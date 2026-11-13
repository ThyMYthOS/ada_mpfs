#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# @req RTS-019
"""The partition data of one image that is built without the configuration generator (standalone).

  standalone.py --hart e51|u54 [--profile P] [--harts SET | --mask N] [--role primary|secondary|N]
                [--memory lim|scratchpad|envm] [--console C] [--console-init 0|1]
                [--stack-size N] [--interrupt-stack-size N] [--secondary-stack-size N]
                [--cache-ways N] [--lim-ways N] [--scratchpad-ways N]
                [--itim-length N] [--dtim-length N] [--omit SYMBOL]
                [--check] [--output FILE] [--defsyms FILE]

Two files come out of the parameters of `./x build`:

  the package MPFS_Partition (--output, default build/partition/mpfs_partition.ads): the values of the
  partition as named numbers and the checks on them as flat static constants and `pragma
  Compile_Time_Error` (a non-static condition is silently ignored by GNAT, so there is none). The
  package is `pragma Pure` and has no body.

  the list of link symbols (--defsyms, default next to --output: mpfs_partition.defsyms), one
  NAME=VALUE per line: the --defsym values of the link, in a fixed order.

The format of both is the contract with the configuration generator, which writes the same two
files from a system description; this tool is the path that needs no description (config/README.md).
Both outputs are deterministic (no time stamp, a fixed order), so --check compares byte for byte.

The tool refuses what it cannot write: an unknown name, a value that is no number. It does NOT refuse a
value that violates a rule of the hardware (a mask of E51 and U54 harts, a stack size that is not a
multiple of 16, a console that needs more than one hart, more L2 ways than there are): that is the
job of the checks in the package, so that the build of the image fails in the compiler with the
message of the check, in the same way for every generator. --omit leaves one link symbol out, a test
seam of the negative builds (the link must fail).

Exit status: 0 ok (with --check: current), 1 not current (--check), 2 invalid arguments.
"""
import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))
from gen_ada import ada, cli, errors, spdx  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OUTPUT = ROOT / "build" / "partition" / "mpfs_partition.ads"
DEFSYMS_NAME = "mpfs_partition.defsyms"
TOOL = "standalone"
SCRIPT = "config/gen/standalone.py"

HARTS = ("e51", "u54")
PROFILES = ("light", "light-tasking", "embedded")
MEMORY_PROFILES = ("lim", "scratchpad", "envm")
ROLES = {"primary": 1, "secondary": 0}

# The console: the LO base of the MMUART (MPFS_Registers.MMUARTn_LO_Base), the divisor and the
# fraction of the 115200 baud rate at the ~40 MHz APB clock of an Icicle Kit at reset. MMUART4 (which
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

# The secondary stack of the environment task, by profile (the defaults of System.BB.Parameters).
SECONDARY_STACK = {"light": 16384, "light-tasking": 8192, "embedded": 16384}
DEFAULT_STACK_SIZE = 16384
# The interrupt stack, by profile. The embedded profile needs more than the others because the first
# exception that is raised in a trap handler runs libgcc's unwinder on it: the peak measured with
# examples/interrupt_stack_embedded_test is 8256 bytes (E51) and 8608 bytes (U54); the default is the
# larger one plus 50 %, a multiple of 16. The other profiles measure 600 and 856 bytes and keep 8 KiB,
# which also holds nested trap frames (crates/mpfs_rts/README.md, "Interrupt stack").
INTERRUPT_STACK = {"light": 8192, "light-tasking": 8192, "embedded": 12912}

# The L2 cache is 16 ways of 128 KB, shared out between cache, LIM and scratchpad. At reset the LIM
# has 15 of them (1920 KB) and the cache one. The scratchpad profile takes two ways from the LIM.
WAYS = 16
WAY_SIZE = 0x20000
MAX_LIM_WAYS = 15
MEMORY_WAYS = {"lim": (1, 15, 0), "scratchpad": (1, 13, 2), "envm": (1, 15, 0)}

