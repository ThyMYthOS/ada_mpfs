#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Switch the boot mode (0..3) of the Icicle Kit with the programmer that ships with SoftConsole.

    bootmode.py N [ELF] [--yes] [--dry-run] [--workdir DIR] [--lab FILE]

Runs  java -jar <SoftConsole>/extras/mpfs/mpfsBootmodeProgrammer.jar --workdir DIR --bootmode N --die DIE
--package PKG ELF  (the paths of java, the jar and fpgenprog (full path, file name included), the die and the package come from hw/lab.conf,
whose defaults are in hw/lab.conf.example). The jar needs a boot program ELF, relative to its working
directory: ELF is copied to DIR (default build/bootmode) and handed over by name; without ELF the example
bare_hello is built (./x build bare_hello) and used. Boot mode 0 (idle boot) needs no boot program and gets
none unless ELF is given. The jar finds SoftConsole and fpgenprog through the environment variables
SC_INSTALL_DIR and FPGENPROG, which are set from SOFT_CONSOLE and FPGENPROG of lab.conf (FPGENPROG is the full path of the executable, file name included). Without --lab, LAB_CONF and
hw/lab.conf, hw/lab.conf.example is copied to hw/lab.conf first, without its header lines. The jar builds a differential bitstream with fpgenprog
(Libero) and programs it through FlashPro. The change is PERMANENT: it survives power cycles, it is undone only
by switching again or by programming another design, and it rewrites the configuration of the FPGA part. So
nothing is written unless --yes is given or the word "yes" is typed at the prompt; without --yes and without a
terminal the script refuses (exit status 2). --dry-run prints the command and does nothing else.

The output of the jar is shown as it comes and not interpreted: only its exit status counts, and an exit status
of 0 without any output is treated as a failure. Boot mode 0 was verified on an Icicle Kit by the project owner; the boot modes 1 to 3 have not been run.

Every set-up error is printed together with the help text, which describes the boot modes.

Exit status: 0 the jar ended with status 0 (or --dry-run), 1 the prompt was not answered with "yes", or the jar
failed, 2 a set-up error (bad N, missing java, jar, fpgenprog or ELF, no --yes without a terminal), 130 after
Ctrl+C.
"""
import argparse
import os
import shlex
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lab  # noqa: E402

BARE_HELLO = "bare_hello"

MODES_HELP = """\
boot modes (as mpfsBootmodeProgrammer.jar describes them):
  0  idle boot
  1  non-secure boot from eNVM
  2  user secure boot from sNVM
  3  factory secure boot from eNVM

