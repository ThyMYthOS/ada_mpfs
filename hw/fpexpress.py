# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""FlashPro Express (FPExpress) from a Tcl script: what hw/program.py and hw/bootmode.py share.

It writes the Tcl scripts, runs FPExpress on them on a pseudo-terminal (so that what it printed before a crash is not lost in
a buffer), keeps scripts and output in a working directory, and reads the programmers, their models, the devices of a JTAG chain
and the <programmer> element of a project out of what FlashPro Express printed or wrote. The formats of those lines were seen
on a board (embedded FlashPro6, MPFS250); see hw/README.md, "Programming the FPGA". A failure that is a set-up error raises
FpExpressError, which each tool turns into its own message and exit status 2.
"""
import errno
import os
import pty
import re
import shlex
import signal
import subprocess
import time
from pathlib import Path


class FpExpressError(Exception):
    """A set-up error: the FPExpress executable, a path the Tcl cannot take, or what FlashPro Express printed."""


JOB_NAME = "PolarfireProg"
JOB_DIR = "job"   # <workdir>/job: the job project location; FlashPro Express does not create it
# FlashPro Express prints the programmer in quotes: "Programmer: Embedded FP6 'B347B62F' : Version = EF9B" and
# "programmer 'B347B62F' : Embedded FlashPro6" (seen on a board); the name is what is in the quotes
PROGRAMMER = re.compile(r"programmer[^'\n]*'([^']+)'", re.I)
# the model follows the name: "programmer 'B347B62F' : Embedded FlashPro6", "programmer 'E2001KOQ57' : FlashPro5"
MODEL = re.compile(r"programmer\s+'([^']+)'\s*:\s*((?:Embedded\s+)?FlashPro\s?\w*)\s*$", re.I | re.M)
DEVICE_LINE = re.compile(r"Device.*Mfr.*Part")
DEVICE = re.compile(r"Part:\s*(\S+)")
# "programmer 'B347B62F' : Device 1: F81A1CF Mfr: Microsemi Part: MPFS250(T_ES|TS_ES)"
CHAIN = re.compile(r"Device\s+(\d+):\s*(\S+)\s+Mfr:\s*(.+?)\s+Part:\s*(\S+)")
# the <programmer ...>...</programmer> element of a project, which names the programmer with its type and connection
PROGRAMMER_ELEMENT = re.compile(r"<programmer\b.*?</programmer>", re.S)


def resolve_fpexpress(lab_conf: dict[str, str], required: bool = True) -> Path | None:
    """FPEXPRESS of lab.conf, or the FPExpress next to FPGENPROG; it must be the full path of an executable. Not there:
    an error, or None if it is not required."""
    configured = lab_conf.get("FPEXPRESS", "")
    path = configured or str(Path(lab_conf["FPGENPROG"]).parent / "FPExpress")
    if os.path.isabs(path) and os.path.isfile(path) and os.access(path, os.X_OK):
        return Path(path)
    if not required:
        return None
    raise FpExpressError(f"FPEXPRESS '{path}' is not the full path of the FPExpress executable, file name included"
                         + ("" if configured else " (FPEXPRESS is empty, so it is taken from the directory of FPGENPROG)")
                         + ": it comes with Libero SoC or the Program Debug Tool; set FPEXPRESS in hw/lab.conf")


def tcl_word(text: str, what: str) -> str:
    """<text> as a braced Tcl word. A brace, a backslash or a line end in it would end the word early."""
    if any(c in text for c in "{}\\\n\r"):
        raise FpExpressError(f"{what} '{text}' has a brace, a backslash or a line end in it, which a Tcl script cannot take")
    return "{" + text + "}"


def job_lines(job_dir: Path, programmer: str) -> list[str]:
    """The Tcl that makes the job project for a programmer ("" lets FlashPro Express look for one)."""
    return ["set_fpexpress_mode -mode {developer_mode}",
            "auto_construct_job_project \\",
            f"  -job_project_location {tcl_word(str(job_dir), 'the workdir')} \\",
            f"  -job_name {{{JOB_NAME}}} \\",
            f"  -programmer {{{programmer}}} \\",
            "  -overwrite 1"]


def project_file(job_dir: Path) -> Path:
    """The project that auto_construct_job_project makes: <job project location>/<job name>/<job name>.pro (the message
    "Created new project '...'" names it)."""
    return job_dir / JOB_NAME / f"{JOB_NAME}.pro"


def reopen_lines(job_dir: Path) -> list[str]:
    """close_project and open_project on the project that was just made. FlashPro Express 2026.1 failed on a scan_chain_prg that
    came right after auto_construct_job_project (with a FlashPro5 and with a FlashPro6); with these two in between it works,
    with 2026.1 and with 2024.2. auto_construct_job_project scans the chain itself ("Construct Chain...", "Scan Chain
    PASSED") but prints no device information, which is why the scan_chain_prg is still there."""
    return ["close_project", f"open_project -project {tcl_word(str(project_file(job_dir)), 'the workdir')}"]


def script_text(lines: list[str]) -> str:
    return "# Microsemi Tcl Script\n" + "\n".join(lines) + "\n"


def detect_programmer_script(job_dir: Path) -> str:
    return script_text(job_lines(job_dir, ""))


def programmers_in(output: str) -> list[str]:
    """The programmer names that the output of FlashPro Express shows, each once, in order."""
    return list(dict.fromkeys(PROGRAMMER.findall(output)))


def models_in(output: str) -> dict[str, str]:
    """{programmer name: model} for the programmer lines of the output that name a model ("Embedded FlashPro6")."""
    return {name: model.strip() for name, model in MODEL.findall(output)}


def chain_in(output: str) -> list[tuple[str, str, str, str]]:
    """(number, IDCODE, manufacturer, part) of every device the scan of the chain printed, each once, in order."""
    found = []
    for line in output.splitlines():
        found += CHAIN.findall(line)
    return list(dict.fromkeys(found))


def devices_in(output: str) -> list[str]:
    """The part names of the devices that the scan of the chain prints, each once, in order."""
    found = []
    for line in output.splitlines():
        if DEVICE_LINE.search(line):
            found += DEVICE.findall(line)
    return list(dict.fromkeys(found))


def describe_status(rc: int) -> str:
    """What an exit status of FlashPro Express means. A shell wrapper (the snap of the Program Debug Tool runs
    FPExpress through one) reports a signal as 128 + its number, which is what 139 is; Popen reports it as -N."""
    def signal_name(number: int) -> str:
        try:
            return f"signal {number} ({signal.Signals(number).name})"
        except ValueError:
            return f"signal {number}"
    if rc < 0:
        return f"killed by {signal_name(-rc)}"
    if rc > 128:
        return f"killed by {signal_name(rc - 128)}, as a shell reports it"
    if rc == 1:
        return "the Tcl script failed (a command printed an Error: line)"
    return "ok" if rc == 0 else "the script ended with this status"


class Run:
    """FPExpress runs in one working directory: it keeps the scripts and the log there."""

    def __init__(self, fpexpress: Path, workdir: Path, log_name: str = "program.log"):
        self.fpexpress = fpexpress
        self.workdir = workdir
        (workdir / JOB_DIR).mkdir(parents=True, exist_ok=True)   # FlashPro Express stops if the location is not there
        self.log = open(workdir / log_name, "w", encoding="utf-8")
        self.seconds = 0.0   # how long the last script ran

    def close(self) -> None:
        self.log.close()

    def script(self, name: str, text: str, show: bool) -> tuple[int, str]:
        """Write <name>.tcl and run FPExpress on it; the output is logged and, with <show>, printed as it comes.
        Returns the exit status and the whole output."""
        path = self.workdir / f"{name}.tcl"
        path.write_text(text, encoding="utf-8")
        command = [str(self.fpexpress), f"script:{path}"]
        self.log.write(f"$ {shlex.join(command)}\n")
        self.log.flush()
        # A pseudo-terminal, not a pipe: a program that writes to a pipe buffers its output in blocks, and what it
        # has not written when it crashes is lost (FlashPro Express printed nothing before a segmentation fault).
        master, slave = pty.openpty()
        started = time.monotonic()
        lines = []
        proc = None

        def take(raw: bytes) -> None:
            line = raw.decode("utf-8", errors="replace").rstrip("\r\n") + "\n"
            lines.append(line)
            self.log.write(line)
            if show:
                print(line, end="", flush=True)

        try:
            proc = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=slave, stderr=slave, close_fds=True,
                                    cwd=self.workdir)
            os.close(slave)
            slave = -1
            pending = b""
            while True:
                try:
                    data = os.read(master, 4096)
                except OSError as e:
                    if e.errno == errno.EIO:   # Linux: the program (and every child) closed its side
                        break
                    raise
                if not data:
                    break
                pending += data
                while b"\n" in pending:
                    raw, _, pending = pending.partition(b"\n")
                    take(raw)
            if pending:
                take(pending)
            rc = proc.wait()
        except BaseException:
            if proc is not None:
                proc.kill()
                proc.wait()
            raise
        finally:
            os.close(master)
            if slave >= 0:
                os.close(slave)
        self.seconds = time.monotonic() - started
        self.log.write(f"(exit status {rc}: {describe_status(rc)}; {self.seconds:.1f} s)\n")
        self.log.flush()
        return rc, "".join(lines)


