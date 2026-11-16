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

### The role of an image

`--role` (`__mpfs_boot_role`) says who owns the MSS; it is independent of the way the image is loaded and of the security
profile, and any application can be built in either role. The default of the tool is `primary`.

- **primary** (1): the image sets the MSS up itself. It starts straight from the eNVM, is copied from the sNVM by the system
  controller (boot mode 2) or is loaded by JTAG in the lab; no bootloader runs before it. `mpfs_boot`, the later
  bootloader, is such an image too. Its console clocks and releases its MMUART itself when `--console-init` is 1.
- **secondary** (0): the image expects an MSS that is already set up, by `mpfs_boot` or, for an image loaded by JTAG in the lab,
  by the stand-ins of `./x hw` (`initialize`, `--uart-clocks`, `--uart-standin`). A secondary image never touches `SYSREG`.

### The link symbols

| Symbol | Meaning | Set by |
|---|---|---|
| `__data_load`, `__data_start`, `__data_end`, `__bss_start`, `__bss_end`, `__heap_start`, `__heap_end`, `__stack_end`, `__interrupt_stack_start`, `__interrupt_stack_end`, `__global_pointer$` | the layout | the placement script (`ld/sections.ld`) |
| `__eh_frame_start`, `__eh_frame_end` | the range of `.eh_frame` that the zero-cost exceptions of the `embedded` profile register | the placement script |
| `__mpfs_boot_role` | 1 primary, 0 secondary (see "The role of an image" below) | the list |
| `__mpfs_console_base` | base of the console MMUART (LO), 0 for none | the list |
| `__mpfs_console_dlr`, `__mpfs_console_dfr` | divisor and fraction of the baud rate | the list |
| `__mpfs_console_init` | 1 the runtime brings the console MMUART up (divisor, format, FIFOs, and on a primary image its clock and reset in `SYSREG`), 0 whoever set the MSS up has done all of it and no register but the data port is written | the list |
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
`Interrupt_Stack_Size`, `Secondary_Stack_Size`, `Clocks.Rtc_Toggle_Hz`, `Cache_Ways`, `LIM_Ways`, `Scratchpad_Ways`, `LIM_Length`,
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
| the runtime's `Clock_Frequency` is not `Clocks.Rtc_Toggle_Hz` | Clock_Frequency of the runtime is not Clocks.Rtc_Toggle_Hz | `clock_not_rtc_toggle_hz`; every profile and a runtime copy: `tests/host/rts_negative` |
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

## System description

A system description, `system.yaml`, says which partitions run on which harts of a board and what connects
them. Its format is the JSON schema [`gen/schema/system.schema.json`](gen/schema/system.schema.json) (schema
version 1), read by the package [`gen/mpfs_gen`](gen/mpfs_gen/__init__.py). The reader parses the file,
validates it against the schema, applies the defaults, normalises the values and checks the rules that a
schema cannot express; what it returns is the immutable model of `mpfs_gen/model.py`. Nothing derives
partition data, linker scripts or boot tables from it yet: those are the next stages of the configuration
generator. To check a description:

```sh
python3 config/gen/mpfs_gen check systems/amp_a/system.yaml
```

prints `FILE: ok`, or one line per violated rule, `FILE: GEN-Exxx PATH: message`, and exits with status 2.
`PATH` names the field, such as `partitions[1].stacks.main`. Every mistake is reported once: a description
that the schema refuses is not checked further.

### Example

```yaml
schema: 1
board: icicle
partitions:
  - name: monitor
    harts: [0]
    profile: light
    priv: u
    memory:
      code: { region: lim, size: 64K }
      data: { region: lim, size: 64K }
    stacks: { main: 8K, interrupt: 4K }
    peripherals: [mmuart0, wdog0]
    interrupts: [MMUART0, WDOG0_MVRP]
    watchdog: { instance: wdog0, timeout_ms: 1000 }
  - name: rt
    harts: [1]
    profile: light-tasking
    priv: m
    memory:
      code: { region: lim, size: 128K }
      data: { region: lim, size: 128K }
      fast_text: { region: itim, size: 16K }
ipc:
  - { name: monitor_rt, between: [monitor, rt], size: 16K, doorbell: true }
```

### The fields