ELF is the boot program for boot modes 1 to 3 (mode 0 needs none), a file of any directory; the programmer wants it relative to
its working directory, so it is copied to --workdir. Without ELF the example bare_hello is built and used
(it is linked into the L2 LIM, not for the linkage of a boot mode: a stand-in until a real image is given).
Stop OpenOCD before you run this (./x hw openocd): it and the programmer both use the FlashPro.
The programmer is permanent: see above. Defaults of java, the jar, fpgenprog, die and package: hw/lab.conf.example."""


class Parser(argparse.ArgumentParser):
    """An argument error is printed with the help text, like every other set-up error."""

    def error(self, message):
        self.exit(2, f"{paint('error', 'bootmode: ' + message)}\n\n{self.format_help()}")

NEXT_STEPS = """\
bootmode: the programmer ended with status 0. What to do now:
  1. Power-cycle the board (the new boot mode takes effect at power-on).
  2. Start OpenOCD (./x hw openocd) and run ./x hw reset.
  3. Read the PC of the E51 (hart 0). In boot mode 0 it is 0x2000312E after power-on, the boot stub (value given by
     the project owner, see hw/README.md; to verify on the board). Another boot mode runs other code.
  If the PC does not match, the switch did not take effect: run this command again or restore the boot mode that
  docs/lab/icicle.md records for the board."""


def mode(text: str) -> int:
    """The boot mode: an integer 0..3."""
    if not text.isdigit() or not 0 <= int(text) <= 3:
        raise argparse.ArgumentTypeError(f"'{text}' is not a boot mode (0, 1, 2 or 3)")
    return int(text)


COLORS = {"error": "1;31", "warn": "1;33", "ok": "1;32", "info": "36"}


def use_color(stream) -> bool:
    """Colour only on a terminal that supports it: NO_COLOR turns it off, FORCE_COLOR turns it on, and TERM=dumb
    or a stream that is not a terminal get none."""
    if os.environ.get("NO_COLOR"):
        return False
    if os.environ.get("FORCE_COLOR"):
        return True
    return stream.isatty() and os.environ.get("TERM", "dumb") != "dumb"


def paint(kind: str, text: str, stream=None) -> str:
    """<text> in the colour of <kind> (error, warn, ok, info) if <stream> (default stderr) supports colour."""
    stream = stream or sys.stderr
    return f"\033[{COLORS[kind]}m{text}\033[0m" if use_color(stream) else text


def say(kind: str, text: str, stream=None, **kwargs) -> None:
    """Print one message of the script, coloured by <kind>."""
    stream = stream or sys.stdout
    print(paint(kind, text, stream), file=stream, **kwargs)


def fail(message: str):
    """A set-up error: the message and the help text, exit status 2."""
    raise SystemExit(f"{paint('error', 'bootmode: ' + message)}\n\n{PARSER.format_help()}")


def tools(lab_conf: dict[str, str]) -> tuple[str, Path, str]:
    """java, the jar and fpgenprog, resolved; a missing one is an error that says what to do."""
    java = shutil.which(lab_conf["JAVA"])
    if java is None:
        fail(f"java '{lab_conf['JAVA']}' not found: install a JRE or set JAVA in hw/lab.conf")
    jar = Path(lab_conf["BOOTMODE_JAR"] or Path(lab_conf["SOFT_CONSOLE"]) / "extras" / "mpfs" / "mpfsBootmodeProgrammer.jar")
    if not jar.is_file():
        fail(f"{jar} not found: is SoftConsole installed in {lab_conf['SOFT_CONSOLE']}? set SOFT_CONSOLE or BOOTMODE_JAR in hw/lab.conf")
    fpgenprog = lab_conf["FPGENPROG"]
    if not os.path.isabs(fpgenprog) or not os.path.isfile(fpgenprog) or not os.access(fpgenprog, os.X_OK):
        fail(f"FPGENPROG '{fpgenprog}' is not the full path of the fpgenprog executable, file name included "
             "(a name on PATH is not enough): it comes with Libero SoC or the Program Debug Tool; "
             "set FPGENPROG in hw/lab.conf")
    return java, jar, fpgenprog


def openocd_running(lab_conf: dict[str, str]) -> bool:
    """True if something answers on the OpenOCD telnet port of lab.conf: an OpenOCD holds the FlashPro."""
    try:
        with socket.create_connection((lab_conf["OCD_HOST"], int(lab_conf["OCD_PORT"])), timeout=1.0):
            return True
    except OSError:
        return False


def boot_elf(elf: str | None, mode_number: int, workdir: Path, dry_run: bool) -> tuple[str | None, Path | None]:
    """The boot program: (name relative to <workdir>, source file). A given ELF is copied to <workdir>; without
    one, bare_hello is built (not in a dry run, which names it only) and its ELF copied. Boot mode 0 (idle
    boot) needs no boot program: without a given ELF there is none, nothing is built and none is passed."""
    if elf is None and mode_number == 0:
        return None, None
    if elf is not None:
        source = Path(elf)
        if not source.is_file():
            fail(f"ELF '{elf}' does not exist")
    elif dry_run:
        return f"{BARE_HELLO}.elf", None
    else:
        built = subprocess.run([str(lab.ROOT / "x"), "build", BARE_HELLO, "--hart", "e51"]).returncode
        if built != 0:
            fail(f"building {BARE_HELLO} for the boot program failed (status {built}): give an ELF or fix the build")
        found = sorted((lab.ROOT / "examples" / BARE_HELLO / "bin-e51").glob("*.elf"))
        if not found:
            fail(f"building {BARE_HELLO} produced no bin-e51/*.elf: give an ELF")
        source = found[0]
    if not dry_run:
        workdir.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, workdir / source.name)
    return source.name, source


def confirm(mode_number: int, command: list[str]) -> bool:
    """True if the person typed "yes". A run without a terminal refuses (exit status 2)."""
    if not sys.stdin.isatty():
        fail("refusing to write without --yes: this changes the FPGA configuration for good "
             "and there is no terminal to ask (nothing was done)")
    say("warn", "This programs the board through FlashPro. The change is PERMANENT: it survives power cycles and is undone "
          "only by switching again or by programming another design. It rewrites the configuration of the FPGA part.")
    print(f"Command: {shlex.join(command)}")
    answer = input(f"Switch the boot mode to {mode_number}? Type 'yes' to go on: ")
    return answer.strip() == "yes"


def run_jar(command: list[str], env: dict[str, str]) -> tuple[int, int]:
    """Run the jar, show its output as it comes, return (exit status, bytes of output)."""
    try:
        proc = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
    except OSError as e:
        raise SystemExit(paint("error", f"bootmode: cannot run {command[0]}: {e}"))
    seen = 0
    try:
        assert proc.stdout is not None
        for chunk in iter(lambda: proc.stdout.read1(4096), b""):  # type: ignore[union-attr]
            seen += len(chunk)
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()
        return proc.wait(), seen
    except KeyboardInterrupt:
        # The terminal sent Ctrl+C to the programmer as well; give it time to end, never leave it behind.
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        raise


def ensure_lab_conf(named: str | None) -> None:
    """Without --lab, LAB_CONF and hw/lab.conf, create hw/lab.conf (git ignores it) from hw/lab.conf.example,
    without the header of the example (its first comment paragraph, up to the first line that is only "#"), and
    say so."""
    target = lab.HERE / "lab.conf"
    if named or os.environ.get("LAB_CONF") or target.exists():
        return
    try:
        lines = lab.EXAMPLE.read_text().splitlines(keepends=True)
        if "#\n" in lines:
            lines = lines[lines.index("#\n") + 1:]
        target.write_text("".join(lines))
    except OSError as e:
        say("warn", f"bootmode: cannot create {target} from {lab.EXAMPLE.name}: {e}; the defaults of the example are used",
            sys.stderr)
        return
    say("warn", f"bootmode: {target} did not exist: created it from {lab.EXAMPLE.name}. Edit it if your SoftConsole, "
        "Libero or java are installed elsewhere.", sys.stderr)


def make_parser() -> argparse.ArgumentParser:
    ap = Parser(prog="./x hw bootmode", description=__doc__.split("\n")[0] + "\n\nThis programs the board through FlashPro. The change is PERMANENT: it survives "
                "power cycles and is undone only by switching again or by programming another design. It rewrites the "
                "configuration of the FPGA part.",
                epilog=MODES_HELP, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", type=mode, metavar="N", help="boot mode 0..3 (see below)")
    ap.add_argument("elf", nargs="?", metavar="ELF", help="boot program for modes 1 to 3 (default: the example bare_hello, built; none for mode 0)")
    ap.add_argument("--yes", action="store_true", help="do not ask: write the boot mode (PERMANENT, see above)")
    ap.add_argument("--dry-run", action="store_true", help="print the command and do nothing")
    ap.add_argument("--workdir", metavar="DIR", default=str(lab.ROOT / "build" / "bootmode"),
                    help="working directory of the programmer, where it writes bootmode<N>/ (default: build/bootmode)")
    ap.add_argument("--lab", metavar="FILE", help="lab settings (default: hw/lab.conf, on top of hw/lab.conf.example)")
    return ap


PARSER = make_parser()


def main(argv=None):
    a = PARSER.parse_args(argv)
    ensure_lab_conf(a.lab)
    lab_conf = lab.load(a.lab)
    java, jar, fpgenprog = tools(lab_conf)
    if not a.dry_run and openocd_running(lab_conf):
        fail(f"OpenOCD is running ({lab_conf['OCD_HOST']}:{lab_conf['OCD_PORT']} answers): stop it first, it and the "
             "programmer both use the FlashPro (nothing was done)")
    workdir = Path(a.workdir).resolve()
    elf_name, _ = boot_elf(a.elf, a.mode, workdir, a.dry_run)
    command = [java, "-jar", str(jar), "--workdir", str(workdir), "--bootmode", str(a.mode), "--die",
               lab_conf["BOOTMODE_DIE"], "--package", lab_conf["BOOTMODE_PACKAGE"]]
    if elf_name is not None:
        command.append(elf_name)
    if a.dry_run:
        say("info", f"bootmode: dry run, nothing is done. Command: {shlex.join(command)}")
        say("info", f"bootmode: environment of the jar: SC_INSTALL_DIR={lab_conf['SOFT_CONSOLE']}, FPGENPROG={fpgenprog}")
        return 0
    if not a.yes and not confirm(a.mode, command):
        say("warn", "bootmode: not confirmed, nothing was done", sys.stderr)
        return 1
    env = dict(os.environ)
    env["PATH"] = os.path.dirname(fpgenprog) + os.pathsep + env.get("PATH", "")
    env["SC_INSTALL_DIR"] = lab_conf["SOFT_CONSOLE"]   # the jar looks for the SoftConsole installation and fpgenprog by these
    env["FPGENPROG"] = fpgenprog
    say("info", f"bootmode: {shlex.join(command)}", flush=True)
    start = time.monotonic()
    try:
        status, seen = run_jar(command, env)
    except KeyboardInterrupt:
        say("error", f"bootmode: interrupted after {time.monotonic() - start:.1f} s; the FPGA configuration may be half "
              "written: run the command again before you trust the board", stream=sys.stderr)
        return 130
    took = time.monotonic() - start
    say("info", f"bootmode: the programmer took {took:.1f} s")
    if status != 0:
        say("error", f"bootmode: the programmer ended with status {status}: the boot mode was not changed or the board is in an "
              "unknown state; check the output above, the FlashPro connection and fpgenprog, then run it again",
              stream=sys.stderr)
        return 1
    if seen == 0:
        say("error", "bootmode: the programmer ended with status 0 but printed nothing: not trusted; check java, the jar "
              f"({jar}) and fpgenprog, then run it again", stream=sys.stderr)
        return 1
    first, _, rest = NEXT_STEPS.partition("\n")
    say("ok", first)
    print(rest)
    return 0


if __name__ == "__main__":
    sys.exit(lab.run(main, uses_hart=False))
