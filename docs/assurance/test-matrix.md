<!--
SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
SPDX-License-Identifier: CC-BY-4.0
-->
# The test set of the runtime: tests, profiles, hart classes

The runtime of `crates/mpfs_rts` has six cells for one hart in machine mode: the three profiles `light`,
`light-tasking` and `embedded`, each for the hart classes E51 and U54. The detail plan (#41, section 5) says which test
runs in which cell, on QEMU and on the Icicle Kit. This page is that table as it is implemented, so that it can be
reviewed: what an image is called, where it is built, which row of `tests/qemu/tests.list` runs it, what is
left for the hardware (#55), and where each negative build lives.

Rules the set keeps (checked by `tests/host/qemu_tests`):

- every test reports with `Test_Report` (`TEST <name>: START`, `ok:`/`FAIL:` lines, `TEST <name>: PASS|FAIL`);
- every cell of the table that is marked for QEMU is one image and one row of `tests/qemu/tests.list`
  (`<image>_e51`, `<image>_u54`), and runs under `./x test qemu` and in the `qemu` job of CI;
- there is no `xfail` row and no skipped cell on QEMU: a test that cannot pass on QEMU is not listed, and the reason is
  in the section on the hardware below, not in a row that hides it;
- a test that runs in several profiles is one example per profile that shares the sources (`examples/STYLE.md`,
  "Profile variants"); the image carries the profile in its name.

## The matrix

Each cell names the example whose image runs there (`<example>_e51`, `<example>_u54` are the rows of the list). A dash is a
cell the plan does not mark. **Bold** are the cells that this work added; the others existed.

| Test | light E51 | light U54 | light-tasking E51 | light-tasking U54 | embedded E51 | embedded U54 |
|---|---|---|---|---|---|---|
| `textio_test`: output and input over the console | `textio_test` | `textio_test` | **`textio_tasking_test`** | **`textio_tasking_test`** | **`textio_embedded_test`** | **`textio_embedded_test`** |
| `console_mmuartN_test` (N = 1 to 4): console selection by link symbols | `textio_test` (`console_mmuart1_test` .. `4`) | same | - | - | - | - |
| `trap_test`: illegal instruction, diagnosis and last chance handler | `trap_test` | `trap_test` | **`trap_tasking_test`** | **`trap_tasking_test`** | **`trap_embedded_test`** | **`trap_embedded_test`** |
| `float_test`: arithmetic, `Sqrt`, `'Image` (soft float on the E51) | `float_test` | `float_test` | **`float_tasking_test`** | **`float_tasking_test`** | **`float_embedded_test`** | **`float_embedded_test`** |
| `tasking_test`: `delay until`, priority order, `Clock` | - | - | `tasking_test` | `tasking_test` | **`tasking_embedded_test`** | **`tasking_embedded_test`** |
| `protected_test`: entry barriers, `Timing_Event` | - | - | **`protected_test`** | **`protected_test`** | **`protected_embedded_test`** | **`protected_embedded_test`** |
| `fp_context_test`: callee-saved FP registers across `delay` | - | - | no FPU | `fp_context_test` | no FPU | **`fp_context_embedded_test`** |
| `interrupt_test`: `Attach_Handler`, ceiling, PLIC context of the own hart | - | - | `interrupt_test` | `interrupt_test` | **`interrupt_embedded_test`** | **`interrupt_embedded_test`** |
| `delay_accuracy_test`: deviation of `delay until`, idle in `wfi` | - | - | `delay_accuracy_test` | `delay_accuracy_test` | **`delay_accuracy_embedded_test`** | **`delay_accuracy_embedded_test`** |
| `exceptions_test` (with `unhandled_test`, `unhandled_task_test`) | - | - | - | - | `exceptions_test` | `exceptions_test` |
| `secstack_test`: functions with unconstrained result | `secstack_light_test` | `secstack_light_test` | `secstack_tasking_test` | `secstack_tasking_test` | `secstack_test` | `secstack_test` |
| `heap_test`: TLSF, random allocation and release | - | - | - | - | `heap_test` | `heap_test` |
| `elab_test`: elaboration order, library tasks | **`elab_test`** | **`elab_test`** | **`elab_tasking_test`** | **`elab_tasking_test`** | **`elab_embedded_test`** | **`elab_embedded_test`** |

The hart classes of one image are the harts the example names in `BUILD_HARTS`: `e51` (hart 0) and `u54` (hart 1). The
images of `tasking_test`, `interrupt_test` and `delay_accuracy_test` of the `light-tasking` profile are also built for U54
hart 3 (`_u54h3`, one image per hart because the mask is link-time data); the `embedded` variants are not, the cell is the
hart class.

Not in the plan's table but in the list, as the plan's text asks for them or because they close a gap of the same
tests: `report_test` (the protocol itself), `console_noinit_test` and `console_none_test` (the console variants of the
partition), `itim_test` and `itim_reject_test` (the E51 fast path: the copy step, and the rejection where the ITIM is
not enabled), `unhandled_test` and `unhandled_task_test` (an exception nobody handles, in the environment task and in a
task).

### Differences between the cells of one test

- `trap_test`: in the `light` and `light-tasking` profiles the trap happens while the units are elaborated, before the
  runtime has installed its own trap handler, so the trap stub of the start code writes the record that the test
  checks. The `embedded` runtime installs its handler before the first unit of the application is elaborated; the trap
  arrives as `Program_Error` in the last chance handler, where `trap_embedded_test` reads `mcause`, `mepc` and
  `mtval`. See the finding at the end.
- `float_test`: the E51 images are soft-float (`lp64`, `Sqrt` of the runtime within 2 ulp), the U54 images hard-float; the
  expected console is the same.
- `textio_test`: the other consoles (`console_mmuartN_test`, `console_noinit_test`) are selected by link symbols that do
  not depend on the profile; they are built for the `light` profile only, as in the plan.

## QEMU and hardware

The plan has one more column per test: what the check is on the board. Only these differ from the QEMU image:

| Test | On QEMU | On the Icicle Kit |
|---|---|---|
| `interrupt_test` | the receive interrupt of MMUART0 is raised by `console.in` | the interrupt is raised by the loopback of the MMUART (`MCR.LOOP`) |
| `delay_accuracy_test` | loose bound (QEMU's `mtime` follows the host clock); the idle is checked as `wfi` before `mepc` | `DELAY_ACCURACY=hardware`: 2 ticks plus interrupt latency; `minstret` stays flat over 100 ms |
| `console_mmuartN_test` | N = 1 to 4 | N up to 3 (the CP2108 has three ports) |
| `itim_test`, `itim_reject_test` | the ranges are in the LIM (QEMU has no ITIM and no scratchpad) | the ITIM at `0x0180_0000` itself |

Everything else runs the same image on both.

### For the hardware runs (#55)

These are checks that only make sense on the board, or that QEMU cannot do. None of them is in `tests/qemu/tests.list`:

- the scratchpad placement (`--memory scratchpad`): the images are built (`tests/host/rts_boot`), QEMU has no scratchpad;
- the real ITIM: execution of `.fast_text` from `0x0180_0000` (`itim_test` with `ld/` of the board), the check word;
- the absolute rate of `mtime` and `Interrupt_Latency_Ticks` on all harts (the placeholder is 30 ticks);
- `delay_accuracy_test` with the hardware bounds and the flat `minstret` over 100 ms;
- `interrupt_test` with the loopback instead of `console.in`;
- whether the heap and `.noinit` need clearing of the ECC memory (`heap_test`, `exceptions_test` on the board);
- the hart cells that QEMU runs only with `-smp 5`: the images of U54 harts 2 to 4;
- `trap_embedded_test` on the board: `mepc` and `mtval` as the core delivers them (QEMU delivers the instruction in
  `mtval`; the check also allows 0).

## Negative builds

The negative builds of the plan, each with where it is tested. Together they are the ones of the plan (#41, section 5) plus
the Ada-side checks of the partition package; the new suite is `tests/host/rts_negative`, which also checks that the
entries of the other suites are still there.

| Negative build | Must fail with | Where |
|---|---|---|
| a task in the `light` profile | `violation of implicit restriction "No_Tasking"` | `tests/host/rts_negative` (E51 and U54) |
| an abort statement, a task allocator in `light-tasking` and `embedded` | `violation of restriction "No_Abort_Statements"`, `"No_Task_Allocators"` (and the control: a task in a library package compiles) | `tests/host/rts_negative` |
| an E51 object linked with the library of the U54 (and the reverse) | the linker's `float modules with` ABI message, no image (and the control: same hart class links) | `tests/host/rts_negative` (the objects of the bare images: `tests/negative`) |
| a mandatory link symbol missing | `undefined reference to` the symbol, or `undefined symbol ... referenced in expression` for those the linker script reads | `tests/host/rts_boot` (`missing_*`) |
| a mask that mixes the E51 and the U54 | `a partition mask must not mix the E51 and U54 harts` (`Compile_Time_Error` of `MPFS_Partition`) | `tests/host/standalone` |
| a stack size that is not a multiple of 16 | the linker's `__stack_size is not a multiple of 16` and the check of the partition package; likewise for the interrupt stack and the secondary stack | `tests/host/rts_boot`, `tests/host/standalone` |
| the console `ram_fifo` before SMP exists | `the console ram_fifo needs a second hart; SMP does not exist yet` | `tests/host/standalone` |
| the other checks of the partition package (L2 way sum, LIM ways, DTIM on a U54, ITIM above the size of its hart, boot role) | the message of the check | `tests/host/standalone` |
| a stack that leaves no room, an empty region, an invalid mask, a `_start` that is not first, an `.init_array` entry that is not 8 bytes | the linker's message | `tests/host/rts_boot` |

## Finding: the interrupt stack and the first exception in a trap

`trap_embedded_test_u54` hangs without a verdict if the first exception of the program is raised in a trap
handler: libgcc sorts its frame descriptions at the first unwind (this takes memory from the heap, which starts at its first
use), and with the U54's larger frames that takes more than the 8 KiB of the interrupt stack of the runtime
(`Interrupt_Stack_Size` in the unmodified fork, `crates/bb-runtimes`). Under QEMU the stack pointer reaches the last 16
bytes of the stack, the next frame overwrites the `.bss` behind it (libgcc's register size table first), and the unwinder
stops at an assertion. The E51 image, with smaller frames, is not affected. The test raises and handles one exception
before the trap (`Warm_Up_Unwinder`), which makes the unwinder's tables exist, and says so in its README and its source.
The cause is a stack size of the runtime, not of the test; it needs a decision in the runtime work (a larger interrupt
stack for the `embedded` profile, or an overflow check), and is reported with this change.
