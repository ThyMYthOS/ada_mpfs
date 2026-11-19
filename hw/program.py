#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Program the FPGA of a PolarFire or PolarFire SoC board from a STAPL or PPD file with FlashPro Express.

    program.py FILE [--device NAME] [--programmer ID] [--action ACTION] [--tck MHZ] [--workdir DIR]
               [--yes] [--dry-run] [--lab FILE]
    program.py --scan [--programmer ID] [--tck MHZ] [--workdir DIR] [--dry-run] [--lab FILE]

--scan only reads: it lists the programmers FlashPro Express finds, with their models, and the devices of the JTAG
chain of each (or of the one named with --programmer or FLASHPRO_ID); no FILE, nothing is written, no
prompt. Exit status 0 if every chain scanned shows a device, 1 if one does not. The rest of this text is about
programming.

Runs FPExpress (FlashPro Express of Libero SoC or of the Program Debug Tool) with a Tcl script that this script
writes to <workdir>/ (default: build/program): it builds a job project for the programmer, scans the JTAG chain,
enables the device, loads FILE and runs ACTION (default PROGRAM). The manual of FlashPro Express lists the actions
DEVICE_INFO, ENC_DATA_AUTHENTICATION, ERASE, PROGRAM, READ_IDCODE and VERIFY; any name goes through, and FlashPro
Express rejects one that does not exist. DEVICE_INFO, READ_IDCODE and VERIFY only read: they need no --yes and no
prompt. They still need a FILE: FlashPro Express stops with "A programming file must be loaded before running the
command 'set_programming_action'" without one (seen with DEVICE_INFO on a board); the file is loaded, not written.
The path of FPExpress (full path, file name included) is FPEXPRESS of hw/lab.conf; if that is
empty, it is the FPExpress that lies next to the FPGENPROG of lab.conf (in the Program Debug Tool and in Libero SoC
both are in the same bin directory).

The programmer is --programmer, else FLASHPRO_ID of lab.conf, else, for a FlashPro5 that FLASHPRO_SERIAL
names, "S2" and that serial number (an assumption, see flashpros.flashpro5_id(); it is checked against the programmers
FlashPro Express finds), else the one FlashPro Express finds: the script runs it once with an empty programmer name
and reads the name in quotes from the programmer lines it prints ("programmer 'B347B62F' : Embedded FlashPro6"). The
name FlashPro Express gives a FlashPro is not in general the serial number of OpenOCD or of ./x hw flashpros
(S200BM0VJ against 00BM80VJ on one FlashPro5), so FLASHPRO_SERIAL is used for a FlashPro5 only, with the prefix. The
device is --device,
else the one the scan of the chain prints ("Device ... Mfr: ... Part: <name>"). More than one programmer or device
found is an error that lists them (name one with --programmer or --device). Both detections read only. Both
kinds of line were seen in the output of an embedded FlashPro6 on an MPFS250: "programmer 'B347B62F' : Device 1:
F81A1CF Mfr: Microsemi Part: MPFS250(T_ES|TS_ES)". They are not in the documentation of FlashPro Express. The
device name goes into the Tcl script as the scan printed it, with the parentheses and the bar. (Splitting it into
MPFS250T_ES and MPFS250TS_ES was tried and taken out again: it did not work as hoped on the board.)

After auto_construct_job_project the scripts close the project and open it again (close_project, open_project on the
project it made) before they scan: FlashPro Express 2026.1 failed on a scan_chain_prg that came right after it, with a
FlashPro5 and with a FlashPro6, and with the two commands in between it works, with 2026.1 and with 2024.2. Whether the
fault is in FlashPro Express or in its installation is not known. auto_construct_job_project scans the chain itself
("Construct Chain...", "Scan Chain PASSED") but prints no device information, so the scan_chain_prg stays.

