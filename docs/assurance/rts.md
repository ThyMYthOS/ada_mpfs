<!--
SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
SPDX-License-Identifier: CC-BY-4.0
-->
# The runtime `crates/mpfs_rts`

This is the assurance view of the runtime: what it consists of, which variants exist, how an image
is tied to it, which units are our own and where they differ from upstream, and which requirement is
checked by which test. The mechanisms are described once, in the files this page links to
([the runtime README](../../crates/mpfs_rts/README.md), [the design note on exceptions](../design/exceptions.md),
the comments of the sources); they are not repeated here. The requirements are in
[`docs/requirements/rts.yaml`](../requirements/rts.yaml), the trace to the tests in
[`trace-matrix.md`](trace-matrix.md).

Scope: the runtime for **one hart in machine mode**: three profiles and two hart classes. SMP, user
mode and the kernel are not part of it.

## 1. Structure

The runtime is made in two steps. `crates/bb-runtimes` is a trimmed fork of
[alire-project/bb-runtimes](https://github.com/alire-project/bb-runtimes) (tag `v15.1.0-1`, GNAT 15.3.1,
only the board `mpfs`); it produces the *packs*, the source text of a runtime. `crates/mpfs_rts` lays
the own port units and overlays over a pack and builds the library of one variant.

| Path in `crates/mpfs_rts/` | Role |
|---|---|
| `compare_toolchain.sh`, `port_units.list` | Proves that everything in a pack that is not a port unit is the source of the toolchain's own runtime. |
| `gen_intnam.py` | Writes `mpfs/gnarl/a-intnam.ads` from the SVD (section 5.4). |
| `gen_runtime.sh`, `mpfs_rts.gpr` | Builds one variant (pack, then `remove.list`, port units, overlays, the register packages of the PAC, linker scripts); an application selects it with `mpfs_rts.gpr`. |
| `ld/`, `mpfs_link.gpr` | The linker base and the project that gives an image its `--defsym` values (section 3). |
| `link-zcx.spec` | The link spec of the embedded profile (section 5.6). |
| `make_packs.sh`, `packs.sha256` | Generates the six packs reproducibly from the fork; only the hash of the uncompressed tar stream is committed, the packs are not. |
| `mpfs/` | The own port units (section 4); `mpfs/remove.list` names the files of a pack that an own unit replaces. |
| `overlays/` | Units laid over the pack, for all profiles or for one: today the TLSF heap of the embedded profile (`overlays/tlsf/embedded/gnat`). |

The runtime sources are GPL-3.0-or-later WITH GCC-exception-3.1, the scripts are Apache-2.0
(see the header of each file and [`PROVENANCE.md`](../../PROVENANCE.md)). The packs, the PAC and the
variants are generated and git-ignored; the hashes of the first two are committed (`packs.sha256`,
`libs/mpfs_pac/MPFS_Registers.sha256`), and the key of a variant in `build/rts/` covers everything that
goes into it. Details: "Packs and their hashes", "Comparison with the toolchain" and "Variant build" in
the runtime README.

## 2. Variants

A variant is the pair (profile, hart class) with one CPU in machine mode, built into
`build/rts/<profile>-<hart>-cpus1-m/` (`adainclude/`, `adalib/` with `libgnat.a` and `libgnarl.a`, `ld/`).
`gen_runtime.sh` refuses every other number of CPUs and every other privilege (requirement RTS-003).

| Profile | Tasking | Exceptions | Heap | Console |
|---|---|---|---|---|
| `light` | none (`No_Tasking`) | no propagation; last chance handler | bump allocator of `s-memory` | `System.Text_IO` |
| `light-tasking` | Ravenscar (Jorvik) | no propagation; last chance handler | bump allocator of `s-memory` | `System.Text_IO` |
| `embedded` | Ravenscar (Jorvik) | zero-cost, registration-based unwinder | TLSF (`overlays/tlsf`) | `System.Text_IO`, `Ada.Text_IO` |

| Hart class | Harts | `-march` / `-mabi` | Floating point | Task context | Trap frame | Square root |
|---|---|---|---|---|---|---|
| E51 | 0 | `rv64imac_zicsr_zifencei` / `lp64` | none; every operation is a libgcc call | `ra`, `sp`, `s0` to `s11` | 256 bytes | software (`s-lidosq`) |
| U54 | 1 to 4 | `rv64imafdc_zicsr_zifencei` / `lp64d` | hardware; `mstatus.FS` set by `start.S` | the same and `fs0` to `fs11` | 512 bytes | `fsqrt` |

