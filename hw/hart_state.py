# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""State that a reset of the Icicle Kit leaves behind and a test must not inherit.

`reset halt` does not clear the enables of the PLIC (a source enabled for another hart's context takes the
interrupt away from the hart that runs) and the silicon does not reset fcsr of the U54 (an invalid frm makes the
FP instructions with dynamic rounding illegal). clear() writes both; ./x hw reset, ./x hw initialize and
hw/run_image.py call it.
"""
from typing import Callable

PLIC_ENABLE = 0x0C002000   # 9 contexts (hart 0 M; harts 1-4 M and S), 0x80 apart, 6 words of 32 sources each
PLIC_CONTEXTS = 9
PLIC_WORDS = 6
U54_TARGETS = ("mpfs.hart1_u54_1", "mpfs.hart2_u54_2", "mpfs.hart3_u54_3", "mpfs.hart4_u54_4")


def clear_plic(command: Callable[[str], str]) -> None:
    """Disable every source of every context."""
    for ctx in range(PLIC_CONTEXTS):
        command("; ".join(f"mww 0x{PLIC_ENABLE + ctx * 0x80 + 4 * w:x} 0" for w in range(PLIC_WORDS)))


def clear_fcsr(command: Callable[[str], str], return_to: str) -> list[str]:
    """Write fcsr = 0 on the four U54 (the E51 has no FPU) and select <return_to> again.

    A hart has to be halted for this; the problems (a hart that runs, a target that is not there) are returned
    as text, one per hart, so the caller decides whether they matter.
    """
    problems = []
    try:
        for target in U54_TARGETS:
            reply = command(f"targets {target}")
            if "not found" in reply.lower() or "invalid" in reply.lower():
                problems.append(f"{target}: {reply.strip()}")
                continue
            reply = command("reg fcsr 0")
            if "0x0000000000000000" not in reply:
                problems.append(f"{target}: fcsr not cleared ({reply.strip()!r})")
    finally:
        command(f"targets {return_to}")
    return problems


def clear(command: Callable[[str], str], return_to: str) -> list[str]:
    """clear_plic and clear_fcsr; the problems of clear_fcsr."""
    clear_plic(command)
    return clear_fcsr(command, return_to)