# The local memories: ITIM per hart (the E51 has one of 8 KB, a U54 one of 28 KB, in windows of 32 KB
# from 0x0180_0000), DTIM on the E51 only (8 KB).
ITIM_ORIGIN = 0x01800000
ITIM_WINDOW = 0x8000
ITIM_MAX = (0x2000, 0x7000, 0x7000, 0x7000, 0x7000)
DTIM_MAX = 0x2000
ENVM_LENGTH = 0x1FF00
NUMBER_OF_HARTS = 5

# Nothing in the runtime uses more than one hart yet: a console that needs a second one (a FIFO in
# RAM that the other hart drains) is refused until SMP exists.
SMP_AVAILABLE = False

# The link symbols that the partition data set (this order is the order of the list), and the symbols
# that the placement script defines. The second list is the part of the interface that the data does
# not carry; it is here so that the contract has one list (config/README.md) and a test can check that
# the linker scripts still define each of them.
VALUE_SYMBOLS = (
    "__mpfs_harts_mask", "__mpfs_boot_role", "__stack_size", "__interrupt_stack_size",
    "__mpfs_console_base", "__mpfs_console_init", "__mpfs_console_dlr", "__mpfs_console_dfr",
    "MPFS_ENVM_LENGTH", "MPFS_DTIM_LENGTH",
    "MPFS_E51_ITIM_LENGTH", "MPFS_U54_1_ITIM_LENGTH", "MPFS_U54_2_ITIM_LENGTH",
    "MPFS_U54_3_ITIM_LENGTH", "MPFS_U54_4_ITIM_LENGTH",
    "MPFS_LOCAL_ITIM_ORIGIN", "MPFS_LOCAL_ITIM_LENGTH",
    "MPFS_LIM_LENGTH", "MPFS_SCRATCHPAD_LENGTH",
    "MPFS_DDR_CACHED_LENGTH", "MPFS_DDR_NC_LENGTH", "MPFS_DDR_WCB_LENGTH",
)
LAYOUT_SYMBOLS = (
    "__data_load", "__data_start", "__data_end", "__bss_start", "__bss_end", "__heap_start",
    "__heap_end", "__stack_end", "__interrupt_stack_start", "__interrupt_stack_end",
    "__global_pointer$", "__eh_frame_start", "__eh_frame_end",
)


def number(text: str) -> int:
    """A non-negative integer in decimal or with 0x (Python's int with base 0, underscores allowed)."""
    try:
        value = int(text, 0)
    except ValueError:
        raise argparse.ArgumentTypeError(f"{text!r} is not an integer") from None
    if value < 0:
        raise argparse.ArgumentTypeError(f"{text!r} is negative")
    return value


def hart_set(text: str) -> int:
    """The mask of a set of harts 0 to 4: N, N-M or a comma list of those."""
    mask = 0
    for item in text.split(","):
        low, dash, high = item.partition("-")
        try:
            first, last = int(low), int(high) if dash else int(low)
        except ValueError:
            raise argparse.ArgumentTypeError(f"{text!r} is not a set of harts (0-4, e.g. 1, 1-4 or 1,3)") from None
        if not 0 <= first <= last < NUMBER_OF_HARTS:
            raise argparse.ArgumentTypeError(f"{text!r} is not a set of harts 0 to 4 (e.g. 1, 1-4 or 1,3)")
        for hart in range(first, last + 1):
            mask |= 1 << hart
    return mask


def role(text: str) -> int:
    """primary, secondary, or the number itself (the check in the package refuses a value above 1)."""
    return ROLES[text] if text in ROLES else number(text)


