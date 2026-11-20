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
of two images that run on the same board, so the LIM regions of such images must be kept apart by hand. The
configuration generator places and checks the windows of the partitions of a system description
([derived system](#derived-system)); its emitters, which will hand the origins to the images, do not exist yet.

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
schema cannot express; what it returns is the immutable model of `mpfs_gen/model.py`. Together with the MSS
Configurator XML it gives the [derived system](#derived-system); nothing writes partition data, linker
scripts or boot tables from that yet: the emitters are the next stage of the configuration generator. To
check a description:

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
keyword), `GEN-E020` to `GEN-E034` the rules across fields, `GEN-E040` to `GEN-E052` the rules of the [MSS
Configurator XML](#mss-configurator-xml), `GEN-E060` to `GEN-E099` the rules of the [derived
system](#derived-system), `GEN-E100` to `GEN-E119` the rules of the [PMP of the XML](#pmp-of-the-xml), `GEN-E120`
on the [PMP and the AMP contexts against the partitions](#pmp-and-amp-contexts-against-the-partitions). A rule
that ends in "(a warning)" is reported without stopping the derivation.
The table is `CODES` in `gen/mpfs_gen/checks.py`, and a test compares the two.
`tests/host/system_yaml/fixtures/broken` has a description for each code of `system.yaml`,
`tests/host/xml_reader/fixtures/broken` an XML (or an edit of the XML of the Icicle Kit) for each code of the
XML, that is rejected with exactly that code, and `tests/host/derive` a negative case for each code of the
derivations.

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
| `GEN-E040` | the XML cannot be read, is not well-formed or has not the structure of an MSS Configurator XML |
| `GEN-E041` | the XML has a document type or entity declaration |
| `GEN-E042` | xml_format_version is missing or not a version the reader knows (0.5.3, 0.6.5, 0.6.8) |
| `GEN-E043` | a core section is missing |
| `GEN-E044` | a register that the generator needs is missing from its section |
| `GEN-E045` | a section has a register or memory element twice |
| `GEN-E046` | a register has a field twice |
| `GEN-E047` | a number does not have its form (0x and hex digits; decimal digits where the section is decimal; a bare number above 9 in a hex section is ambiguous) |
| `GEN-E048` | a field reaches beyond its register |
| `GEN-E049` | two fields of a register overlap |
| `GEN-E050` | a value is wider than its field |
| `GEN-E051` | a field is at another bit position than the field of the same name in the SVD |
| `GEN-E052` | a value is wider than the field of the same name in the SVD |
| `GEN-E060` | the XML does not have the SHA-256 that system.yaml names for it |
| `GEN-E061` | a clock of mss_clocks/clocks differs by more than 1 ppm from the clock recomputed from the MSS PLL and the dividers |
| `GEN-E062` | the MSS PLL has a reference divider, a feedback multiplier or an output divider of 0 |
| `GEN-E063` | the CPU clock is above 625 MHz |
| `GEN-E064` | the AXI clock is above 312.5 MHz |
| `GEN-E065` | the AHB/APB clock is above 156.25 MHz |
| `GEN-E066` | the CPU clock is below the AXI clock |
| `GEN-E067` | the AHB/APB clock divider is 1 |
| `GEN-E068` | the AHB clock is not above 66 MHz while USB is configured |
| `GEN-E069` | the reference clock divided by the RTC toggle clock is not a whole number from 1 to 4095 |
| `GEN-E070` | RTC_CLOCK_CR.PERIOD is not the reference clock divided by the RTC toggle clock |
| `GEN-E071` | the RTC toggle clock is not the Clock_Frequency of the runtime (1 MHz) |
| `GEN-E072` | the L2 of the XML has no cache way or more than 16 ways (WAY_ENABLE, NUM_SCRATCH_PAD_WAYS) |
| `GEN-E073` | a way mask of the XML includes a scratchpad way |
| `GEN-E074` | l2.cache_partitioning names a way that is not a cache way |
| `GEN-E075` | the size of a window is not a multiple of 4 (the granularity of a PMP entry) |
| `GEN-E076` | the windows of a memory do not fit it (the L2 budget of LIM and scratchpad, the eNVM) |
| `GEN-E077` | a window reaches outside its memory |
| `GEN-E078` | windows of two different partitions overlap |
| `GEN-E079` | a window lies in the ITIM or DTIM of a hart that is not in its partition |
| `GEN-E080` | an interrupt is not a PLIC source of the SVD |
| `GEN-E081` | a local interrupt is not one of every hart of the partition |
| `GEN-E082` | a PLIC source is handled by two partitions |
| `GEN-E083` | a peripheral is neither a block of SUBBLK_CLOCK_CR nor a watchdog of the SVD |
| `GEN-E084` | a partition owns a peripheral that CONFIGURED_PERIPHERALS of the XML leaves out |
| `GEN-E100` | a PMP entry of the XML has W set and R clear (a reserved combination) |
| `GEN-E101` | a PMP configuration byte of the XML sets the reserved bits 5 and 6 |
| `GEN-E102` | a locked PMP entry comes after an unlocked entry in use |
| `GEN-E103` | a PMP entry in use is beyond the number of entries of the target (16; 8 with --pmp-entries 8) |
| `GEN-E104` | MEM_CONFIGS_ENABLED.PMP is 0, but the PMP sections set entries (a warning) |
| `GEN-E105` | a locked PMP entry grants rights over the whole address space or over the range of a later entry |
| `GEN-E120` | a U partition cannot reach a window of its own with the rights it needs |
| `GEN-E121` | a U partition cannot read and write a peripheral of its own at the address APBBUS_CR gives |
| `GEN-E122` | a U partition cannot read the page of mtime |
| `GEN-E123` | U mode of a U partition reaches what is not its own (a warning) |
| `GEN-E124` | a window or peripheral of another partition, or the ITIM or DTIM of another hart, is reachable from U mode or from M mode of a hart with locked entries |
| `GEN-E125` | a critical system block is reachable from U mode |
| `GEN-E126` | SYSREG or MPUCFG is reachable from U mode |
| `GEN-E127` | a critical system block is reachable from M mode of a hart with locked entries (a warning) |
| `GEN-E130` | a hart is in both AMP contexts |
| `GEN-E131` | a peripheral is in both AMP contexts |
| `GEN-E132` | APBBUS_CR is not bits 23:0 of CONTEXT_B_EN while AMP contexts are used |
| `GEN-E133` | a peripheral of a partition is not in the AMP context of its harts |
| `GEN-E134` | the harts of a partition are not all in the same AMP context |
| `GEN-E135` | a PMP window of a partition in one AMP context covers the bus window of the other (a warning) |

Several rules are also checks of the package `MPFS_Partition` (a mask that mixes E51 and U54, a stack size,
`ram_fifo`, the L2 ways, the ITIM): the reader refuses a description early, and the package still refuses
partition data that breaks them, whichever tool wrote it.

### The reference systems

[`systems/`](../systems/README.md) has four systems that the schema validates and that derive with the XMLs of
the Icicle Kit (`icicle`, `icicle_es`; the video kit does not configure MMUART2 and MMUART3, which they use).
Their window sizes are example data that fit together into the LIM; they are not measured. The reference
XMLs configure 4 ways of LIM (512 KiB), too few for them, so `amp_a` to `amp_c` override the L2 with the split at
reset (1 way of cache, 15 of LIM) and `amp_d` with 4 ways of cache and 12 of LIM.

| System | E51 (hart 0) | U54 (harts 1 to 4) |
|---|---|---|
| `amp_a` | light, `u` (monitor, watchdog, log) | hart 1 light-tasking `m` (real-time core); harts 2 to 4 one SMP partition, embedded, `u` |
| `amp_b` | light-tasking, `u` | hart 1 light `u`; harts 2 to 4 SMP light-tasking `u` |
| `amp_c` | embedded, `u` | harts 1 to 4 each a partition of its own, `u`: light, light-tasking, embedded, embedded (ten domains: M and U mode of each of the five harts; the E51 has U mode and no S mode, the U54 has S mode, which is not counted) |
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

## MSS Configurator XML

Libero's MSS Configurator writes the configuration of the MSS of a design as an XML file: clocks and PLL,
IO multiplexing and banks, the memory map, L2, PMP and MPU, DDR and SGMII. Microchip's HAL turns it into C
headers with `mpfs_configuration_generator.py`; here `gen/mpfs_gen/xml_reader.py` reads it into the
immutable model `MssConfiguration` of `mpfs_gen/model.py`. To read one:

```sh
python3 config/gen/mpfs_gen xml config/boards/icicle/ICICLE_MSS_mss_cfg.xml           # every register
python3 config/gen/mpfs_gen xml --fields config/boards/icicle/ICICLE_MSS_mss_cfg.xml  # and its fields
python3 config/gen/mpfs_gen xml --check config/boards/*/*.xml                         # FILE: ok
```

The printout has the design, the SHA-256 of the file, one line per register of the core sections
(`SECTION/NAME = VALUE`, and the register of the SVD with its layout in brackets), the memory elements and
the sections that are only validated. A broken XML gives one line per violated rule,
`FILE: GEN-Exxx SECTION/REGISTER.FIELD: message`, and status 2. The merged SVD is
`build/svd/PolarfireSoC.svd` (made current first) or `--svd FILE`.

**Format versions.** `xml_format_version` must be `0.5.3`, `0.6.5` or `0.6.8`, the versions of the reference
XMLs; any other is refused (`GEN-E042`). A version enters the list together with a reference XML of it and a
green run of the differential test below. Format 0.5.3 (Libero 2021.1, the PMP demo) has the same core sections
and the same layout of every register it has, checked against the SVD as the later ones, but lacks
`GPIO_INTERRUPT_FAB_CR`, `ALT_GPIO_INTERRUPT_FAB_CR` and `CONFIGURED_PERIPHERALS` (and `DDR_CLK`,
`MSS_CLKS_VERSION`, `SYSREG_CLKS_VERSION`, which the generator does not need). The first three are not needed in
that format (`NOT_IN_FORMAT` in `xml_reader.py`); the derivations then take the defaults of Microchip's HAL:
every peripheral configured (`0xFFFFFFFF`, `mss_peripherals.h`) and `GPIO_INTERRUPT_FAB_CR` 0
(`mss_io_config.h`).

**Sections.** The core sections are decoded: `mss_clocks` (`clocks`, `mss_sys`, `mss_pll`, `mss_cfm`,
`sgmii_cfm`), `mss_io` (`io_mux` with the banks and `GPIO_INTERRUPT_FAB_CR`, `io_mux_alt`),
`mss_memory_map` (`apb_split` with `APBBUS_CR`, `MEM_CONFIGS_ENABLED` and the AMP contexts `CONTEXT_A_EN`,
`CONTEXT_B_EN`, `CONTEXT_A_HART_EN`, `CONTEXT_B_HART_EN`, `map/mem_elements`, `nvm_map`,
`cache`, `pmp_h0` to `pmp_h4`, the ten `mpu_*`), `mss_general/mss_peripherals`, `mss_sgmii/tip` (the
values of the SGMII off mode) and `mss_ddr/mode` and `mss_ddr/off_mode` (`DDRPHY_MODE`). A register is
found by section and name: the three PLLs have registers of the same names. The other sections (the rest of
`mss_ddr`, `sgmii_pll`, `ddr_pll`, `hsio`) are only validated and are not in the model: by the same rules,
except the comparison with the SVD (`GEN-E051`, `GEN-E052`). Nothing writes them, and a design that does
not use them carries the defaults of the configurator (a design without DDR has `0x4` in the one-bit
`CFG_DATA_MASK` of the DDR controller).

**Values.** A register's value is what Microchip's generator makes of it: the RW fields shifted to their
offsets and added; fields of other types are not part of it. `clocks` and `nvm_map` are decimal; in the
other sections a value has `0x`. Microchip's generator reads a bare number as hex in every section, so a bare
number in a hex section is taken only from 0 to 9, where both readings agree (`GEN-E047`).

**Widths.** Every value must fit the width that the XML declares for its field (`GEN-E050`). Where the SVD
has the register, the source of the PAC as well, a field of the same name must be at the same bit position
(`GEN-E051`) and the value must fit the field of the SVD (`GEN-E052`). The configurator keeps some values for
the software only (the clock rates, the PMP CSRs, the L2 settings, most of `apb_split`), and the SVD does
not describe a few registers yet (the multiplexers of `sgmii_cfm`, `IMIRROR_TRIM`); for those the XML's own
widths are the check. The three PLLs share the layout of the PLL in `CFG_DDR_SGMII_PHY` (`<NAME>_MAIN`).

**The known defect of `PLL_PHADJ`.** In every reference XML, `REG_OUT3_PHSINIT` of the MSS PLL is 3 bits
wide and holds `0x8`. Shifted to its offset 11, the value sets bit 14, `REG_LOADPHS_B`, which the XML gives
as 0. Microchip's generator adds the fields all the same and writes `0x4003`: all four phases 0 and
`REG_LOADPHS_B` 1, the form that `PLL_PHADJ` of the SGMII and the DDR PLL has in the same XMLs, and the
value that `hw/mss_init.py` writes on the board. The reader keeps the field as written and gives the
register this value; the register names the defect (`defect`), and `xml` marks it. The defect is reported
to Microchip (polarfire-soc/polarfire-soc-documentation#610, without an answer). The exception is this one
field with this one value (`KNOWN_DEFECTS` in `xml_reader.py`); `0x8` in any other field, or another value
there, is `GEN-E050`.

**The width of `MEM_CONFIGS_ENABLED`.** Every XML at hand declares its fields `PMP` (offset 0) and `MPU` (offset
1) 0 bits wide; the configurator writes `0x1` into them when it enables its PMP and MPU tables (Microchip's PMP
demo has both). Microchip's generator ignores the width and shifts the value to its offset, which gives the bits
that Microchip's HAL tests (`PMP_ENABLED_MASK` 1, `MPU_ENABLED_MASK` 2, `mss_pmp.h`). The reader takes `0x1` in
either field the same way and names it as a known defect; any other value there is `GEN-E050`.

**Differential test.** [`tools/mchp_diff`](../tools/mchp_diff/README.md) runs Microchip's generator at a
pinned commit on every reference XML and compares each of its `LIBERO_SETTING_*` defines with the value
of the reader: the registers of the core sections, the memory elements and the design information. A
difference fails unless `tools/mchp_diff/exceptions.yaml` admits it with whose defect it is and the
reason; the list is empty, every overlapping value of the four XMLs agrees.

**Untrusted input.** The reader refuses a document type or entity declaration before the parser sees the
file (`GEN-E041`), so no entity is expanded.

### Reference XMLs

Each board directory has the XML of its design, unchanged; where an imported one comes from is in
[`PROVENANCE.md`](../PROVENANCE.md). `icicle_amp_c` is the project owner's own Icicle design, exported with
pfsoc_mss from the `.cfg` next to it.

| Board | File | Format | Libero | Part |
|---|---|---|---|---|
| [`icicle`](boards/icicle/README.md) | `ICICLE_MSS_mss_cfg.xml` | 0.6.8 | 2024.2 | MPFS250T |
| [`icicle_amp_c`](boards/icicle_amp_c/README.md) | `amp_c_mss_cfg.xml` | 0.6.8 | 2026.1 | MPFS250T_ES |
| [`icicle_es`](boards/icicle_es/README.md) | `ICICLE_MSS_mss_cfg.xml` | 0.6.5 | 2022.2 | MPFS250T_ES |
| [`icicle_es_pmp_demo`](boards/icicle_es_pmp_demo/README.md) | `ICICLE_MSS_mss_cfg.xml` | 0.5.3 | 2021.1 | MPFS250T_ES |
| [`video_kit`](boards/video_kit/README.md) | `MSS_video-kit_mss_cfg.xml` | 0.6.8 | 2023.2 | MPFS250TS |

## Derived system

The package `gen/mpfs_gen/derive` derives from a system description and the MSS Configurator XML of its board
the data that the emitters will write: the clocks, the L2, the windows of the partitions and channels, and per
partition `CPU_To_Hart`, the PLIC sources and contexts and the release masks of its peripherals. The result,
`Derived`, is immutable; a description and an XML that break a rule give one line per rule,
`FILE with XML: GEN-Exxx PATH: message`, and status 2.

```sh
python3 config/gen/mpfs_gen derive systems/amp_a/system.yaml                      # print the derived system
python3 config/gen/mpfs_gen derive --check systems/*/system.yaml                  # FILE: ok
python3 config/gen/mpfs_gen derive --xml config/boards/icicle_es/ICICLE_MSS_mss_cfg.xml systems/amp_a/system.yaml
python3 config/gen/mpfs_gen derive --pmp-entries 8 --check FILE                   # does the PMP run under QEMU
```

The XML is `xml.file` of the description (its SHA-256 must be `xml.sha256`, `GEN-E060`), otherwise the one XML
in the directory of the board; `--xml` takes another.

**Clocks** (`derive/clocks.py`). The rates of `mss_clocks/clocks` are recomputed from the MSS PLL and must
agree within 1 ppm (`GEN-E061`): VCO = `MSS_EXT_SGMII_REF_CLK` / `RFDIV` × (`INTIN` + `FRACIN` / 2²⁴ when
`FRACN_EN`), the MSS clock = VCO / (4 × `POST0DIV`) (output 0 of the PLL, selected by bit 0 of `MSSCLKMUX`),
and CPU, AXI and AHB/APB that divided by 2 to the power of the dividers of `CLOCK_CONFIG_CR`. Microchip's HAL
does not spell the formula out; it is the one of the PolarFire clocking documentation, and every reference XML
agrees with it exactly (125 MHz / 5 × 96 = 2400 MHz, / 4 = 600 MHz; CPU 600, AXI 300, AHB/APB 150 MHz). A
divider or multiplier of 0 is `GEN-E062`. The limits are those of `mss_pll.h` (lines 147 to 155 at the commit
of `tools/mchp_diff/oracle.env`): CPU at most 625 MHz (`GEN-E063`), AXI at most 312.5 MHz (`GEN-E064`), AHB/APB
at most 156.25 MHz (`GEN-E065`), CPU not below AXI (`GEN-E066`), AHB/APB not divided by 1 (`GEN-E067`), AHB
above 66 MHz when `CONFIGURED_PERIPHERALS` has USB (`GEN-E068`). The RTC: the reference divided by
`MSS_RTC_TOGGLE_CLK` must be a whole number from 1 to 4095 (`GEN-E069`), `RTC_CLOCK_CR.PERIOD` must hold it
(`GEN-E070`; 125 in the reference XMLs), and the toggle clock must be the `Clock_Frequency` of the runtime,
1 MHz (`GEN-E071`).

**L2** (`derive/l2.py`). The XML is the source of the split. It is a setting of the MSS, not a property of the
board: every PolarFire SoC has the same 16 ways of 128 KiB, and the XML of any board, the Icicle Kit's included,
can share them out differently (only the DDR memory depends on the board). As Microchip's `mss_l2_cache.c` lays the ways out: cache ways 0 to `WAY_ENABLE` −
`NUM_SCRATCH_PAD_WAYS`, the scratchpad the upper `NUM_SCRATCH_PAD_WAYS` of the enabled ways (the code, not the
comment of the header), the LIM the ways above `WAY_ENABLE`. The reference XMLs have `WAY_ENABLE` 11 and 4
scratchpad ways: 8 ways of cache, 4 of scratchpad (ways 8 to 11), 4 of LIM. The XML must leave at least one
cache way (`GEN-E072`) and keep the scratchpad ways out of its way masks (`GEN-E073`). `l2.ways` overrides the
split and is laid out the same way; the ways of `l2.cache_partitioning` must be cache ways (`GEN-E074`).

**Windows** (`derive/placement.py`). Each partition has one window for its code and data per memory (`envm`,
`lim`, `scratchpad`), and `fast_text` a window in the ITIM of each of its harts. A channel lies in the memory
of the data of both its partitions (the LIM where they differ). Where the channels of a memory form chains,
each chain is one block, `A | IPC_AB | B | IPC_BC | C`, starting at the end that comes first in the
description; otherwise all channels of the memory form one shared block. The blocks are placed
first-fit-decreasing (equal sizes in the order of the description), at a multiple of the size of their first
window where that is a power of two (a NAPOT region), at a multiple of 4 (TOR) otherwise. A size that is no
multiple of 4 is `GEN-E075`, windows that do not fit their memory are `GEN-E076` (the message names the
partitions). The system map is then checked, whoever placed its windows: a window outside its memory
(`GEN-E077`), windows of two different partitions that overlap (`GEN-E078`, the message names both), a window
in the ITIM or DTIM of a hart that its partition does not have (`GEN-E079`). The space of the boot loader in
the LIM is not counted yet: the boot loader does not exist.

**Per partition.** `CPU_To_Hart` is the position of the k-th set bit of the mask. The PLIC sources are the
names of the SVD with their numbers (`GEN-E080` for another name, `GEN-E082` for a source of two partitions);
the boot loader enables them in the M-mode context of each hart of the partition only (hart 0 context 0, hart
n context 2n − 1). `local:NAME` must be a local interrupt of every hart of the partition (`GEN-E081`). The PLIC
level of a source is the level of the Ada priority of its handler (`Interrupt_Priority'First + n − 1` is level
n, `crates/mpfs_rts/README.md`); `system.yaml` does not carry those priorities yet, so the levels are left
open. A peripheral is a field of `SUBBLK_CLOCK_CR` in lower case or a watchdog of the SVD (`GEN-E083`); the
release masks of `SUBBLK_CLOCK_CR` and `SOFT_RESET_CR` have the bits of the SVD for the peripherals and the
console MMUART of the partition. A peripheral that `CONFIGURED_PERIPHERALS` has a field for must be configured
there (`GEN-E084`).

**System.** `RAM_SHUTDOWN_CR` shuts down the RAMs of CAN0, CAN1, USB, GEM0, GEM1 and MMC when
`CONFIGURED_PERIPHERALS` leaves them out and of the DDR controller when `DDRPHY_MODE` is off, by the rules of
Microchip's `mss_peripherals.h` (the video kit: CAN0 and CAN1). The direct GPIO interrupts `GPIO_DIRECT_0` to
`_31` are GPIO0 or GPIO1 lines, or GPIO2 lines where the bit of `GPIO_INTERRUPT_FAB_CR` is set; `_32` to `_37`
are GPIO1 bits 18 to 23.

## PMP of the XML

The PMP of each hart is not chosen by the generator: the user sets it with Microchip's MSS Configurator
(pfsoc_mss), and the XML holds it in `mss_memory_map/pmp_h0` to `pmp_h4` (`CSR_PMPCFG0` for the entries 0 to 7,
`CSR_PMPCFG2` for 8 to 15, `CSR_PMPADDR0` to `15`). `mpfs_gen/pmp.py` reads and decodes it:

```sh
python3 config/gen/mpfs_gen pmp config/boards/icicle/ICICLE_MSS_mss_cfg.xml      # the entries of each hart
python3 config/gen/mpfs_gen pmp --ada examples/pmp_xml_test/src/generated/pmp_xml.ads \
  config/boards/icicle/ICICLE_MSS_mss_cfg.xml                                     # the Ada table (--check: compare)
```

`pmp` prints per hart the two configuration CSRs and every entry that is not OFF: its mode, the byte range it
matches (TOR from the `pmpaddr` of the entry before it, a NAPOT entry of all ones is the whole space of 2^56
bytes), its rights and its lock. The rules of the Privileged Spec v1.10: an entry with W set and R clear is
reserved (`GEN-E100`), bits 5 and 6 of a configuration byte are reserved (`GEN-E101`). `--ada` writes the values
as the package `Pmp_Xml` (`Pure`, one record per hart), byte for byte the same for the same XML; the test program
`examples/pmp_xml_test` compares it with the CSRs of the hart. What the reference XMLs set and what the tests
cover is in [`docs/assurance/pmp-tests.md`](../docs/assurance/pmp-tests.md).

**Semantics.** `pmp.regions` cuts the address space of a hart into the regions in which its PMP decides alike,
after the Privileged Spec v1.10 (the MPFS has no Smepmp): the matching entry with the lowest index decides; for
U mode it grants its rights, for M mode only if it is locked (an unlocked entry lets M through); no match allows
M and denies U. `pmpaddr` is WARL, so the entries are taken in the bits each hart implements
(`target.PMPADDR_BITS`): 36 on a U54, measured on hart 1 (the all-ones value of the XML reads back
`0xf_ffff_ffff`, `docs/lab/results/pmp-entries.md`), 54 on the E51, whose width is not measured yet. The
locked part of a hart (the locked entries and the base of a locked TOR entry, whose `pmpaddr` is locked with it)
is what the boot loader will set, the unlocked part what the kernel of the partition will set.

**Layout.** The derivation checks how the entries are laid out: all locked entries come before all unlocked
entries in use (`GEN-E102`); the entries in use fit the target, 16 entries per hart on the silicon (measured on
the E51 and U54 hart 1) or 8 under QEMU 10.1 with `derive --pmp-entries 8` (`GEN-E103`); with
`MEM_CONFIGS_ENABLED.PMP` 0 the PMP sections should be zero (`GEN-E104`, a warning: Microchip's start code
writes `pmpcfg0` of the U54 harts whatever the flag says); a locked entry that grants rights over the whole
address space, or over the range of a later entry so that the later one can never decide, is refused
(`GEN-E105`). The three reference XMLs of the boards have `MEM_CONFIGS_ENABLED.PMP` 0 and, on each U54, entry 0
locked NAPOT over the whole address space with RWX (`0x9F`, `pmpaddr` all ones): both are reported, and entry 0
is refused. The PMP demo keeps the layout rules (`MEM_CONFIGS_ENABLED` `0x3`, every entry locked, a deny-all
last); with 11 entries on harts 1 and 2 it does not fit the 8 of QEMU.

## PMP and AMP contexts against the partitions

The PMP and the AMP contexts are the user's, set in the MSS Configurator; the generator does not make or repair
an entry. `derive` (`derive/protection.py`, `derive/contexts.py`) checks them against the partitions of
`system.yaml` and adds to the derived system the AMP context and the peripheral addresses of each partition,
`APBBUS_CR`, the contexts, and per hart the PMP: the entries in use, the locked and the unlocked part and the
regions with the rights of U and M mode. `derive` prints them with the occupation of each hart and the mapping of
the partitions onto the contexts; a warning is a line `warning: GEN-Exxx (warning) ...` (with `--check`, on
stderr after `FILE: ok`).

**Security profile.** A `prod` image must pass the checks: every rule of the PMP and the contexts, those of the
XML's own PMP sections (`GEN-E100` to `GEN-E105`) included, is enforced, and an error stops the derivation. For a
`dev` image (the default) the checks run for information; every finding, error or warning, is a note
(`Derived.notes`, the lines `note: ...`; `derive --check` prints how many) and stops nothing. A dev image does
not set the PMP registers: the derived system marks the PMP as not applied (`Protection.applied` False, the line
`pmp: not applied (security_profile dev)`), so that the emitters write no PMP entries into the boot table and
the partition data. Everything else of the XML is applied in both profiles: the MPU (a DMA master has no access
until its MPU regions exist, MSS TRM DS60001702S §3.4; its checks, still to come, will be notes in dev and errors
in prod like those of the PMP), the way masks and the L2 split, `APBBUS_CR` and the addresses of the
peripherals, the clocks and the IO multiplexing.

**Addresses.** A peripheral of both APB buses (MSS TRM DS60001702S Table 3-49: MMUART0 to 4, WDOG0 to 4, SPI,
I2C, CAN, MAC (GEM), GPIO0 to 2, RTC, timer, H2F interrupts; the blocks `<NAME>_LO` and `<NAME>_HI` of the SVD)
is at its LO address (from `0x2000_0000`) or its HI address (from `0x2800_0000`) as its bit of `APBBUS_CR` says;
USB, QSPI, eMMC, the eNVM controller and Athena have one address, the one of the SVD; a peripheral takes the
whole 4 KiB pages its registers in the SVD span. The FICs, the DDR controller and the CFM have no block of
their own and are not checked.

**What a partition reaches.** For each hart of a partition the PMP is evaluated in U mode (a `u` partition) and
in M mode where the hart has locked entries (M mode of a hart without any is bound by no entry). Its own are
its windows (code and data RWX in one window, code and `fast_text` RX, data and channels RW; `fast_text` only in
the ITIM of the hart itself), its peripherals and console RW at their address, and the page of `mtime` R
(`0x0200_B000`, from the CLINT of the SVD). Foreign are the windows of other partitions and channels, the DTIM
and the ITIMs of the harts outside the partition and the peripherals of other partitions. An ITIM of another hart
is foreign only if a partition places a window in it (`fast_text`): an ITIM that no partition uses holds no code
or data of any partition, and locking each one out would take an entry of the locked tables per ITIM, a budget
the Configurator's one table per context does not have. Critical are, from the SVD and in the whole pages their
registers touch: SYSREG, MPUCFG (with the SEG registers), SCB, the AXI switch, `CFG_DDR_SGMII_PHY`, the eNVM
controller (unless the partition owns `envm`), the L2 cache controller (`0x0201_0000`), the PDMA (`0x0300_0000`,
four channels of `0x1000`), the system controller (`0x3702_0000`) and its mailbox (`0x3702_0800`), the IOSCB
configuration (`0x3708_0000`), the IOSCB blocks of the MSS (`IOSCB_*` from `0x3E00_1000`) and the bus error
units of the harts outside the partition (`0x0170_0000` plus `0x1000` per hart).

The rules: U mode lacks a right on a window of its own (`GEN-E120`), cannot read and write a peripheral of its own
at its address (`GEN-E121`) or cannot read the page of `mtime` (`GEN-E122`); U mode reaches what is not its own
and none of the following (`GEN-E123`, a warning); U mode, or M mode of a hart with locked entries, reaches
something foreign (`GEN-E124`); U mode reaches a critical block (`GEN-E125`), or SYSREG or MPUCFG, which expose
`APBBUS_CR`, the clocks and resets of all peripherals and the MPU of every master (`GEN-E126`); M mode of a hart
with locked entries reaches a critical block (`GEN-E127`, a warning: which ones its kernel needs is not described
yet); a partition of one context reaches the bus window of the other, the HI addresses for A and the LO ones for
B (`GEN-E135`, a warning).

`GEN-E135` is a warning for now: on the Icicle Kit an access to a peripheral at the address of the bus it is not
on had no effect and raised no fault (`docs/lab/results/pmp-entries.md`); where the PSLVERR of such an access
goes is still being measured.

**AMP contexts.** The Configurator keeps them in `apb_split`: `CONTEXT_A_HART_EN` and `CONTEXT_B_HART_EN` (a bit
per hart), `CONTEXT_A_EN` and `CONTEXT_B_EN` (a bit per peripheral, bits 0 to 23 those of `APBBUS_CR`). No
register of the silicon holds them: the Configurator derives `APBBUS_CR` and one PMP table per context from them.
They are used when one of the four is not 0 (the reference XMLs have all four 0). A hart in both contexts
(`GEN-E130`; Libero SoC Help §20.2.2.3.9: harts "cannot be enabled in both Context A & Context B") and a
peripheral in both (`GEN-E131`) are refused, so is an `APBBUS_CR` other than bits 23:0 of `CONTEXT_B_EN` while
contexts are used (`GEN-E132`), a peripheral of a partition that is not in the context of its harts (`GEN-E133`)
and a partition whose harts are not all in the same context (`GEN-E134`). `GEN-E133` applies only to the
peripherals the Configurator can put into a context: its `.cfg` (pfsoc_mss) has the keys
`PMP_<P>_CONTEXT_A_EN` and `PMP_<P>_CONTEXT_B_EN` only for MMUART1 to 4, CAN0 and 1, GEM0 and 1, GPIO0 to 2, I2C0
and 1, SPI0 and 1, QSPI, RTC, USB, EMMC and the crypto block (`CRYPTO_CFG`, `CRYPTO_MEM`). MMUART0, WDOG0 to 4,
the timer and the H2F interrupts have none: they stay on the LO bus and belong to no context, and a partition of
either context may own one (its PMP still decides who reaches it). That partitions of different contexts
share no peripheral needs no rule: `system.yaml` gives each peripheral, the console included, to one partition
(`GEN-E025`, `GEN-E026`).

With the reference XMLs of the boards the reference systems are refused for prod: the open, locked entry 0 of
the U54 harts lets every partition reach everything (`GEN-E105`, `GEN-E124` to `GEN-E126`), and the E51 has no
entry for the `u` partition `monitor` of `amp_a` (`GEN-E120` to `GEN-E122`). `amp_c` is a prod system and is
refused; `amp_a`, `amp_b` and `amp_d` are dev systems and derive, with these findings as notes. The PMP demo
(`config/boards/icicle_es_pmp_demo`) passes the checks of the contexts with one partition per context
(`tests/host/derive/fixtures/pmp_demo`); its locked PMP grants SYSREG and the L2 controller to all modes and does
not cover windows in the LIM, so a prod system on it is refused (`GEN-E120`, `GEN-E125`, `GEN-E126`, with the
warnings `GEN-E123` and `GEN-E127`).
