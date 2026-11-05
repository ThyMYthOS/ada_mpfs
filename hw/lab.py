# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""The lab setup and the pinned toolchain, shared by the scripts of hw/.

lab.conf holds what differs between machines (the SoftConsole path, the OpenOCD
port, the serial ports: devices, or TCP ports that socat tunnels from another machine). It is not in the repository: lab.conf.example is, and gives
the default of every key. The RISC-V cross compiler comes from the version pinned
in tools/toolchain.env, never from "the last directory that matches a glob".
"""
import glob
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent

EXAMPLE = HERE / "lab.conf.example"


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
    """The lab settings: lab.conf.example, then hw/lab.conf (or the file named by <path> or
    the environment variable LAB_CONF) on top. hw/lab.conf may be missing, a named file may
    not: that is an error, not a fallback to the defaults."""
    named = path or os.environ.get("LAB_CONF")
    conf = Path(named) if named else HERE / "lab.conf"
    if not EXAMPLE.is_file():
        raise SystemExit(f"lab: {EXAMPLE} does not exist")
    values = read_env_file(EXAMPLE)
    if conf.is_file():
        values.update(read_env_file(conf))
    elif named:
        raise SystemExit(f"lab: lab.conf '{conf}' does not exist")
    for key in ("OCD_PORT", "UART_COUNT"):
        if not values[key].isdigit():
            raise SystemExit(f"lab: {key} must be a number, got '{values[key]}'")
    count = int(values["UART_COUNT"])
    overrides = uart_overrides(values)
    for n, spec in overrides.items():
        if n >= count:
            raise SystemExit(f"lab: UART{n} is outside MMUART0 .. MMUART{count - 1} (UART_COUNT={count})")
        parse_endpoint(spec, n, f"UART{n}")
    if "{n}" not in values["UART_PATTERN"] and any(n not in overrides for n in range(count)):
        raise SystemExit("lab: UART_PATTERN must contain {n}, the number of the MMUART")
    parse_endpoint(values["UART_PATTERN"], 0, "UART_PATTERN")
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


@dataclass(frozen=True)
class Endpoint:
    """Where the serial text of one MMUART comes from: a device file ("device", <path>) or a TCP
    port on another machine ("tcp", <host>, <port>), where socat tunnels the UART."""
    kind: str
    path: str = ""
    host: str = ""
    port: int = 0

    def __str__(self) -> str:
        if self.kind == "device":
            return self.path
        return f"tcp://[{self.host}]:{self.port}" if ":" in self.host else f"tcp://{self.host}:{self.port}"


def uart_overrides(values: dict[str, str]) -> dict[int, str]:
    """The UART<n> keys of the lab settings: {n: value}."""
    return {int(k[4:]): v for k, v in values.items() if re.fullmatch(r"UART\d+", k)}


def parse_endpoint(spec: str, n: int, key: str = "UART_PATTERN") -> Endpoint:
    """The endpoint that SPEC names for MMUART <n>: {n} is replaced by the number first. A spec that starts
    with tcp: or tcp:// is HOST:PORT of a TCP port (HOST may be a name, an IPv4 address or [IPv6]); any
    other spec is a device path (a glob, resolved by uart_endpoints)."""
    spec = spec.replace("{n}", str(n)).strip()
    if not spec:
        raise SystemExit(f"lab: {key} is empty")
    if not spec.startswith("tcp:"):
        return Endpoint("device", path=spec)
    rest = spec[4:].removeprefix("//")
    host, _, port = rest.rpartition(":")
    host = host.removeprefix("[").removesuffix("]")
    if not host or any(c.isspace() or c == "/" for c in host) or not port.isdigit() or not 1 <= int(port) <= 65535:
        raise SystemExit(f"lab: {key}: '{spec}' is not tcp:HOST:PORT (a port from 1 to 65535)")
    return Endpoint("tcp", host=host, port=int(port))


def uart_endpoints(lab: dict[str, str], ports) -> dict[int, Endpoint]:
    """The endpoint of every MMUART in <ports>: UART<n> of the lab settings if there is one, otherwise
    UART_PATTERN. A device that does not exist is an error here; a TCP port is only tried when connecting."""
    overrides = uart_overrides(lab)
    found = {}
    for n in ports:
        spec = overrides.get(n, lab["UART_PATTERN"])
        ep = parse_endpoint(spec, n, f"UART{n}" if n in overrides else "UART_PATTERN")
        if ep.kind == "device":
            devices = sorted(glob.glob(ep.path))
            if not devices:
                raise SystemExit(f"lab: no serial port for MMUART{n} ({ep.path})")
            ep = Endpoint("device", path=devices[0])
        found[n] = ep
    return found


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