class Partition:
    """The values of one partition: what the parameters say, and what follows from them."""

    def __init__(self, args: argparse.Namespace):
        self.hart = args.hart
        self.profile = args.profile
        self.memory = args.memory
        if args.mask is not None:
            self.mask = args.mask
        elif args.harts is not None:
            self.mask = args.harts
        else:
            self.mask = 1 if args.hart == "e51" else 2
        self.role = args.role
        self.console_name = args.console or f"mmuart{self.local_hart}"
        self.console_init = args.console_init
        self.stack_size = args.stack_size
        self.interrupt_stack_size = (INTERRUPT_STACK[args.profile] if args.interrupt_stack_size is None
                                     else args.interrupt_stack_size)
        self.secondary_stack_size = (SECONDARY_STACK[args.profile] if args.secondary_stack_size is None
                                     else args.secondary_stack_size)
        cache, lim, scratchpad = MEMORY_WAYS[args.memory]
        self.cache_ways = cache if args.cache_ways is None else args.cache_ways
        self.lim_ways = lim if args.lim_ways is None else args.lim_ways
        self.scratchpad_ways = scratchpad if args.scratchpad_ways is None else args.scratchpad_ways
        self.dtim_length = args.dtim_length
        self.itim_length = [args.itim_length if self.mask >> h & 1 else 0 for h in range(NUMBER_OF_HARTS)]
        self.omit = args.omit

    @property
    def console(self) -> int:
        return {"none": CONSOLE_NONE, "ram_fifo": CONSOLE_RAM_FIFO}.get(self.console_name, CONSOLE_MMUART)

    @property
    def console_values(self) -> tuple[int, int, int]:
        """Base, divisor and fraction; all 0 where the runtime has no MMUART to drive."""
        return CONSOLES.get(self.console_name, (0, 22, 0))

    @property
    def lim_length(self) -> int:
        return self.lim_ways * WAY_SIZE

    @property
    def scratchpad_length(self) -> int:
        return self.scratchpad_ways * WAY_SIZE

    @property
    def local_hart(self) -> int:
        """The lowest hart of the mask: the one whose ITIM the generic window `local_itim` stands for."""
        for hart in range(NUMBER_OF_HARTS):
            if self.mask >> hart & 1:
                return hart
        return 0

    @property
    def local_itim(self) -> tuple[int, int]:
        """Origin and length of the generic ITIM window. A window of length 0 keeps the origin of the E51
        window, so that an image without ITIM does not depend on the hart (the length alone decides)."""
        length = self.itim_length[self.local_hart]
        if length == 0:
            return ITIM_ORIGIN, 0
        return ITIM_ORIGIN + ITIM_WINDOW * self.local_hart, length

    def symbols(self) -> list[tuple[str, str]]:
        """(name, value) in the order of VALUE_SYMBOLS, without the one --omit names."""
        base, dlr, dfr = self.console_values
        origin, local_length = self.local_itim
        values = {
            "__mpfs_harts_mask": str(self.mask),
            "__mpfs_boot_role": str(self.role),
            "__stack_size": str(self.stack_size),
            "__interrupt_stack_size": str(self.interrupt_stack_size),
            "__mpfs_console_base": hex(base),
            "__mpfs_console_init": str(self.console_init),
            "__mpfs_console_dlr": str(dlr),
            "__mpfs_console_dfr": str(dfr),
            "MPFS_ENVM_LENGTH": hex(ENVM_LENGTH),
            "MPFS_DTIM_LENGTH": hex(self.dtim_length),
            "MPFS_E51_ITIM_LENGTH": hex(self.itim_length[0]),
            "MPFS_U54_1_ITIM_LENGTH": hex(self.itim_length[1]),
            "MPFS_U54_2_ITIM_LENGTH": hex(self.itim_length[2]),
            "MPFS_U54_3_ITIM_LENGTH": hex(self.itim_length[3]),
            "MPFS_U54_4_ITIM_LENGTH": hex(self.itim_length[4]),
            "MPFS_LOCAL_ITIM_ORIGIN": hex(origin),
            "MPFS_LOCAL_ITIM_LENGTH": hex(local_length),
            "MPFS_LIM_LENGTH": hex(self.lim_length),
            "MPFS_SCRATCHPAD_LENGTH": hex(self.scratchpad_length),
            "MPFS_DDR_CACHED_LENGTH": "0",
            "MPFS_DDR_NC_LENGTH": "0",
            "MPFS_DDR_WCB_LENGTH": "0",
        }
        return [(name, values[name]) for name in VALUE_SYMBOLS if name != self.omit]