Both use `-mcmodel=medany` (the default of the toolchain's spec), `-fno-tree-loop-distribute-patterns`
and `-ffile-prefix-map`, so an image does not depend on the directory of its checkout. An object of one
hart class cannot be linked with the other: the ABI check of the linker stops it (BLD-002). The U54
variant is built for any of the harts 1 to 4; which hart runs is link-time data and `mhartid`, not a
property of the library.

## 3. Link-time interface

Everything that belongs to a partition and not to the runtime is an absolute symbol that the link sets
with `--defsym`; the values come from the partition data (section 3.1). The library holds none of the values, so one variant serves every placement and
every console. Requirement RTS-004.

| Symbol | Meaning | Read by |
|---|---|---|
| `__data_load`, `__data_start`, `__data_end`, `__bss_start`, `__bss_end`, `__heap_start`, `__heap_end`, `__stack_end`, `__interrupt_stack_start`/`_end`, `__global_pointer$`, `__eh_frame_start`/`_end`, the bounds of the constructor arrays, `__mpfs_trap_record` | The layout of the image. | `place-*.ld` and `sections.ld` define, `start.S`, the heap and libgcc read |
| `__fast_text_start`/`_end`/`_load` and the same for `__fast_data_*` | Run and load range of the application's ITIM and DTIM sections; empty by default. | the application's `app-sections.ld` defines, `start_fast.S` reads |
| `__gnat_gdb_cpu_first_id` | The lowest hart of the mask, for the debugger. | `.mpfs_gdb` constant of `sections.ld` |
| `__mpfs_boot_role` | 1 primary (owns the boot flow, resets the MSS at exit), 0 secondary (halts at exit). | `start.S` |
| `__mpfs_console_base`, `_init`, `_dlr`, `_dfr` | The MMUART of the console (0: none), whether the runtime programs it, the divisor and its fraction. | `System.Text_IO` |
| `__mpfs_harts_mask` | Bit n set: hart n belongs to the partition. A hart outside the mask is parked in `wfi`. | `start.S`, `sections.ld` (debug constant) |
| `__stack_size`, `__interrupt_stack_size` | The stack of the environment task and the interrupt stacks. | `sections.ld` |
| `MPFS_*_LENGTH`, `MPFS_LOCAL_ITIM_ORIGIN` | The lengths of the regions (the origins are literals). | `mpfs-memory.ld` |

The rules: there are no defaults, so a missing symbol is a link error ("undefined reference" or
"undefined symbol ... referenced in expression"); an invalid value is stopped by an `ASSERT` of the
linker scripts (a size that is not a multiple of 16, an empty region, overlapping `.bss`, stacks, heap
and trap record, a mask outside the harts 0 to 4, `_start` not at the start of the lowest segment) or
by `Compile_Time_Error` in the partition package. The value symbols are read with `lui` and `addi`
(not through an imported address, which the compiler knows to be non-null). The negative builds are in
the host suite `rts_boot`. The placements `place-lim.ld`, `place-scratchpad.ld` and `place-envm.ld`
bind the region names of `sections.ld` to the regions of `mpfs-memory.ld`; the section "Start code and
linker base" of the runtime README has the order of the start code, the memory initialisation and the
table of placements.

### 3.1 Partition data and `./x build`

An image built without a system description (every example and test) gets its partition data from
`config/gen/standalone.py`, which writes two files to `build/partition/<example>-<hart>/`: the Ada package
`MPFS_Partition` (the values as named numbers and one static `Compile_Time_Error` per rule) and the list of
link symbols that becomes the `--defsym` values (RTS-019). `./x build` runs it with its own options
(`--hart`, `--harts`, `-P`, `--console`, `--console-init`, `--memory`, `--role`, the stack sizes, and options
after `--`), compiles the package against the variant before it links, and passes the list to the link through
`mpfs_link.gpr`; a violated rule therefore stops the build and leaves no image. The parameters, the defaults,
the symbol list, the checks and the negative build of each are described in
[`config/README.md`](../../config/README.md); the configuration generator will write the same two files from a
system description. The test set per profile and hart class, with the negative builds and where each lives, is
[`test-matrix.md`](test-matrix.md).

## 4. Own port units

The authoritative list of the board files that may differ from the toolchain's runtimes is
[`port_units.list`](../../crates/mpfs_rts/port_units.list), with the upstream file each replaces; the
files are in `mpfs/gnat`, `mpfs/gnarl` and `overlays/`.

| Unit | What it is | Upstream |
|---|---|---|
| `a-intnam.ads` | Generated from the SVD. | `a-intnam` of the pack |
| `context_switch.S`, `riscv_def.h` | The FP restore from the incoming task; assembly-time checks of the frame against the float ABI. | the same files |
| `link-zcx.spec` | The embedded link spec, without `--eh-frame-hdr`. | `link-zcx.spec` of the pack |
| `overlays/tlsf/embedded/gnat` | `tlsf_core`, `tlsf_math`, `heap_guard`, `mpfs_heap`, `mpfs_heap_lock`. | `s-memory` (bump allocator; `System.Memory` of the pack stays) |
| `s-bbbopa.ads` | `Clock_Frequency` (1 MHz `mtime`); no hart and no console literals. | `s-bbbopa__polarfiresoc` |
| `s-bbbosu.adb` | Board initialisation of the own PLIC context; `Power_Down` is `wfi`. | `s-bbbosu__riscv` |
| `s-bbhart` | `System.BB.Hart.Id`, from `mhartid`. | hart literals in several units |
| `s-bbricl` | The CLINT: `Mtime`, `Mtimecmp (Hart)`, `MSIP (Hart)`. | the CLINT code of `s-bbsuti` |
| `s-bbripl` | The PLIC of the own hart: context from `mhartid`, 32-bit accesses to PAC registers, the priority mapping. | `s-bbripl` of `polarfiresoc` |
| `s-bbsuti.adb` | The tickless timer on `mtimecmp` of the own hart. | `s-bbsuti__riscv_clint` |
| `s-textio.ad[sb]` | The polled MMUART console driven by link symbols. | `s-textio__ns16550` |
| `start.S` | Entry of every image: `mtvec` first, hart gate, `.data`, `.bss` and stacks with 64-bit stores, `mstatus.FS`, constructor arrays, `main`, exit by role; the early trap stub and the trap record. | `start-ram.S` |
| `start_fast.S` | `start.S` with the check and the copy of the application's ITIM and DTIM sections (section 5.5). | none |

`s-bbpara.ads` (the interrupt range 1 to 186, one CPU) and the system packages of the profiles come
from the fork `crates/bb-runtimes` (`s-bbpara__polarfiresoc.ads` and the `system-xi-riscv*` files
of the pack); the fork is not changed by the work described here. `trap_handler.S` and the unit
`s-bbcpsp` (`Context_Buffer`) are upstream and unchanged.

## 5. How the parts fit

### 5.1 Heap and secondary stack

`light` and `light-tasking` keep the bump allocator of upstream (`free` does nothing). `embedded`
has the TLSF allocator behind `malloc`, `free`, `realloc` and `calloc`, defined once by `MPFS_Heap`
over the memory from `__heap_start` to `__heap_end`; libgcc's unwinder calls `malloc` and `free` by name,
so both stay (RTS-012). The lock around the allocator is the single place that has to change for
more than one hart: today it clears `mstatus.MIE` and restores it. The secondary stack is the
upstream unit with sizes chosen by `gen_runtime.sh` (RTS-013). Description: "Heap and secondary stack" in
the runtime README; the SPARK proofs of `Tlsf_Math` and `Heap_Guard` run with `./x prove`
(`tests/prove/tlsf`).

### 5.2 Console

`System.Text_IO` replaces the upstream driver for all three profiles: polled, one MMUART, chosen and
(optionally) initialised through the four `__mpfs_console_*` symbols, console `none` possible. The
runtime never releases the clock or the reset of the MMUART; that is the boot stage's task (RTS-014).
The console of the runtime follows the hart: the partition data default it to the MMUART of the lowest
hart of the mask (MMUART0 for hart 0, MMUARTn for U54 hart n). `Bare_Console`, through which most
examples write their `Test_Report` lines, stays on MMUART0 on every hart; only the console of the
runtime moves (checked by `tests/host/standalone`). Only MMUART0 to MMUART3 are brought out on the Icicle Kit.
See "Console".

### 5.3 Tick and idle

There is no periodic tick. `System.BB.Time` computes the next alarm of the hart and
`s-bbsuti.adb` writes it to `mtimecmp` of that hart with one 64-bit store; the same register, set to
the maximum, is the acknowledge and the disarmed state. The idle task executes `wfi` with interrupts
enabled (RTS-009, RTS-010). `Clock_Frequency` is 1 MHz; that `mtime` really runs at that rate is
checked at compile time against the clock of the partition (the clock is not part of the standalone partition
data, so an example uses a stand-in package for the check) and on the hardware, where the absolute rate is not yet measured (section 8). See "Tick and idle".

### 5.4 Interrupt names and priorities

`Ada.Interrupts.Names` is generated from the `<interrupt>` elements of the merged SVD and
`svd/additions/local_interrupts.yaml`; the generator refuses an `Interrupt_Range` that is not the
range of the PLIC sources (SVD-002). The seven Ada interrupt priorities of the tasking profiles are
the PLIC levels 1 to 7; `RISCV_PLIC.Level_Of` is the one place of the mapping (RTS-015). See
"Interrupt names" and "Interrupt priorities".

### 5.5 ITIM and DTIM

The application owns the sections: `.fast_text` (code that runs from the ITIM) and `.fast_data`
(data in the DTIM, E51 only) are declared by the application's own `app-sections.ld`, the hook that
`sections.ld` includes, and the runtime has none (RTS-017). What only the runtime can do is in
`start_fast.S`: `start.S` assembled with the check and the copy step, which `Mpfs_Link.Fast_Switches`
puts on the link line of such an image (an image without the sections has the ordinary `start.S`).
Six symbols that the application's sections define say where the ranges run and where they are
loaded; the start code checks both ranges with a pattern, copies them and executes `fence.i`, and if a
range is not backed by memory it does not return but writes a record at `__mpfs_trap_record`
(which memory, which address, `mcause`) and stops. Malformed ranges stop the link. Enabling the ways
is the boot stage's task. QEMU has no ITIM: `itim_test` runs the copy with run addresses in the LIM, and
`itim_reject_test` shows the rejection; whether the real ITIM works is a hardware question (RTS-016).
The decision, the contract of the six symbols and the record are in the section "ITIM and DTIM" of the
runtime README.

### 5.6 Exceptions

Only `embedded` propagates exceptions. The unwinder is the registration-based one of libgcc, because the
linker of the toolchain does not know `--eh-frame-hdr`, which the upstream unwinder needs: own link spec,
the upstream unwinder removed from the library (`remove.list`), the constructor arrays run by `start.S`
before `main`, `.eh_frame` bracketed in the linker script (RTS-011). The decision, the spike and the
evidence are in [`docs/design/exceptions.md`](../design/exceptions.md); the mechanism is "Zero-cost
exceptions" in the runtime README.

## 6. Deviations from upstream bb-runtimes

Everything not listed is the upstream source, which `compare_toolchain.sh` proves against the
shipped runtimes (RTS-002).

| Deviation | Why |
|---|---|
| Board `mpfs` in `crates/bb-runtimes`, hart class as a parameter, one CPU, no `-T` in `runtime.xml` | One library for all placements; the fork carries no other board. |
| `start.S` instead of `start-ram.S`; hart gate on every image, also secondary ones | Upstream hard-wires hart 1; QEMU sends every hart to the entry point and has no gate of its own. |
| Constructor arrays run by a loop in `start.S` instead of `__libc_init_array` | `light` links with `-nolibc`; a weak call to an absent symbol is out of reach from DDR. |
| `context_switch.S` loads `fs0` to `fs11` from `a1` | Upstream restores them from the outgoing task (every switched-in task got the registers of the one switched out); the defect is in the `gnat-fsf-15` and `gnat-fsf-16` branches and in the shipped toolchain. The overlay can go when the sources contain AdaCore's fix. |
| `fcsr` is not part of the context | Nothing in the runtime or the project changes the rounding mode; the decision and the way back are in the runtime README. |
| PLIC and CLINT without hart literals, 32-bit PLIC accesses only, through the PAC | Upstream hard-wires hart 1 and `mtimecmp` at `0x4008`; a 64-bit store into the PLIC is an error of the SoC. |
| `Threshold` returns an Ada priority | Upstream compared an Ada priority with a PLIC level, so its assertion could never fail. |
| `Power_Down` is `wfi` | Upstream is `null`, the idle task would poll. |
| Timer disarmed before the handler is installed; one 64-bit access | After reset `mtimecmp` is undefined on the SoC; no spurious first tick. |
| `System.Text_IO` driven by link symbols | Upstream has fixed addresses and always initialises. |
| `Ada.Interrupts.Names` generated; `Interrupt_Range` is 1 to 186 | The upstream list covered a few sources only. |
| `link-zcx.spec`, `unwind-dw2-fde-bb.c` removed | See section 5.6. |
| TLSF heap for `embedded`, secondary stack defaults | The upstream defaults (1 MiB, 512 KiB) do not fit the 1920 KiB of the LIM. |
| `s-textio.ads` with `No_Elaboration_Code` | The body names the PAC, which has the weaker restriction. |

## 7. Requirements and tests

Every requirement of `rts.yaml` and the tests that carry its `@verifies` tag. The host suites are in
`tests/host/rts_*`; the examples run under QEMU (`tests/qemu/tests.list`, `./x qemu`) for the E51 and
the U54, and U54 hart 3 for some. The list is the one of [`trace-matrix.md`](trace-matrix.md), which is
generated and authoritative; this table adds what each requirement is about. A test that runs in several
profiles is one example per profile with shared sources (`textio_tasking_test`, `trap_embedded_test`,
`protected_embedded_test` and so on); the tag is on the shared source of the example with the plain name, and
[`test-matrix.md`](test-matrix.md) names the image of every cell.

| ID | About | Host suite | QEMU example |
|---|---|---|---|
| RTS-001 | Packs reproducible, hashes committed | `rts_packs` | |
| RTS-002 | Common sources equal the toolchain's | `rts_packs` | |
| RTS-003 | The variant build and its refusals | `rts_variants` | |
| RTS-004 | Link-time interface, negative builds | `rts_boot` | |
| RTS-005 | Trap record (early) and the trap in the last chance handler (embedded) | | `trap_test`, `trap_embedded_test` |
| RTS-006 | PLIC and CLINT of the own hart | `rts_plic` | `interrupt_test` |
| RTS-007 | Context switch, FP registers, trap frame | `rts_context` | `fp_context_test` |
| RTS-008 | Floating point, E51 soft and U54 hard | `rts_itim` (the images) | `float_test` |
| RTS-009 | Tickless timer, `delay until` | `rts_tick` | `tasking_test`, `delay_accuracy_test` |
| RTS-010 | Idle with `wfi` | `rts_tick` | `delay_accuracy_test` |
| RTS-011 | Zero-cost exceptions | `rts_zcx` | `exceptions_test`, `unhandled_test`, `unhandled_task_test` |
| RTS-012 | The TLSF heap | `rts_heap` | `heap_test` |
| RTS-013 | The secondary stack | `rts_heap` | `secstack_test`, `secstack_light_test`, `secstack_tasking_test` |
| RTS-014 | The console | `rts_boot` | `textio_test`, `console_none_test` |
| RTS-015 | Interrupt priorities and PLIC levels | | `interrupt_test` |
| RTS-016 | Runs on the Icicle Kit | | |
| RTS-017 | ITIM and DTIM sections of the application | `rts_itim` | `itim_test`, `itim_reject_test` |
| RTS-018 | Order of elaboration, library tasks | | `elab_test`, `elab_tasking_test` |
| RTS-019 | Standalone partition data, `MPFS_Partition` checks | `standalone` | |
| RTS-020 | Profile restrictions | `rts_negative` | |
| RTS-021 | Protected objects and timing events | | `protected_test` |
| SVD-002 | Interrupt names from the SVD | `rts_intnam` | `interrupt_test` |

**No test yet:** RTS-016. The tests of the examples are written to run on the board as well, but the hardware
runs are not a check of this repository (`./x hw run` needs a board in the lab, and not every cell has
been run); until a hardware report is part of a check, the requirement stays without a `@verifies`
and `./x trace` lists it as such. The runs on the Icicle Kit are recorded in [`docs/lab/results/p1.md`](../lab/results/p1.md).
Checks that are not tied to a requirement: the proofs of the heap arithmetic (`./x prove`), the
sizes of all images (`metrics.golden`, BLD-003) and the negative build of the ABI mismatch (BLD-002).

## 8. Open points

- **Hardware.** The runs on the Icicle Kit (`docs/lab/results/p1.md`: 72 cells pass, 3 are skipped; `mtime`
  at 1 MHz; the interrupt latency behind `Interrupt_Latency_Ticks`) are a report, not a check of this
  repository, so RTS-016 stays without a test. They are the runs of one board; the report lists what they
  do not cover.
- **Interrupt stack of the embedded profile.** The first unwind inside a trap handler may overflow the 8 KiB
  interrupt stack on the U54; `trap_embedded_test` works around it by raising one exception first
  (issue #91). RTS-005 holds for that test as it is.
- **ITIM and DTIM on the board.** QEMU cannot show that the real ITIM and DTIM work once the boot stage
  has enabled them (section 5.5); `itim_test_e51` passes on the board with `.fast_text` in the ITIM, and the
  report says what else is not covered.
- **GNAT 16.** The pin is 15.3.1. The switch needs the v16 runtime sources; the link spec,
  `remove.list` and `start.S` have to be reviewed then (the exceptions design note has the details).
- **SMP and user mode** are not part of this runtime. The port units are written for it (hart
  index, the lock interface of the heap, `mcause` 3 in the trap handler); the requirements come with that
  work. `start.S` runs the constructor arrays on every hart that runs the image; an SMP runtime must let only the
  first hart of the mask do it, because `.eh_frame` is registered once.
