# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Bring the debug module and the MSS back to the power-on state with a reset halt.

Shared by hw/reset.py (`./x hw reset`) and `hw/svd_probe.py --recover`. The sequence was measured on the
Icicle Kit in boot mode 0 after an access had stalled the debug module ("Timed out after 2s waiting for
busy to go low (abstractcs=0x10001002)"), without a power cycle:

  1. riscv dmi_read 0x16        abstractcs: busy clear, cmderr=1 (0x10000102)
  2. riscv dmi_write 0x16 0x700 clear cmderr
  3. reset halt
  4. read SYSREG.SUBBLK_CLOCK_CR: 0x00000001, its power-on value

A reset returns the platform to the power-on state: whatever the probe or the person wrote (clocks, pokes)
and any PLL or boot state is gone. If the check fails, the debug module is toggled off and on
(dmi_write 0x10 0x0, 0x10 0x1, the dmcontrol dmactive bit) and the reset halt is repeated.
"""
import re
from dataclasses import dataclass
from typing import Callable

ABSTRACTCS = 0x16
DMCONTROL = 0x10
CMDERR = 0x700
RESET_TIMEOUT = 30.0  # seconds "reset halt" may take
# What OpenOCD replies to a command it does not know
UNKNOWN_COMMAND = re.compile(r"invalid command name|\bunknown\b|no such command|not recognized", re.IGNORECASE)
POWER_CYCLE = "power-cycle the board and restart OpenOCD"


@dataclass(slots=True)
class Check:
    """A register that must read its power-on value after the reset."""
    name: str
    address: int
    expected: int


def recover(command: Callable[..., str], read: Callable[[int], int], checks: list[Check],
            say: Callable[[str], None] = print) -> bool:
    """Run the sequence; every step is reported with the reply of OpenOCD through <say>.

    <command>(cmd, timeout=None) runs an OpenOCD command and returns its reply (OSError and its
    subclasses for a lost connection or a timeout), <read>(address) reads a 32-bit word (OSError if it
    fails). True if every register of <checks> has its power-on value afterwards, else False after saying so.
    """
    def step(cmd: str, timeout: float | None = None) -> str | None:
        """Run one command and say what it replied; None if the command failed."""
        try:
            reply = command(cmd, timeout) if timeout else command(cmd)
        except Exception as e:  # noqa: BLE001 - the connection is gone or the command timed out
            say(f"recover: {cmd}: failed ({type(e).__name__}: {e})")
            return None
        say(f"recover: {cmd} -> {reply!r}")
        return reply

    def verify() -> bool:
        bad = []
        for check in checks:
            try:
                value = read(check.address)
            except Exception as e:  # noqa: BLE001
                say(f"recover: verify {check.name} (0x{check.address:08X}): not readable ({type(e).__name__}: {e})")
                bad.append(check.name)
                continue
            ok = value == check.expected
            say(f"recover: verify {check.name} (0x{check.address:08X}) = 0x{value:08X}, power-on value 0x{check.expected:08X}"
                + ("" if ok else ": DIFFERS"))
            if not ok:
                bad.append(check.name)
        return not bad

    first = step(f"riscv dmi_read 0x{ABSTRACTCS:X}")
    dmi = first is not None and not UNKNOWN_COMMAND.search(first)
    if first is not None and not dmi:
        say("recover: riscv dmi_read is not available in this OpenOCD (invalid command): the debug module is not "
            "cleared and not toggled, only the reset halt is tried")
    if dmi:
        step(f"riscv dmi_write 0x{ABSTRACTCS:X} 0x{CMDERR:X}")
    step("reset halt", RESET_TIMEOUT)
    if verify():
        say("recover: the platform is in its power-on state (reset halt)")
        return True
    if dmi:
        say("recover: verification failed: toggling the debug module (dmcontrol dmactive off and on), then reset halt again")
        step(f"riscv dmi_write 0x{DMCONTROL:X} 0x0")
        step(f"riscv dmi_write 0x{DMCONTROL:X} 0x1")
        step("reset halt", RESET_TIMEOUT)
        if verify():
            say("recover: the platform is in its power-on state (after toggling the debug module)")
            return True
    say(f"recover: verification failed: {POWER_CYCLE}")
    return False