The TCK frequency of the JTAG chain is --tck MHZ, else TCK_MHZ of lab.conf, else what FlashPro Express
decides (the manual says 4 MHz by default, or the frequency of the programming file). A frequency given is put into the
scripts as configure_flashpro6_prg (or configure_flashpro5_prg, by the model of the programmer) -force_freq {ON}
-freq {HZ} (MHZ times 1000000: FlashPro Express wants Hz, whole MHz, 1 to 20 MHz for a FlashPro6, although its
manual says MHz): FlashPro Express then uses exactly that frequency and not the one of the programming file, so it
is the highest clock that is used. The model is read from the programmer line ("Embedded FlashPro6"), so a run with a
frequency also looks for the programmers when --programmer names one, and checks that it is there.

The programming rewrites the FPGA configuration, so nothing is written unless --yes is given or the word "yes" is
typed at the prompt; without --yes and without a terminal the script refuses (exit status 2). --dry-run starts
nothing and prints the Tcl scripts it would run (with <programmer> and <device> in place of what the detection
would find). FlashPro Express and OpenOCD both use the FlashPro, so the script refuses while OpenOCD answers on
the port of lab.conf. The Tcl scripts and the whole output are kept in <workdir>/ (program.log).

Files that have been used with this script: .stp (STAPL; the shell script it replaces programmed an MPF500 with one) and
.ppd (the PPD of the Icicle Kit base design programmed an MPFS250). Another file is tried, with a warning.