def find_programmers(run: Run, job_dir: Path) -> tuple[list[str], dict[str, str], str]:
    """Run FlashPro Express with an empty programmer name, which makes it print the programmers it sees: their names, their
    models and the whole output."""
    _, output = run.script("detect_programmer", detect_programmer_script(job_dir), show=False)
    return programmers_in(output), models_in(output), output


def programmer_script(job_dir: Path, programmer: str) -> str:
    """A job project for <programmer>, closed so that it is on disk: auto_construct_job_project (which scans the chain itself)
    and close_project, the two commands of the sequence that was run on a board."""
    return script_text(job_lines(job_dir, programmer) + ["close_project"])


def programmer_element(run: Run, job_dir: Path, programmer: str) -> str:
    """The <programmer ...> element that FlashPro Express writes into a project for <programmer>: with its type and its
    connection, as in <programmer status="enable" type="FlashPro6Lite" revision="UndefRev" connection="usb1.1"><name>B347B62F</name>
    <id>B347B62F</id></programmer>. That is how a project names the programmer it is for, and what a tool that has a project of its own
    (fpgenprog) is given, so that it uses this programmer and no other. FlashPro Express makes the project in the working
    directory of <run>."""
    rc, output = run.script("programmer", programmer_script(job_dir, programmer), show=False)
    pro = project_file(job_dir)
    try:
        text = pro.read_text(encoding="utf-8")
    except OSError:
        text = ""
    found = PROGRAMMER_ELEMENT.search(text)
    named = re.search(r"<id>\s*(\S+)\s*</id>", found.group(0)) if found else None
    if rc != 0 or found is None or named is None or named.group(1) != programmer:
        errors = "".join(f"\n  {ln.strip()}" for ln in output.splitlines() if ln.strip().startswith("Error"))
        why = ("is not there" if not text else "has no <programmer> element" if found is None else
               "names another programmer" if named is None or named.group(1) != programmer else "was made")
        raise FpExpressError(f"FlashPro Express did not make a project for the programmer '{programmer}' (status {rc}; the "
                             f"project {pro} {why}; output in {run.log.name}){errors}")
    return found.group(0)