Every object refuses a field that it does not name (`additionalProperties: false`). A **size** is bytes: an
integer, `0x` and hex digits, or decimal digits with `K` (KiB) or `M` (MiB), such as `4096`, `0x1000`, `64K`.
A **name** (board, partition, channel, peripheral) is lower case letters, digits and single underscores,
starting with a letter, at most 32 characters.

| Field | Type and range | Default | Meaning |
|---|---|---|---|
| `schema` | 1 | required | the version of the schema |
| `board` | name | required | the board: `config/boards/<board>/` must exist |
| `xml` | `file` (path relative to `system.yaml`), `sha256` (64 hex digits) | the XML of the board | the MSS Configurator XML and its expected hash |
| `security_profile` | `dev` or `prod` | `dev` | |
| `l2.ways` | `cache` 1 to 16, `lim` 0 to 15, `scratchpad` 0 to 15, adding up to 16 | as the XML configures it | an override of the L2 of the XML; needs `l2.reason` |
| `l2.reason` | text, 1 to 500 characters | | why the L2 differs from the XML |
| `l2.cache_partitioning` | `e51`, `u54_1` to `u54_4`: a list of ways 0 to 15 | the way masks of the XML | the cache ways that each hart may allocate into |
| `partitions` | list of 1 to 5 partitions (below) | required | |
| `ipc[]` | `name`, `between` (two partitions), `size`, `doorbell` (boolean) | none; `doorbell` false | a channel between two partitions |
| `boot.sources` | list of `envm`, `fram`, `ymodem`, each once | no `boot` section | where the boot loader looks for the images, in this order |
| `fram` | `transport` (`spi0`, `spi1`, `qspi`), `sck_hz` (from 1), `cs` (name), `part` (name), `wp` (name) | `part` `auto`, `wp` `none` | the FRAM of the boot source `fram` |

A partition:

| Field | Type and range | Default | Meaning |
|---|---|---|---|
| `name` | name | required | |
| `harts` | list of 1 to 4 harts 0 to 4, each once | required | 0 is the E51, 1 to 4 the U54 cores; more than one is SMP |
| `profile` | `light`, `light-tasking`, `embedded` | required | the runtime profile |
| `priv` | `u`, `m` | `u` | the privilege mode of the application |
| `memory.code` | `region` (`envm`, `lim`, `scratchpad`), `size` | required; without `size` the whole region | the window of the code |
| `memory.data` | `region` (`lim`, `scratchpad`), `size` | required; without `size` the whole region | the window of the data |
| `memory.fast_text` | `region` (`itim`), `size` | none | code in the ITIM of each hart of the partition |
| `stacks.main` | size | 16K | the stack of the environment task |
| `stacks.interrupt` | size | by profile: 8192, 8192, 12912 | the interrupt stack of each hart |
| `stacks.secondary` | size | by profile: 16384, 8192, 16384 | the secondary stack of the environment task |
| `console` | `mmuart0` to `mmuart4`, `none`, `ram_fifo` | the MMUART of the lowest hart (hart n: MMUARTn) | |
| `peripherals` | list of names, each once | none | the peripherals that the partition owns, instance names of the SVD in lower case |
| `interrupts` | list of PLIC source names, or `local:<name>` for a hart-local interrupt, each once | none | the interrupts that the partition handles |
| `watchdog` | `instance` (`wdog0` to `wdog4`), `timeout_ms` (from 1) | none | the watchdog that the partition services |

