# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""The facts of PolarFire SoC and the defaults of the runtime that the partition data are made of.

One place for both paths that write partition data: config/gen/standalone.py (an image without a
system description) and the reader of system.yaml (yaml_reader.py), so that the two give the same
values for the same partition (presets.py).
"""

HARTS = ("e51", "u54")
NUMBER_OF_HARTS = 5
E51_HART = 0
U54_HARTS = (1, 2, 3, 4)
PROFILES = ("light", "light-tasking", "embedded")
PRIVILEGES = ("m", "u")
MEMORY_PROFILES = ("lim", "scratchpad", "envm")

# The console: the LO base of the MMUART (MPFS_Registers.MMUARTn_LO_Base), the divisor and the
# fraction of the 115200 baud rate at the ~40 MHz APB clock of the MSS at reset. MMUART4 (which
# the board does not bring out) uses the fractional baud rate mode (21 and 45/64), so that it is
# exercised; the other four use the integer divisor 22.
CONSOLES = {
    "mmuart0": (0x20000000, 22, 0),
    "mmuart1": (0x20100000, 22, 0),
    "mmuart2": (0x20102000, 22, 0),
    "mmuart3": (0x20104000, 22, 0),
    "mmuart4": (0x20106000, 21, 45),
}
CONSOLE_NONE, CONSOLE_MMUART, CONSOLE_RAM_FIFO = 0, 1, 2
CONSOLE_CHOICES = (*CONSOLES, "none", "ram_fifo")


def default_console(lowest_hart: int) -> str:
    """The console of a partition whose lowest hart is <lowest_hart>: hart n has MMUARTn."""
    return f"mmuart{lowest_hart}"


# The secondary stack of the environment task, by profile (the defaults of System.BB.Parameters).
SECONDARY_STACK = {"light": 16384, "light-tasking": 8192, "embedded": 16384}
DEFAULT_STACK_SIZE = 16384
# The interrupt stack, by profile. The embedded profile needs more than the others because the first
# exception that is raised in a trap handler runs libgcc's unwinder on it: the peak measured with
# examples/interrupt_stack_embedded_test is 8256 bytes (E51) and 8608 bytes (U54); the default is the
# larger one plus 50 %, a multiple of 16. The other profiles measure 600 and 856 bytes and keep 8 KiB,
# which also holds nested trap frames (crates/mpfs_rts/README.md, "Interrupt stack").
INTERRUPT_STACK = {"light": 8192, "light-tasking": 8192, "embedded": 12912}
# Stack sizes are multiples of this (the RISC-V psABI aligns the stack pointer to 16 bytes).
STACK_ALIGNMENT = 16

# The L2 cache is 16 ways of 128 KB, shared out between cache, LIM and scratchpad, in every PolarFire
# SoC whatever the board. At reset the LIM has 15 of them (1920 KB) and the cache one; the MSS
# Configurator XML sets the split that a system uses (derive/l2.py). The scratchpad profile takes two ways from the LIM.
WAYS = 16
WAY_SIZE = 0x20000
MAX_LIM_WAYS = 15
MEMORY_WAYS = {"lim": (1, 15, 0), "scratchpad": (1, 13, 2), "envm": (1, 15, 0)}

# The origins of the memories that windows are placed in (the literals of crates/mpfs_rts/ld/mpfs-memory.ld;
# the scratchpad is ZERO_DEVICE_BOTTOM of Microchip's mss_l2_cache.h). The LIM and the scratchpad are as long
# as their L2 ways.
ENVM_ORIGIN = 0x20220100
LIM_ORIGIN = 0x08000000
SCRATCHPAD_ORIGIN = 0x0A000000
DTIM_ORIGIN = 0x01000000

# The local memories: ITIM per hart (the E51 has one of 8 KB, a U54 one of 28 KB, in windows of 32 KB
# from 0x0180_0000), DTIM on the E51 only (8 KB).
ITIM_ORIGIN = 0x01800000
ITIM_WINDOW = 0x8000
ITIM_MAX = (0x2000, 0x7000, 0x7000, 0x7000, 0x7000)
DTIM_MAX = 0x2000
ENVM_LENGTH = 0x1FF00

# The rate of mtime that the runtime assumes: System.BB.Board_Parameters.Clock_Frequency
# (crates/mpfs_rts/mpfs/gnat/s-bbbopa.ads), of which Ada.Real_Time.Time_Unit is the inverse. The RTC
# divider of the configuration must give exactly this rate from the reference clock.
RUNTIME_CLOCK_HZ = 1_000_000

# The PMP of a hart: the entries of the silicon (16, measured on the Icicle Kit on the E51 and U54 hart 1,
# docs/lab/results/pmp-entries.md; also the MSS TRM DS60001702S §3.1.4), the entries QEMU 10.1 models (8,
# what `--pmp-entries 8` checks against), and the bits of pmpaddr that each hart implements (WARL): a U54
# holds bits 35:0 (measured on hart 1: the all-ones value of the XML reads back 0xf_ffff_ffff; harts 2 to 4
# are the same core and not measured), the E51 is not measured yet and is taken with all 54 bits of RV64.
PMP_ENTRIES = 16
QEMU_PMP_ENTRIES = 8
PMPADDR_BITS = (54, 36, 36, 36, 36)

# The checks of the PMP take a block of registers in whole pages of 4 KiB: the APB peripherals of the SVD
# start at multiples of it, and a U partition reads mtime through the page that holds it.
PAGE = 0x1000

# Nothing in the runtime uses more than one hart yet: a console that needs a second one (a FIFO in
# RAM that the other hart drains) is refused until SMP exists.
SMP_AVAILABLE = False