def hexa(value: int) -> str:
    """An Ada based literal, upper case, with digit groups of four."""
    digits = f"{value:X}"
    if len(digits) > 4:
        digits = digits.zfill((len(digits) + 3) // 4 * 4)
        digits = "_".join(digits[i:i + 4] for i in range(0, len(digits), 4))
    return f"16#{digits}#"


def render_defsyms(part: Partition) -> str:
    out = spdx.header("shell", "Apache-2.0")
    out += "#\n"
    out += "".join(f"# {line}\n" for line in (
        f"The link symbols of the partition, one NAME=VALUE per line, written by {SCRIPT}.",
        "Each is a --defsym of the link. The layout symbols come from the placement script.",
        "Do not edit: run the generator (CI fails if a committed copy is not current)."))
    out += "".join(f"{name}={value}\n" for name, value in part.symbols())
    return out


def constant(name: str, value: str, text: str = "", width: int = 24) -> list[str]:
    line = f"   {name:<{width}} : constant := {value};"
    return [line] + ada.comment(text, "   ") if text else [line]


def check(name: str, condition: str, message: str, width: int = 24) -> list[str]:
    """A check as a flat static constant and the pragma on it."""
    return [f"   {name:<{width}} : constant Boolean :=",
            f"     {condition};",
            "   pragma Compile_Time_Error",
            f"     ({name},",
            f"      \"{message}\");", ""]


def render_package(part: Partition) -> str:
    out = spdx.header("ada", "Apache-2.0").splitlines()
    out += ["--", *ada.comment(ada.generated_notice(
        SCRIPT, "the parameters of the build of this image (hart, profile, console, memory "
        "profile and stack sizes)"), "")]
    out += ["--", *ada.comment(
        "The partition data of one image and the checks on them. The package is pure and has no "
        "body: the values are named numbers, the checks are flat static constants, each with a "
        "Compile_Time_Error on it, because GNAT ignores one whose condition is not static. The "
        "linker scripts and the start code read the same values as link symbols, which the "
        "list mpfs_partition.defsyms carries.", "")]
    out += ["", "package MPFS_Partition is", "", "   pragma Pure;", ""]

    out += ada.banner("Harts")
    out += [""]
    out += constant("Harts_Mask", hexa(part.mask), "Bit n is hart n: bit 0 is the E51, bits 1 to 4 are the U54 cores.")
    out += constant("Boot_Role", str(part.role), "1 primary, 0 secondary (__mpfs_boot_role).")
    out += constant("Hart_E51", "16#01#", "The E51 in a mask.")
    out += constant("Hart_U54", "16#1E#", "The U54 cores in a mask.")
    out += [""]

    out += ada.banner("Console")
    out += [""]
    out += constant("Console_None", str(CONSOLE_NONE))
    out += constant("Console_MMUART", str(CONSOLE_MMUART))
    out += constant("Console_RAM_FIFO", str(CONSOLE_RAM_FIFO))
    out += constant("Console_Kind", str(part.console), f"The console is {part.console_name}.")
    base, dlr, dfr = part.console_values
    out += constant("Console_Base", hexa(base), "The LO base of the MMUART; 0 without one.")
    out += constant("Console_Init", str(part.console_init),
                    "1 the runtime sets divisor and format; 0 the boot stage has done it.")
    out += constant("Console_Divisor", str(dlr), "The integer divisor of the baud rate.")
    out += constant("Console_Fraction", str(dfr), "The fraction in 64ths of the divisor.")
    out += [""]

    out += ada.banner("Stacks")
    out += [""]
    out += constant("Stack_Size", str(part.stack_size), "Bytes, the stack of the environment task.")
    out += constant("Interrupt_Stack_Size", str(part.interrupt_stack_size), "Bytes, per hart.")
    out += constant("Secondary_Stack_Size", str(part.secondary_stack_size),
                    "Bytes, the secondary stack of the environment task. Not a link symbol: the "
                    "runtime takes the default of its profile, so only the check reads it.")
    out += [""]

    out += ada.banner("Memory")
    out += [""]
    out += constant("L2_Ways", str(WAYS), "The L2 is 16 ways of 128 KB.")
    out += constant("Cache_Ways", str(part.cache_ways))
    out += constant("LIM_Ways", str(part.lim_ways), "Ways used as LIM (L2 addressed as SRAM).")
    out += constant("Scratchpad_Ways", str(part.scratchpad_ways))
    out += constant("Max_LIM_Ways", str(MAX_LIM_WAYS), "At least one way stays cache.")
    out += constant("LIM_Length", hexa(part.lim_length))
    out += constant("Scratchpad_Length", hexa(part.scratchpad_length))
    out += constant("DTIM_Length", hexa(part.dtim_length), "The E51 only.")
    out += constant("DTIM_Max", hexa(DTIM_MAX))
    for hart in range(NUMBER_OF_HARTS):
        out += constant(f"ITIM_Length_{hart}", hexa(part.itim_length[hart]),
                        f"The ITIM of hart {hart}." if hart in (0, 1) else "")
    for hart in range(NUMBER_OF_HARTS):
        out += constant(f"ITIM_Max_{hart}", hexa(ITIM_MAX[hart]), "E51: 8 KB, U54: 28 KB." if hart == 0 else "")
    out += constant("SMP_Available", "0", "1 once the runtime has more than one CPU.")
    out += [""]

    out += ada.banner("Checks")
    out += [""]
    out += ada.comment("Each check is a flat static Boolean constant, then the pragma. A false condition "
                       "costs nothing; a true one stops the compilation with the message.")
    out += [""]
    out += check("Mask_Names_No_Hart",
                 "Harts_Mask = 0 or else Harts_Mask > 16#1F#",
                 "the harts mask names no hart or a hart above 4")
    out += check("Mask_Mixes_E51_And_U54",
                 "Harts_Mask mod 2 = 1 and then Harts_Mask / 2 /= 0",
                 "a partition mask must not mix the E51 and U54 harts")
    out += check("Boot_Role_Invalid", "Boot_Role > 1",
                 "__mpfs_boot_role must be 1 (primary) or 0 (secondary)")
    out += check("Stack_Size_Invalid", "Stack_Size = 0 or else Stack_Size mod 16 /= 0",
                 "the stack size must be a non-zero multiple of 16")
    out += check("Interrupt_Stack_Size_Invalid",
                 "Interrupt_Stack_Size = 0 or else Interrupt_Stack_Size mod 16 /= 0",
                 "the interrupt stack size must be a non-zero multiple of 16")
    out += check("Secondary_Stack_Size_Invalid",
                 "Secondary_Stack_Size = 0 or else Secondary_Stack_Size mod 16 /= 0",
                 "the secondary stack size must be a non-zero multiple of 16")
    out += check("Console_RAM_FIFO_Without_SMP",
                 "Console_Kind = Console_RAM_FIFO and then SMP_Available = 0",
                 "the console ram_fifo needs a second hart; SMP does not exist yet")
    out += check("L2_Way_Sum_Not_16",
                 "Cache_Ways + LIM_Ways + Scratchpad_Ways /= L2_Ways",
                 "the L2 ways (cache, LIM, scratchpad) must add up to 16")
    out += check("LIM_Ways_Above_15", "LIM_Ways > Max_LIM_Ways",
                 "at most 15 L2 ways can be LIM: one way stays cache")
    out += check("DTIM_Not_On_E51",
                 "DTIM_Length /= 0 and then Harts_Mask mod 2 = 0",
                 "the DTIM exists on the E51 only")
    out += check("DTIM_Too_Large", "DTIM_Length > DTIM_Max",
                 "the DTIM of the E51 is 8 KB at most")
    for hart in range(NUMBER_OF_HARTS):
        kind = "E51" if hart == 0 else f"U54 hart {hart}"
        out += check(f"ITIM_{hart}_Too_Large", f"ITIM_Length_{hart} > ITIM_Max_{hart}",
                     f"the ITIM of {kind} is larger than the ITIM of that hart")
    out[-1:] = []
    out += ["", "end MPFS_Partition;", ""]
    return "\n".join(out)


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="standalone.py", description=__doc__.split("\n")[0])
    p.add_argument("--hart", required=True, choices=HARTS, help="hart class of the image")
    p.add_argument("--profile", choices=PROFILES, default="light", help="runtime profile (secondary stack default)")
    sel = p.add_mutually_exclusive_group()
    sel.add_argument("--harts", type=hart_set, help="the harts 0-4 of the partition (default: hart 0 for the E51, "
                     "hart 1 for the U54)")
    sel.add_argument("--mask", type=number, help="the mask itself (a test seam for masks the set cannot say)")
    p.add_argument("--role", type=role, default=1, help="primary, secondary or the number of __mpfs_boot_role")
    p.add_argument("--memory", choices=MEMORY_PROFILES, default="lim", help="memory profile (placement script)")
    p.add_argument("--console", choices=CONSOLE_CHOICES, help="default: the MMUART of the lowest hart of the mask (hart n: mmuartn)")
    p.add_argument("--console-init", type=int, choices=(0, 1), default=1,
                   help="1 the runtime programs the MMUART, 0 the boot stage has")
    p.add_argument("--stack-size", type=number, default=DEFAULT_STACK_SIZE)
    p.add_argument("--interrupt-stack-size", type=number, help="default: that of the profile")
    p.add_argument("--secondary-stack-size", type=number, help="default: that of the profile")
    p.add_argument("--cache-ways", type=number, help="L2 ways used as cache (default: by memory profile)")
    p.add_argument("--lim-ways", type=number, help="L2 ways used as LIM (default: 15 at reset)")
    p.add_argument("--scratchpad-ways", type=number, help="L2 ways used as scratchpad (default: by memory profile)")
    p.add_argument("--itim-length", type=number, default=0, help="bytes of ITIM of each hart of the partition")
    p.add_argument("--dtim-length", type=number, default=0, help="bytes of DTIM (E51)")
    p.add_argument("--omit", choices=VALUE_SYMBOLS, help="leave this link symbol out (test seam: the link must fail)")
    cli.add_check(p, "compare with the committed outputs instead of writing them")
    cli.add_output(p, DEFAULT_OUTPUT, "the package (default: build/partition/mpfs_partition.ads)")
    p.add_argument("--defsyms", type=Path, help=f"the list of link symbols (default: {DEFSYMS_NAME} next to --output)")
    return p


def main(argv: list[str]) -> int:
    args = parser().parse_args(argv)
    part = Partition(args)
    package = render_package(part)
    defsyms = render_defsyms(part)
    list_path = args.defsyms or args.output.with_name(DEFSYMS_NAME)
    if args.check:
        status = cli.check_output(package, args.output, tool=TOOL, command=SCRIPT)
        return max(status, cli.check_output(defsyms, list_path, tool=TOOL, command=SCRIPT))
    cli.write_output(package, args.output)
    cli.write_output(defsyms, list_path)
    return errors.OK


if __name__ == "__main__":
    sys.exit(errors.run(main, TOOL, sys.argv[1:]))