The defaults of the stacks and of the console are those of the [standalone partition data](#defaults); both
paths take them from `mpfs_gen/target.py`. The model has the lists whose order means nothing (harts,
peripherals, interrupts, the two ends of a channel, the cache ways) sorted, and the sizes in bytes; the
partitions, the channels and the boot sources keep their order.

Not in schema version 1: `boot.slots` and `keys`, which a later version adds (`GEN-E005`). Whether a
peripheral or interrupt name exists in the SVD, whether the windows fit their regions together and whether
the description agrees with the XML are checked by the later stages that read the SVD and the XML.

### The error codes

Each rule has its own code. `GEN-E001` to `GEN-E013` are the rules of the schema (the reader maps each
failure of the validator to the code of its keyword; a size that is not a size is `GEN-E010` whatever the
keyword), `GEN-E020` on are the rules across fields. The table is `CODES` in `gen/mpfs_gen/checks.py`, and a
test compares the two. `tests/host/system_yaml/fixtures/broken` has a description for each code that is
rejected with exactly that code.

| Code | Rule |
|---|---|
| `GEN-E001` | the file cannot be read or is not well-formed YAML (a key given twice included) |
| `GEN-E002` | the schema version is missing or not 1 |
| `GEN-E003` | a required field is missing |
| `GEN-E004` | an unknown field |
| `GEN-E005` | a field of a later schema version (keys, boot.slots) |
| `GEN-E006` | a value has the wrong type |
| `GEN-E007` | a value is not one of the allowed names |
| `GEN-E008` | a number is out of its range |
| `GEN-E009` | a name or text does not have its form or length |
| `GEN-E010` | a size is not a size (a number, 0x and hex digits, or digits with K or M) |
| `GEN-E011` | a list has an entry twice |
| `GEN-E012` | a list has too few or too many entries |
| `GEN-E013` | l2.ways overrides the XML without l2.reason |
| `GEN-E020` | two partitions have the same name |
| `GEN-E021` | a hart is in two partitions |
| `GEN-E022` | a partition mixes the E51 and U54 harts |
| `GEN-E023` | a stack size is 0 or not a multiple of 16 |
| `GEN-E024` | the console ram_fifo needs SMP, which the runtime does not have yet |
| `GEN-E025` | a peripheral is owned by two partitions |
| `GEN-E026` | the console of a partition is a peripheral of another partition |
| `GEN-E027` | the watchdog of a partition is not one of its peripherals |
| `GEN-E028` | a channel names a partition that does not exist |
| `GEN-E029` | two channels have the same name |
| `GEN-E030` | fast_text is larger than the ITIM of a hart of the partition (E51 8 KiB, U54 28 KiB) |
| `GEN-E031` | the L2 ways (cache, LIM, scratchpad) do not add up to 16 |
| `GEN-E032` | a memory window without a size in a system of more than one partition |
| `GEN-E033` | the boot source fram without a fram section |
| `GEN-E034` | the board has no directory in config/boards |

Several rules are also checks of the package `MPFS_Partition` (a mask that mixes E51 and U54, a stack size,
`ram_fifo`, the L2 ways, the ITIM): the reader refuses a description early, and the package still refuses
partition data that breaks them, whichever tool wrote it.

### The reference systems

[`systems/`](../systems/README.md) has four systems that the schema validates. Their window sizes are example
data that fit together into the LIM; they are not measured.

| System | E51 (hart 0) | U54 (harts 1 to 4) |
|---|---|---|
| `amp_a` | light, `u` (monitor, watchdog, log) | hart 1 light-tasking `m` (real-time core); harts 2 to 4 one SMP partition, embedded, `u` |
| `amp_b` | light-tasking, `u` | hart 1 light `u`; harts 2 to 4 SMP light-tasking `u` |
| `amp_c` | embedded, `u` | harts 1 to 4 each a partition of its own, `u`: light, light-tasking, embedded, embedded (ten domains) |
| `amp_d` | none (the E51 stays with the boot loader) | harts 1 and 2 SMP embedded `u`; harts 3 and 4 SMP light `m`; an L2 override with cache partitioning |

### Standalone presets

Each of the 30 runtime variants (E51 with one CPU, U54 with one to four; three profiles; `m` and `u`) has a
preset: the system description of the partition that `./x build` gives the variant without options.
`mpfs_gen/presets.py` renders it (it is not committed):

```sh
python3 config/gen/mpfs_gen preset u54 2 embedded u
```

The preset names only the harts (hart 0 for the E51, harts 1 to n for a U54 variant of n CPUs), the profile,
the privilege mode and the region `lim` for code and data, without a size; the reader applies the rest. For a
description of one partition whose windows take whole regions, `python3 config/gen/mpfs_gen standalone-args
FILE` prints the parameters of `standalone.py` that stand for it. The test `tests/host/system_yaml` checks
for every variant that `standalone.py` with the parameters of its preset writes the same bytes as with the
parameters of `./x build`, so that a build from a description and a build without one get the same partition
data.
