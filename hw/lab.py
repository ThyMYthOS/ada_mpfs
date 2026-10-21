# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""The lab setup and the pinned toolchain, shared by the scripts of hw/.

lab.conf holds what differs between machines (the SoftConsole path, the OpenOCD
port, the serial ports). The RISC-V cross compiler comes from the version pinned
in tools/toolchain.env, never from "the last directory that matches a glob".
"""
import glob
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent

DEFAULTS = {
    "SC": "/opt/Microchip_SoftConsole-v2022.2",
    "OCD_HOST": "localhost",
    "OCD_PORT": "4444",
    "UART_PATTERN": "/dev/serial/by-id/usb-Silicon_Labs_CP2108_*-if0{n}-port0",
    "UART_COUNT": "4",
}


def read_env_file(path: Path) -> dict[str, str]:
    """NAME=VALUE lines of a file; comments and blank lines are skipped."""
    values = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip()
    return values


def load(path: str | None = None) -> dict[str, str]:
    """The lab settings: the defaults, then lab.conf (or the file named by <path> or
    the environment variable LAB_CONF) on top. A named file that does not exist is an
    error, not a fallback to the defaults."""
    named = path or os.environ.get("LAB_CONF")
    conf = Path(named) if named else HERE / "lab.conf"
    values = dict(DEFAULTS)
    if conf.is_file():
        values.update(read_env_file(conf))
    elif named:
        raise SystemExit(f"lab: lab.conf '{conf}' does not exist")
    for key in ("OCD_PORT", "UART_COUNT"):
        if not values[key].isdigit():
            raise SystemExit(f"lab: {key} must be a number, got '{values[key]}'")
    if "{n}" not in values["UART_PATTERN"]:
        raise SystemExit("lab: UART_PATTERN must contain {n}, the number of the MMUART")
    return values


def toolchain_bin() -> Path:
    """The bin directory of the pinned gnat_riscv64_elf (GNAT_RISCV64_VERSION of
    tools/toolchain.env) below MPFS_ADA_TOOLCHAINS (default: Alire's install dir).
    A missing pinned version is an error, and so is a different one."""
    pins = read_env_file(ROOT / "tools" / "toolchain.env")
    version = pins.get("GNAT_RISCV64_VERSION")
    if not version:
        raise SystemExit("lab: GNAT_RISCV64_VERSION is not pinned in tools/toolchain.env")
    base = os.environ.get("MPFS_ADA_TOOLCHAINS") or os.path.expanduser("~/.local/share/alire/toolchains")
    found = sorted(glob.glob(os.path.join(base, f"gnat_riscv64_elf_{version}_*", "bin")))
    if not found:
        raise SystemExit(
            f"lab: gnat_riscv64_elf {version} (pinned in tools/toolchain.env) is not installed in {base}"
            " (./x toolchain install)")
    return Path(found[0])


def serial_path(lab: dict[str, str], n: int) -> str:
    """The device of MMUART <n> according to UART_PATTERN."""
    found = sorted(glob.glob(lab["UART_PATTERN"].replace("{n}", str(n))))
    if not found:
        raise SystemExit(f"lab: no serial port for MMUART{n} ({lab['UART_PATTERN'].replace('{n}', str(n))})")
    return found[0]


def die(message: str) -> "None":
    """Print the message and exit with status 2 (set-up error, not a failed expectation)."""
    print(message, file=sys.stderr)
    raise SystemExit(2)


def run(main, uses_hart: bool = True) -> int:
    """Run <main> and return its exit status. A SystemExit with a message (a set-up error: no
    OpenOCD, no serial port, no toolchain, bad arguments) is printed and becomes status 2, so
    that status 1 always means "the expectation was not met". Ctrl+C ends the run at once with
    status 130 and one line, not a traceback; the hart is then in whatever state the run had reached
    (halted, or running the image), which the line says (not for monitor.py, which does not touch it)."""
    try:
        return main()
    except KeyboardInterrupt:
        what = ("; the hart may be halted or still running the image: send 'resume' or 'halt' to OpenOCD, "
                "or reset the board" if uses_hart else "")
        print(f"{os.path.basename(sys.argv[0])}: interrupted (Ctrl+C){what}", file=sys.stderr)
        return 130
    except SystemExit as e:
        if isinstance(e.code, str):
            print(e.code, file=sys.stderr)
            return 2
        raise