Exit status: 0 done (or --dry-run), 1 the prompt was not answered with "yes", or FlashPro Express failed or
printed nothing, or (--scan) a chain showed no device, 2 a set-up error (bad option, missing FPExpress or file, no
--yes without a terminal, OpenOCD running, programmer or device not found or not unique), 130 after Ctrl+C.
"""
import argparse
import os
import re
import shlex
import sys
import time
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import flashpros  # noqa: E402
import lab  # noqa: E402
from fpexpress import (JOB_DIR, FpExpressError, Run, chain_in, describe_status, detect_programmer_script,  # noqa: E402,F401
                       devices_in, find_programmers, job_lines, models_in, programmers_in, project_file, reopen_lines,
                       resolve_fpexpress, script_text, tcl_word)
from bootmode import openocd_running, paint, say  # noqa: E402

# a programmer, a device and an action as the Tcl script gets them; the scan prints the part of an MPFS250 as
# MPFS250(T_ES|TS_ES), hence the parentheses and the bar
NAME = re.compile(r"[0-9A-Za-z_.()|-]+")
# whole MHz: FlashPro Express takes -freq in Hz and, for a FlashPro6, only 1000000 to 20000000 in steps of 1000000 (its
# message: "freq: Invalid argument value: '10' (expecting 1000000, 2000000, ... or 20000000)"), although its manual says MHz
TCK = re.compile(r"[1-9][0-9]*")
FLASHPRO6_MAX_MHZ = 20
# FlashPro Express ends a script that ran through with "The Execute Script command succeeded." and status 0, and one
# in which a command failed with "... failed." and status 1 (seen on a board). A script must NOT end with the Tcl
# command exit: FlashPro Express 2024.2.0.13 (the snap) crashed with a segmentation fault on it, after a failed action
# and after a successful one.
KNOWN_FILE_TYPES = (".stp", ".ppd")   # used on a board: a STAPL file (MPF500, by the old shell script) and a PPD (MPFS250)
SCRIPT_OK = "The Execute Script command succeeded"
# "Warning:  The programming file '<file>' is for 'MPF300TS_ES' devices. Your current device 'MPFS250(T_ES|TS_ES)' doesn't match"
FILE_FOR = re.compile(r"programming file '[^']*' is for '([^']+)' devices")
# The actions of the manual ("Selecting and Running an Action"): DEVICE_INFO, ENC_DATA_AUTHENTICATION, ERASE, PROGRAM,
# READ_IDCODE, VERIFY. These only read, so they need no prompt and no --yes. Every action needs a programming file
# loaded, FlashPro Express says so for set_programming_action (DEVICE_INFO without one stopped with that error).
READ_ONLY_ACTIONS = ("DEVICE_INFO", "READ_IDCODE", "VERIFY")


def fail(message: str):
    """A set-up error: the message, exit status 2 (lab.run)."""
    raise SystemExit(paint("error", f"program: {message}"))


def clock_lines(model: str | None, mhz: str | None, dry_run: bool = False) -> list[str]:
    """The Tcl that sets the TCK frequency, for the family of the programmer: configure_flashpro6_prg for a FlashPro6
    (also the embedded one), configure_flashpro5_prg for a FlashPro5. No frequency, no line. A model without a known
    command, or none printed, is a set-up error; a dry run leaves the number of the command open."""
    if mhz is None:
        return []
    if model is None and dry_run:
        command = "configure_flashpro<5 or 6>_prg"
    elif model is None:
        fail("FlashPro Express printed no model for the programmer (the line 'programmer ... : Embedded FlashPro6'), so "
             "it is not known which command sets the TCK frequency: leave TCK_MHZ and --tck out")
    elif "flashpro6" in model.replace(" ", "").lower():
        command = "configure_flashpro6_prg"
    elif "flashpro5" in model.replace(" ", "").lower():
        command = "configure_flashpro5_prg"
    else:
        fail(f"no command to set the TCK frequency is known for the programmer model '{model}' (FlashPro Express has "
             "one for FlashPro6 and FlashPro5): leave TCK_MHZ and --tck out")
    if command == "configure_flashpro6_prg" and int(mhz) > FLASHPRO6_MAX_MHZ:
        fail(f"a FlashPro6 takes 1 to {FLASHPRO6_MAX_MHZ} MHz in steps of 1 MHz (FlashPro Express says so), not {mhz}")
    return [f"{command} -force_freq {{ON}} -freq {{{int(mhz) * 1_000_000}}}"]


def detect_device_script(job_dir: Path, programmer: str, clock: list[str]) -> str:
    return script_text(job_lines(job_dir, programmer) + reopen_lines(job_dir) + clock
                       + [f"scan_chain_prg -name {{{programmer}}}"])


def program_script(job_dir: Path, programmer: str, device: str, stapl: Path, action: str, clock: list[str]) -> str:
    """The action: the job project (closed and opened again, see reopen_lines), the clock, the scan, the device, the file
    (every action needs one loaded) and the action. A failing command ends the script, and FlashPro Express then exits with
    status 1; the script does not call exit (see SCRIPT_OK)."""
    return script_text(job_lines(job_dir, programmer) + reopen_lines(job_dir) + clock + [
        f"scan_chain_prg -name {{{programmer}}}",
        f"enable_device -name {{{device}}} -enable 1",
        f"set_programming_file -name {{{device}}} -file {tcl_word(str(stapl), 'the file')}",
        f"set_programming_action -name {{{device}}} -action {{{action}}}",
        "run_selected_actions"])


def pick(found: list[str], what: str, option: str, output: str, run: Run) -> str:
    """The one programmer or device found; none or several is a set-up error that says what to give."""
    if len(found) == 1:
        if not NAME.fullmatch(found[0]):
            fail(f"the {what} name '{found[0]}' that FlashPro Express printed has characters this script does not "
                 "put into a Tcl script (it takes letters, digits, '_', '.', '-', '(', ')' and '|'; see program.log)")
        return found[0]
    seen = [ln for ln in output.splitlines() if ln.strip()][-8:]
    errors = [ln.strip() for ln in output.splitlines() if ln.strip().startswith("Error")]
    if not found and errors:   # FlashPro Express said why (a bad option, a command that failed): that is the thing to read
        fail(f"FlashPro Express printed no {what} and reported errors (output in {run.log.name}):\n  "
             + "\n  ".join(errors[:6]))
    if not found:
        fail(f"FlashPro Express printed no {what} (output in {run.log.name}); the last lines were:\n  "
             + "\n  ".join(seen) + f"\nname it with {option}")
    fail(f"more than one {what} found: {', '.join(found)}; name one with {option}")


def confirm(command: list[str], programmer: str, device: str, stapl: Path, action: str) -> bool:
    """True if the person typed "yes"."""
    say("warn", f"program: {action} of {device} through programmer {programmer} from {stapl}. This rewrites the "
        "FPGA configuration.")
    print(f"Command: {shlex.join(command)}")
    return input(f"{action} {device}? Type 'yes' to go on: ").strip() == "yes"


def make_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(prog="./x hw program", description=__doc__.split("\n")[0])
    ap.add_argument("file", metavar="FILE", nargs="?", help="the programming file (.stp or .ppd) to load (not with --scan)")
    ap.add_argument("--scan", action="store_true",
                    help="only list the programmers and the devices of their JTAG chains: it reads, writes nothing, "
                    "asks nothing and takes no FILE")
    ap.add_argument("--device", metavar="NAME",
                    help="the device of the JTAG chain as the scan prints it, e.g. MPFS250(T_ES|TS_ES) (default: the one "
                    "the scan prints)")
    ap.add_argument("--programmer", metavar="ID",
                    help="the FlashPro as FlashPro Express names it, not the serial of OpenOCD (default: FLASHPRO_ID of lab.conf, else the one it finds)")
    ap.add_argument("--action", metavar="ACTION", default="PROGRAM",
                    help="the action of FlashPro Express (default: PROGRAM; its manual lists DEVICE_INFO, ERASE, PROGRAM, "
                    "READ_IDCODE, VERIFY and ENC_DATA_AUTHENTICATION). DEVICE_INFO, READ_IDCODE and VERIFY only read: no "
                    "prompt, no --yes, but all of them need a FILE")
    ap.add_argument("--tck", metavar="MHZ",
                    help="TCK frequency of the JTAG chain in whole MHz, forced (a FlashPro6 takes 1 to 20; default: "
                    "TCK_MHZ of lab.conf, else FlashPro Express decides)")
    ap.add_argument("--workdir", metavar="DIR", default=str(lab.ROOT / "build" / "program"),
                    help="where the Tcl scripts and program.log are written (default: build/program)")
    ap.add_argument("--yes", action="store_true", help="do not ask: program (this rewrites the FPGA configuration)")
    ap.add_argument("--dry-run", action="store_true", help="print the Tcl scripts and start nothing")
    ap.add_argument("--lab", metavar="FILE", help="lab settings (default: hw/lab.conf, on top of hw/lab.conf.example)")
    return ap


def scan_chains(run: Run, job_dir: Path, programmers: list[str], models: dict[str, str], mhz: str | None) -> int:
    """--scan: the devices of the JTAG chain of each programmer, printed. 0 if every chain shows a device, else 1."""
    status = 0
    for name in programmers:
        if not NAME.fullmatch(name):
            fail(f"the programmer name '{name}' that FlashPro Express printed has characters this script does not put "
                 "into a Tcl script (it takes letters, digits, '_', '.' and '-'; see program.log)")
        clock = clock_lines(models.get(name), mhz)
        say("info", f"program: scanning the chain of programmer {name}")
        _, output = run.script(f"scan_{name}", detect_device_script(job_dir, name, clock), show=False)
        chain = chain_in(output)
        print(f"programmer {name}: {models.get(name, '(no model printed)')}")
        for number, idcode, manufacturer, part in chain:
            print(f"  device {number}: {part}, IDCODE {idcode}, {manufacturer}")
        if not chain:
            status = 1
            seen = [ln for ln in output.splitlines() if ln.strip()][-4:]
            print("  no device found (the scan failed or the chain is empty); the last lines were:")
            for ln in seen:
                print(f"    {ln}")
    return status


def _main(argv=None) -> int:
    parser = make_parser()
    a = parser.parse_args(argv)
    if a.scan and a.file is not None:
        parser.error("--scan takes no FILE")
    if not a.scan and a.file is None:
        parser.error("FILE is required (or --scan); every action needs a programming file loaded")
    read_only = a.action in READ_ONLY_ACTIONS
    lab_conf = lab.load(a.lab)
    fpexpress = resolve_fpexpress(lab_conf)
    stapl = None
    if not a.scan and a.file is not None:
        stapl = Path(a.file).resolve()
        if not stapl.is_file():
            fail(f"'{a.file}' does not exist")
        if stapl.suffix.lower() not in KNOWN_FILE_TYPES:
            say("warn", f"program: {stapl.name} is neither a .stp nor a .ppd file; only those have been used with this "
                "script", sys.stderr)
        tcl_word(str(stapl), "the file")      # a path the Tcl cannot take is found before anything runs
    programmer = a.programmer or lab_conf.get("FLASHPRO_ID") or None
    guessed = False   # the name of a FlashPro5 derived from FLASHPRO_SERIAL: it is checked against the programmers found
    if programmer is None and not a.scan:
        programmer = flashpros.flashpro5_id(lab_conf)
        guessed = programmer is not None
    for value, what in ((programmer, "programmer"), (a.action, "action")):
        if value is not None and not NAME.fullmatch(value):
            fail(f"'{value}' is not a {what} name (letters, digits, '_', '.' and '-')")
    mhz = a.tck or lab_conf.get("TCK_MHZ") or None
    if mhz is not None and not TCK.fullmatch(mhz):
        fail(f"'{mhz}' is not a TCK frequency in whole MHz (such as 4; FlashPro Express takes steps of 1 MHz)")
    if a.device is not None and not NAME.fullmatch(a.device):
        fail(f"'{a.device}' is not a device name (letters, digits, '_', '.', '-', '(', ')' and '|')")
    device_given = a.device
    workdir = Path(a.workdir).resolve()
    job_dir = workdir / JOB_DIR
    tcl_word(str(job_dir), "the workdir")
    # the model of the programmer decides which command sets the frequency, and only the output with the programmers
    # has it: with a frequency (and for --scan) the programmers are looked for even when one is named
    need_programmers = programmer is None or guessed or mhz is not None or a.scan
    if a.dry_run:
        say("info", f"program: dry run, nothing is started. FPExpress: {fpexpress}; the scripts are written to {workdir}")
        if guessed:
            say("info", f"program: programmer {programmer}: derived from FLASHPRO_SERIAL (a FlashPro5 is assumed to be named "
                f"'{flashpros.FP5_PREFIX}' and the serial number), checked against the programmers found in a real run")
        clock = clock_lines(None, mhz, dry_run=True)
        steps = []
        if need_programmers:
            steps.append(("detect_programmer", detect_programmer_script(job_dir)))
        if a.scan:
            steps.append(("scan_<programmer>", detect_device_script(job_dir, programmer or "<programmer>", clock)))
        else:
            if device_given is None:
                steps.append(("detect_device", detect_device_script(job_dir, programmer or "<programmer>", clock)))
            steps.append(("program", program_script(job_dir, programmer or "<programmer>", device_given or "<device>",
                                                    stapl, a.action, clock)))
        for name, text in steps:
            print(f"--- {name}.tcl\n{text}", end="")
        return 0
    if openocd_running(lab_conf):
        fail(f"OpenOCD is running ({lab_conf['OCD_HOST']}:{lab_conf['OCD_PORT']} answers): stop it first, it and "
             "FlashPro Express both use the FlashPro (nothing was done)")
    if not a.scan and not read_only and not a.yes and not sys.stdin.isatty():
        fail(f"refusing to run {a.action} without --yes: it changes the FPGA and there is no terminal to ask "
             "(nothing was done)")
    start = time.monotonic()
    run = Run(fpexpress, workdir)
    try:
        models = {}
        if need_programmers:
            say("info", "program: looking for the programmers")
            names, models, output = find_programmers(run, job_dir)
            if programmer is not None and programmer not in names:
                how = (f": it was derived from FLASHPRO_SERIAL {lab_conf['FLASHPRO_SERIAL']} on the assumption that "
                       f"FlashPro Express names a FlashPro5 '{flashpros.FP5_PREFIX}' and the serial number; name the programmer "
                       "with --programmer or FLASHPRO_ID" if guessed else "")
                fail(f"the programmer '{programmer}' is not among those FlashPro Express found "
                     f"({', '.join(names) or 'none'}; output in {run.log.name}){how}")
            if a.scan:
                if not names:
                    pick(names, "programmer", "--programmer", output, run)   # says what was printed instead
                return scan_chains(run, job_dir, [programmer] if programmer else names, models, mhz)
            if programmer is None:
                programmer = pick(names, "programmer", "--programmer", output, run)
            say("info", f"program: programmer {programmer}")
        clock = clock_lines(models.get(programmer), mhz)
        if device_given is None:
            say("info", f"program: scanning the chain of programmer {programmer}")
            _, output = run.script("detect_device", detect_device_script(job_dir, programmer, clock), show=False)
            device = pick(devices_in(output), "device", "--device", output, run)
            say("info", f"program: device {device}")
        else:
            device = device_given
        text = program_script(job_dir, programmer, device, stapl, a.action, clock)
        command = [str(fpexpress), f"script:{workdir / 'program.tcl'}"]
        if not read_only and not a.yes and not confirm(command, programmer, device, stapl, a.action):
            say("warn", "program: not confirmed, nothing was written to the board", sys.stderr)
            return 1
        rc, output = run.script("program", text, show=True)
    except KeyboardInterrupt:
        say("error", f"program: interrupted after {time.monotonic() - start:.1f} s; if it was programming, the FPGA "
            "configuration may be half written: run the command again before you trust the board", sys.stderr)
        return 130
    finally:
        run.close()
    took = time.monotonic() - start
    if rc != 0:
        # FlashPro Express prints "Executing action <ACTION>" when the action starts: before that (the check of the chain
        # against the file failed) nothing has been written
        if read_only:
            after = "; it only reads, so nothing was written"
        elif "Executing action" not in output:
            after = "; the action did not start, so nothing was written"
        else:
            after = ": the FPGA may be half programmed, run it again before you trust the board"
        say("error", f"program: FlashPro Express ended with status {rc}: {describe_status(rc)}, after {run.seconds:.1f} s "
            f"of its own; details in {run.log.name}{after}", sys.stderr)
        wrong = FILE_FOR.search(output)
        if wrong:
            say("error", f"program: the programming file is for {wrong.group(1)} devices and the chain has {device}: a file "
                "for another device cannot be used on this board", sys.stderr)
        if not output.strip():
            say("error", f"program: it printed nothing before it ended; run the script by hand in a terminal to see more: "
                f"{shlex.join(command)}", sys.stderr)
        return 1
    if not output.strip():
        say("error", f"program: FlashPro Express ended with status 0 but printed nothing: not trusted; check "
            f"FPEXPRESS ({fpexpress}), then run it again", sys.stderr)
        return 1
    if SCRIPT_OK not in output:
        say("error", f"program: FlashPro Express ended with status 0 but did not print '{SCRIPT_OK}': not trusted; read "
            f"{run.log.name}, then run it again", sys.stderr)
        return 1
    say("ok", f"program: {a.action} of {device} through programmer {programmer} took {took:.1f} s "
        f"(log: {run.log.name})")
    return 0


def main(argv=None) -> int:
    try:
        return _main(argv)
    except FpExpressError as e:   # a set-up error of the FPExpress side: this tool's message, exit status 2
        fail(str(e))


if __name__ == "__main__":
    sys.exit(lab.run(main, uses_hart=False))
