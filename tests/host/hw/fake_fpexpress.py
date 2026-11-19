#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""A stand-in for FPExpress (FlashPro Express), for the tests of hw/program.py.

It takes `script:FILE`, appends the script to $FAKE_FPE_LOG (a line "=== <name>" before each) and acts on it like the
three scripts of program.py need: with an empty programmer name it prints the programmers it "finds"; a script
that ends with scan_chain_prg prints the devices it "finds"; the script with a programming action checks that
the programmer and the device it names are among those, and ends with the status of $FAKE_FPE_RC. It does no
hardware and no Tcl. The programmer lines are the ones an embedded FlashPro6 printed on a board (with the error of
auto_construct_job_project after them, as for an empty or a wrong name); so is the device line of the scan.

  FAKE_FPE_LOG         file that gets every script (required)
  FAKE_FPE_PROGRAMMERS comma separated names printed in "programmer '<name>' : Embedded FlashPro6" (default FAKEPRG01)
  FAKE_FPE_DEVICES     comma separated part names printed in a "Device 1: F81A1CF Mfr: Microsemi Part: <name>" line
                       (default MPF500T)
  FAKE_FPE_MODEL       the model after the programmer name (default "Embedded FlashPro6"; e.g. "FlashPro5")
  FAKE_FPE_RC          exit status of the programming script (default 0)
  FAKE_FPE_SILENT      1: the programming script prints nothing
  FAKE_FPE_CRASH       1: the programming script prints its line and then ends with a segmentation fault
  FAKE_FPE_FILE_DEVICE a device name: the programming file is "for" that device, and the check of the chain fails
  FAKE_FPE_SCAN_ERROR  1: the scan script prints Error: lines and no device and exits 1
  FAKE_FPE_NO_OK       1: the script runs through and exits 0 without printing "The Execute Script command succeeded."
