# `config/`

- **Purpose:** System configuration and generator.
- **License:** Apache-2.0

## Standalone partition data

An image that is built without a system description (every example and test of this repository) gets its
partition data from `config/gen/standalone.py`. The configuration generator writes the same two files from a
system description, so what is written here is the contract between the generator and what reads the data: the
runtime, its linker scripts and start code (`crates/mpfs_rts`), and the build. A reader that works with this tool
works with the configuration generator.

**Images that run together.** The tool describes one partition, one image. Nothing compares the memory regions
of two images that run on the same board, so the LIM regions of such images must be kept apart by hand until the
configuration generator checks the windows (open issue
[#89](https://github.com/ThyMYthOS/ada_mpfs/issues/89)).

### The two files

`./x build` runs the tool with the parameters of the build and writes, to `build/partition/<example>-<hart>/`:

| File | Content |
|---|---|
| `mpfs_partition.ads` | The Ada package `MPFS_Partition`: the values of the partition as named numbers, then the checks on them. `pragma Pure`, no body. |
| `mpfs_partition.defsyms` | The list of link symbols: one `NAME=VALUE` per line in a fixed order, `#` comment lines. Each line is a `--defsym` of the link. |

Both start with the licence header and say that they are generated. Both are deterministic (no time stamp, a
fixed order), so `standalone.py --check --output FILE` compares byte for byte and exits 1 if one of the two files is
missing or differs from what the parameters give.

### Parameters

| `./x build` | `standalone.py` | Default | Gives |
|---|---|---|---|
| `--hart e51\|u54` | `--hart` | | the hart class |
| `--harts 1-4` | `--harts` (harts 0 to 4), `--mask` (the raw mask, a test seam) | E51: hart 0, U54: hart 1 | `__mpfs_harts_mask`, `Harts_Mask` |
| `-P light\|light-tasking\|embedded` | `--profile` | `light` | the default of `Secondary_Stack_Size` |
| `--console mmuart0..4\|none\|ram_fifo` | `--console` | the MMUART of the lowest hart of the mask (hart n: MMUARTn); `./x build` passes `--console` only when it is given or the `example.conf` says `CONSOLE=` | `__mpfs_console_base`, `_dlr`, `_dfr`, `Console_*` |
| `--console-init 0\|1` | `--console-init` | 1 | `__mpfs_console_init` |
| `--memory lim\|scratchpad\|envm` | `--memory` | `lim` | the L2 ways (below) and the placement script `place-<memory>.ld` (`MPFS_PLACEMENT`) |
| `--role primary\|secondary` | `--role` (or the number) | primary | `__mpfs_boot_role` |
| `--stack-size N` | `--stack-size` | 16384 | `__stack_size` |
| `--interrupt-stack-size N` | `--interrupt-stack-size` | by profile: 8192, 8192, 12912 | `__interrupt_stack_size`: the size of the interrupt stack, exactly (the `embedded` profile has the larger default because the first unwind inside a trap runs on it: `crates/mpfs_rts/README.md`, "Interrupt stack") |
| `--secondary-stack-size N` | `--secondary-stack-size` | by profile: 16384, 8192, 16384 | `Secondary_Stack_Size` (checked; not a link symbol, the runtime takes the default of its profile) |
| `-- OPTION...` | `--cache-ways`, `--lim-ways`, `--scratchpad-ways`, `--itim-length`, `--dtim-length`, `--omit` | by memory profile, 0, 0 | the L2 ways, the ITIM of each hart of the mask, the DTIM, a link symbol left out |

`./x build` passes everything after `--` to the tool unchanged, and the `PARTITION_OPTS=` of an example's
`example.conf` before that. `IMAGE_<main>=` gives one main of an example options of its own (a console per main in
`examples/textio_test`).

The tool refuses what it cannot write (an unknown name, a value that is no number, a hart above 4): exit status 2
and a message. It does **not** refuse a value that breaks a rule of the hardware. The checks in the package do that,
so that every generator fails in the same place and with the same message.

### Defaults

The console is the MMUART of the hart: MMUART0 for hart 0, MMUART1 to MMUART4 for U54 harts 1 to 4; for a mask of several harts the lowest hart counts (as for the local ITIM window). Only MMUART0 to MMUART3 are brought out on the Icicle Kit (CP2108), so an image for hart 4 has its console on a port that no serial port shows; give it `--console` of another MMUART or `none`. Test_Report of most examples writes through `Bare_Console`, which is MMUART0 on every hart, not through the console of the runtime. The `mtime` clock of the
runtime is 1 MHz (`System.BB.Parameters.Clock_Frequency`; it is not partition data). The L2 is as at reset: 15 ways
of LIM (1920 KB), no scratchpad, one way of cache. The scratchpad profile takes two ways from the LIM (13 and 2, that
is 1664 KB and 256 KB); `envm` has the LIM of `lim`.

### The link symbols

| Symbol | Meaning | Set by |
|---|---|---|
| `__data_load`, `__data_start`, `__data_end`, `__bss_start`, `__bss_end`, `__heap_start`, `__heap_end`, `__stack_end`, `__interrupt_stack_start`, `__interrupt_stack_end`, `__global_pointer$` | the layout | the placement script (`ld/sections.ld`) |
| `__eh_frame_start`, `__eh_frame_end` | the range of `.eh_frame` that the zero-cost exceptions of the `embedded` profile register | the placement script |
| `__mpfs_boot_role` | 1 primary, 0 secondary | the list |
| `__mpfs_console_base` | base of the console MMUART (LO), 0 for none | the list |
| `__mpfs_console_dlr`, `__mpfs_console_dfr` | divisor and fraction of the baud rate | the list |
| `__mpfs_console_init` | 1 the runtime sets divisor and format, 0 the boot stage has | the list |
| `__mpfs_harts_mask` | mask of the partition, bit n is hart n | the list |
| `__stack_size`, `__interrupt_stack_size` | stack sizes in bytes: the stack of the environment task and the interrupt stack (the size, not a limit: `ld/sections.ld` reserves exactly this for an image that links `System.BB.Interrupts`, none for another) | the list |
| `MPFS_ENVM_LENGTH`, `MPFS_DTIM_LENGTH`, `MPFS_E51_ITIM_LENGTH`, `MPFS_U54_1_ITIM_LENGTH` to `MPFS_U54_4_ITIM_LENGTH`, `MPFS_LIM_LENGTH`, `MPFS_SCRATCHPAD_LENGTH`, `MPFS_DDR_CACHED_LENGTH`, `MPFS_DDR_NC_LENGTH`, `MPFS_DDR_WCB_LENGTH` | the lengths of the regions of `ld/mpfs-memory.ld` (the origins are literals there) | the list |
| `MPFS_LOCAL_ITIM_ORIGIN`, `MPFS_LOCAL_ITIM_LENGTH` | the ITIM of the first hart of the mask; a window of length 0 keeps the origin of the E51 window | the list |

A value symbol that is missing stops the link (an undefined reference, or an undefined symbol in the linker script);
`--omit SYMBOL` leaves one out for the negative builds. The value of `__mpfs_boot_role` is not checked in the linker
script, because a check there would hide the undefined reference: the package checks it. The linker scripts keep
their own asserts (a stack size that is not a multiple of 16, an empty region, a mask that names no hart) as a
second line.

### The package

The values are named numbers: `Harts_Mask`, `Boot_Role`, `Console_Kind` (`Console_None`, `Console_MMUART`,
`Console_RAM_FIFO`), `Console_Base`, `Console_Init`, `Console_Divisor`, `Console_Fraction`, `Stack_Size`,
`Interrupt_Stack_Size`, `Secondary_Stack_Size`, `Cache_Ways`, `LIM_Ways`, `Scratchpad_Ways`, `LIM_Length`,
`Scratchpad_Length`, `DTIM_Length`, `ITIM_Length_0` to `ITIM_Length_4`, `SMP_Available`, and the constants that the
checks compare with (`L2_Ways`, `Max_LIM_Ways`, `DTIM_Max`, `ITIM_Max_0` to `ITIM_Max_4`). Excerpt for an E51 with the
defaults:

```ada
package MPFS_Partition is

   pragma Pure;

   Harts_Mask               : constant := 16#1#;
   Boot_Role                : constant := 1;
   Console_Kind             : constant := 1;
   Console_Base             : constant := 16#2000_0000#;
   Stack_Size               : constant := 16384;
   LIM_Ways                 : constant := 15;
   --  ...
   Mask_Mixes_E51_And_U54   : constant Boolean :=
     Harts_Mask mod 2 = 1 and then Harts_Mask / 2 /= 0;
   pragma Compile_Time_Error
     (Mask_Mixes_E51_And_U54,
      "a partition mask must not mix the E51 and U54 harts");
```

and the list for the same image:

```
__mpfs_harts_mask=1
__mpfs_boot_role=1
__stack_size=16384
__interrupt_stack_size=8192
__mpfs_console_base=0x20000000
__mpfs_console_init=1
__mpfs_console_dlr=22
__mpfs_console_dfr=0
MPFS_ENVM_LENGTH=0x1ff00
...
```

### The checks

Each check is a **flat static constant** and a `pragma Compile_Time_Error` on it. GNAT silently ignores a
`Compile_Time_Error` whose condition is not static, so there is no function call, attribute or aggregate in a
condition, and the package is `pragma Pure`. `./x build` compiles the package (`-gnatc`, warnings are errors)
against the runtime variant before it links, so a failing check stops the build with its message and leaves no
image.

| Check | Message | Negative build |
|---|---|---|
| the mask names no hart or a hart above 4 | the harts mask names no hart or a hart above 4 | `mask_names_no_hart`, `mask_empty` |
| the mask mixes E51 and U54 | a partition mask must not mix the E51 and U54 harts | `mask_mixes_e51_and_u54` |
| the boot role is above 1 | `__mpfs_boot_role` must be 1 (primary) or 0 (secondary) | `boot_role_above_1` |
| the stack size is 0 or not a multiple of 16 | the stack size must be a non-zero multiple of 16 | `stack_size_not_16` |
| the interrupt stack size is 0 or not a multiple of 16 | the interrupt stack size must be a non-zero multiple of 16 | `interrupt_stack_size_not_16` |
| the secondary stack size is 0 or not a multiple of 16 | the secondary stack size must be a non-zero multiple of 16 | `secondary_stack_size_not_16` |
| the console `ram_fifo` without SMP | the console ram_fifo needs a second hart; SMP does not exist yet | `console_ram_fifo_before_smp` |
| the L2 ways (cache, LIM, scratchpad) do not add up to 16 | the L2 ways (cache, LIM, scratchpad) must add up to 16 | `l2_way_sum_not_16` |
| more than 15 ways of LIM | at most 15 L2 ways can be LIM: one way stays cache | `lim_ways_above_15` |
| a DTIM in a partition without the E51 | the DTIM exists on the E51 only | `dtim_on_u54` |
| a DTIM above 8 KB | the DTIM of the E51 is 8 KB at most | `dtim_too_large` |
| the ITIM of a hart above the size of its ITIM (E51 8 KB, U54 28 KB) | the ITIM of E51 (or U54 hart n) is larger than the ITIM of that hart | `itim_too_large_e51`, `itim_too_large_u54` |

The negative builds are in `tests/host/standalone` (`./x build trap_test` with a partition that breaks the rule).
`tests/host/rts_boot` has the linker-level ones, which go through the linker scripts without the Ada checks.
`SMP_Available` is 0 until the runtime has more than one CPU; the check on `ram_fifo` goes with it.

### Reading the data without `./x build`

`mpfs_link.gpr` (`crates/mpfs_rts`) reads the list from the environment variable `MPFS_DEFSYMS` (the lines as
`-Wl,--defsym=NAME=VALUE`, separated by semicolons) and `MPFS_DEFSYMS_<main>` for a main of its own. gprbuild called by
hand sets them from the file and the placement in `MPFS_PLACEMENT`; without them the link fails with undefined
symbols. The bare images of `examples/common/bare_build.sh` have their own linker script and do not use the
partition data.

### What the configuration generator takes over

The names of the symbols and their order, the named numbers and the text of the checks. It adds what a system
description knows: several partitions, the origins and lengths of their regions and the clock of the configuration
for the divisors. The length of a region of a hart that the partition does not own is 0, not omitted.