"""
import os
import re
import signal
import sys
from pathlib import Path


def names(variable: str, default: str) -> list[str]:
    return [n for n in os.environ.get(variable, default).split(",") if n]


def finish(rc: int, text: str) -> int:
    """The end of a script. FlashPro Express 2024.2.0.13 (the snap) crashed with a segmentation fault on the Tcl command
    exit, after a failed and after a successful action; a script that ends by itself exits normally."""
    if re.search(r"(^|[\s{])exit([\s}]|$)", text):
        os.kill(os.getpid(), signal.SIGSEGV)
    return rc


def main(argv: list[str]) -> int:
    scripts = [a[len("script:"):] for a in argv if a.startswith("script:")]
    if len(scripts) != 1:
        print("fake FPExpress: usage: FPExpress script:FILE", file=sys.stderr)
        return 2
    path = Path(scripts[0])
    text = path.read_text(encoding="utf-8")
    with open(os.environ["FAKE_FPE_LOG"], "a", encoding="utf-8") as f:
        f.write(f"=== {path.stem}\n{text}")
    programmers = names("FAKE_FPE_PROGRAMMERS", "FAKEPRG01")
    devices = names("FAKE_FPE_DEVICES", "MPF500T")
    named = re.search(r"-programmer \{([^}]*)\}", text)
    if named is None:
        print("fake FPExpress: the script has no auto_construct_job_project", file=sys.stderr)
        return 2
    silent = os.environ.get("FAKE_FPE_SILENT") == "1" and "set_programming_action" in text
    location = re.search(r"-job_project_location \{([^}]*)\}", text)
    if location is None or not Path(location.group(1)).is_dir():
        print(f"fake FPExpress: the job project location {location.group(1) if location else '(none)'} does not exist",
              file=sys.stderr)   # FlashPro Express does not create the directory
        return 3
    if not silent:
        print("fake FPExpress: Running the script")
    if named.group(1) == "" or named.group(1) not in programmers:
        # what FlashPro Express printed on a board when the name was empty or wrong: the programmers it sees (the
        # name in quotes), then the error of auto_construct_job_project; the exit status of that is not known
        for p in programmers:
            print(f"Programmer: Embedded FP6 '{p}' : Version = EF9B")
            print("===============================================================")
            print(f"programmer '{p}' : {os.environ.get('FAKE_FPE_MODEL', 'Embedded FlashPro6')}")
        print(f"Created new project '{location.group(1)}/{'PolarfireProg'}/PolarfireProg.pro'")
        print("Error:  Parameter 'name' is missing or has invalid value.")
        print("Error:  The command 'auto_construct_job_project' failed.")
        return 1 if named.group(1) == "" else 3
    # auto_construct_job_project makes the project; FlashPro Express 2026.1 failed on a scan_chain_prg right after it (on a
    # FlashPro5 and on a FlashPro6) unless the project was closed and opened again; this stand-in fails the same way
    project = Path(location.group(1)) / "PolarfireProg" / "PolarfireProg.pro"
    project.parent.mkdir(parents=True, exist_ok=True)
    project.write_text(f'<project><programmer status="enable" type="FlashPro6Lite" revision="UndefRev" connection="usb1.1">'
                       f'<name>{named.group(1)}</name><id>{named.group(1)}</id></programmer></project>\n', encoding="utf-8")
    steps = [ln.split()[0] for ln in text.splitlines() if ln.strip() and not ln.startswith(("#", " "))]

    def at(command: str) -> int:
        return steps.index(command) if command in steps else -1

    opened = re.search(r"open_project -project \{([^}]*)\}", text)
    if opened is not None and not Path(opened.group(1)).is_file():
        print(f"Error:  The project '{opened.group(1)}' does not exist.")
        print("Error:  The command 'open_project' failed.")
        print("Error:  The Execute Script command failed.")
        return 1
    if at("scan_chain_prg") >= 0 and not 0 <= at("close_project") < at("open_project") < at("scan_chain_prg"):
        print(f"Error:  programmer '{named.group(1)}' : Scan Chain FAILED (stand-in: the project was not closed and opened "
              "again after auto_construct_job_project, which FlashPro Express 2026.1 needs).")
        print("Error:  The command 'scan_chain_prg' failed.")
        print("Error:  The Execute Script command failed.")
        return 1
    # the frequency is in Hz, and a FlashPro6 takes 1000000 to 20000000 in steps of 1000000 (what FlashPro Express said on a
    # board when it was given 10); its manual says MHz
    freq = re.search(r"configure_flashpro([56])_prg -force_freq \{ON\} -freq \{([^}]*)\}", text)
    if freq and freq.group(1) == "6" and freq.group(2) not in [str(n * 1000000) for n in range(1, 21)]:
        print(f"Error:  freq: Invalid argument value: '{freq.group(2)}' (expecting 1000000, 2000000, 3000000, ... or 20000000).")
        print("Error:  The command 'configure_flashpro6_prg' failed.")
        print("Error:  Failure when executing Tcl script. [ Line 8 ]")
        print("Error:  The Execute Script command failed.")
        return 1
    if "set_programming_action" not in text:
        if os.environ.get("FAKE_FPE_SCAN_ERROR") == "1":   # a command of the script fails and FlashPro Express says why
            print("Error:  The command 'scan_chain_prg' failed on request.")
            print("Error:  The Execute Script command failed.")
            return 1
        for i, d in enumerate(devices, 1):
            print(f"programmer '{named.group(1)}' : Device {i}: F81A1CF Mfr: Microsemi Part: {d}")   # as seen on a board
        return 0
    device = re.search(r"enable_device -name \{([^}]*)\}", text)
    if device is None or device.group(1) not in devices:
        print(f"fake FPExpress: no device {device.group(1) if device else '(none)'}", file=sys.stderr)
        return 3
    programmer, dev = named.group(1), device.group(1)
    if "set_programming_file" not in text:   # what FlashPro Express says on a board, also for DEVICE_INFO
        print("Error:  A programming file must be loaded before running the command 'set_programming_action'.")
        print("Error:  The command 'set_programming_action' failed.")
        print("Error:  The Execute Script command failed.")
        return finish(1, text)
    action = re.search(r"-action \{([^}]*)\}", text).group(1)
    file_device = os.environ.get("FAKE_FPE_FILE_DEVICE")
    if file_device:   # a programming file for another device, as seen on a board: the check of the chain fails
        file = re.search(r"-file \{([^}]*)\}", text).group(1)
        print(f"Warning:  The programming file '{file}' is for '{file_device}' devices. Your current device '{dev}' doesn't match the programming file.")
        print(f"          Your current device will be changed to '{file_device}' to match your programming file. Do you want to proceed? [YES]")
        print(f"programmer '{programmer}' : Check Chain...")
        print(f"Error:  programmer '{programmer}' : Device 1: Found: {dev}, Expected: {file_device}")
        print(f"Error:  programmer '{programmer}' : Scan and Check Chain FAILED.")
        print("Error:  Failed to run Action.")
        print("Error:  The command 'run_selected_actions' failed.")
        print("Error:  The Execute Script command failed.")
        return finish(1, text)
    rc = int(os.environ.get("FAKE_FPE_RC", "0"))
    if silent:
        return finish(rc, text)
    # run_selected_actions without -name runs the action on every connected programmer (the Tcl reference says so, and
    # fpgenprog did it on a board with two FlashPros); with -name only on the ones named
    running = re.findall(r"run_selected_actions .*?-name \{([^}]*)\}", text) or programmers
    for who in running:
        print(f"programmer '{who}' : device '{dev}' : Executing action {action}")
    print(f"fake FPExpress: {action} {dev} on {', '.join(running)}")
    if os.environ.get("FAKE_FPE_CRASH") == "1":
        os.kill(os.getpid(), signal.SIGSEGV)   # the printed line is lost if stdout is a pipe: Python buffers it in blocks
    if rc != 0:
        print(f"programmer '{programmer}' : device '{dev}' : Executing action {action} FAILED.")
        print("Error:  The command 'run_selected_actions' failed.")
        print("Error:  The Execute Script command failed.")
        return finish(rc, text)
    print(f"programmer '{programmer}' : device '{dev}' : Executing action {action} PASSED.")
    print("The 'run_selected_actions' command succeeded.")
    if os.environ.get("FAKE_FPE_NO_OK") != "1":
        print("The Execute Script command succeeded.")
    return finish(0, text)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
