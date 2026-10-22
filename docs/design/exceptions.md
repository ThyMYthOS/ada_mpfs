<!--
SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
SPDX-License-Identifier: CC-BY-4.0
-->
# Zero-cost exceptions in the embedded runtime (R8)

Design note of work package P1.7 (#48, part of #41). The mechanism is described where it lives, in
[`crates/mpfs_rts/README.md`](../../crates/mpfs_rts/README.md#zero-cost-exceptions-p17-r8); this note gives the
decision, the evidence and what was not done.

## Decision

The `embedded` profile of `mpfs_rts` propagates exceptions with the **zero-cost model (ZCX)**, and finds the unwind
tables with the **registration-based unwinder of libgcc**: `crtbegin.o` registers `.eh_frame` with
`__register_frame_info` from `.init_array`, which `start.S` runs before `main`. No `.eh_frame_hdr`, no linear search of
our own, no SJLJ. `light` and `light-tasking` have no exception propagation and are not concerned.

## Problem

- bb-runtimes (`v15.1.0-1`, and `v16.1.0-1` unchanged) links the embedded profile with `link-zcx.spec`
  (`-u _Unwind_Find_FDE --eh-frame-hdr`) and its unwinder `unwind-dw2-fde-bb.c` finds the FDEs only through
  `__eh_frame_hdr`.
- `riscv64-elf-ld` knows no `--eh-frame-hdr` (binutils 2.46.1 in the pinned GNAT 15.3.1 toolchain; GNAT 16 has the same): the link
  stops with `unrecognized option '--eh-frame-hdr'`. Without the option there is no `.eh_frame_hdr` and the bb unwinder
  asserts in `uw_init_context_1` at the first raise (the symptom that ada-machine recorded).

## Spike

The path derived on paper in #41 section 3a was linked and **executed** under QEMU 10.2.1 (`microchip-icicle-kit`, five
harts) for the E51 (hart 0) and for the U54 (hart 1), with `examples/exceptions_test`. It worked at the first run; what
had to change from the paper version:

| Step of #48 | Result |
|---|---|
| 1. libgcc's `unwind-dw2-fde.o` instead of the bb unwinder | Works. The bb unwinder is also taken out of `libgnat.a` (`mpfs/remove.list`, `embedded: gnat/unwind-dw2-fde-bb.c`), because with two definitions of `_Unwind_Find_FDE` the order of the archives would decide silently. |
| 2. own spec: `crti`, `crtbegin`, `-u __register_frame_info`, `crtend`, `crtn`; `-lgcc` first in the group | Spec as written (`crates/mpfs_rts/link-zcx.spec`). `-lgcc` first is **not needed**: after the removal there is one `_Unwind_Find_FDE` and `-u __register_frame_info` pulls the object that has it. |
| 3. `start.S` calls `__libc_init_array`; `.init_array`, `.fini_array`, `KEEP(.eh_frame)` | The arrays and the `KEEP` as written. **`start.S` runs the arrays with a loop instead of calling `__libc_init_array`**: `light` and `light-tasking` link with `-nolibc` (the call would not resolve), and a weak call is out of reach of `auipc`/`addi` above `0x8000_0000`. `__libc_init_array` itself needs only the weak array symbols and runs the same entries. |

Findings of the spike besides the path itself:

- libgcc's `unwind-dw2-fde.o` calls `malloc` and `free` once, at the first search, to sort the FDEs; the heap of the
  embedded runtime is newlib's `malloc` over `__heap_start` .. `__heap_end`. If `malloc` returns null libgcc falls back
  to a linear search, so a missing heap is slower, not wrong. P1.8 must keep the two symbols.
- `crtbegin.o` and `crtend.o` bring `.tm_clone_table`, `.fini_array` and 160 bytes of code that only a hosted program
  needs (`__do_global_dtors_aux`, `register_tm_clones`); `--gc-sections` keeps what the arrays refer to. The
  cost is small and accepted, in exchange for the standard mechanism that also runs the constructors of C code.
- The default stacks of the embedded profile (1 MiB secondary stack, 2 MiB per task) do not fit the LIM
  (1920 KiB). `exceptions_test` sets `-D8k` and the aspects `Storage_Size` and `Secondary_Stack_Size` of its tasks.

## Evidence

All under QEMU 10.2.1 with `-smp 5`, `./x test qemu`:

| Test | Result |
|---|---|
| `exceptions_test_e51`, `exceptions_test_u54` | 16 checks: raise, propagation through five frames, `Exception_Name`/`Message`/`Information`, `raise;`, `Reraise_Occurrence`, `Constraint_Error` from a division and a range check, `Program_Error`, finalization during propagation, an exception raised in a handler, an exception handled in a task, the constructor arrays |
| `unhandled_test_*`, `unhandled_task_test_*` | An exception that nobody handles, in the environment task and in a task, reaches `__gnat_last_chance_handler` once with its identity and its message: the unwinder reaches the end of the stack (`_start` has no FDE) and does not crash |
| `tests/host/rts_zcx` | The premise (the linker rejects the option), the spec, the variants, the images: no `.eh_frame_hdr`, libgcc's `_Unwind_Find_FDE` and `__register_frame_info`, `frame_dummy` in `.init_array`, `.eh_frame` and its brackets |
| `tests/host/rts_boot` | The arrays and `.eh_frame` in every boot scenario, a constructor entry and an entry of the wrong size |

The tests can fail. With `start.S` built without the two constructor loops (a scratch variant, not committed) the same
`exceptions_test_u54` image prints `FAIL: the constructor arrays ran in order before main`, and at the first raise the
hart takes a load access fault (`mcause` 5, `mtval` 0x2f0, a small offset from a null pointer; the cause was not
analysed further) and loops in the trap stub: START but no verdict, which `run_tests.sh` reports as
a hang.

The hardware run (E51 and U54 on the Icicle Kit) is P1.14 (#55) and has **not** been done.

## Not done, and why

| Alternative | Status |
|---|---|
| (a) own `_Unwind_Find_FDE` that searches `__eh_frame_start` .. `__eh_frame_end` linearly (SPARK-suitable, no header, no `malloc`) | Not needed: the path of #48 works. It would save about 5.5 KiB of code (`unwind-dw2-fde.o`) and the dependency on `malloc`. The brackets and the zero word that it needs are in place and checked, so it can be added without touching the link. |
| (b) SJLJ | Not needed; a project decision that was not taken. |
| `.eh_frame_hdr` by a linker script (`PT_GNU_EH_FRAME`-style table made by hand) | Not tried: the table must be sorted by address and is made by the linker, not by a script. |

## Consequences for the plan

- #48 step 3 (`__libc_init_array`) and step 2 (`-lgcc` first) are replaced as in the table above; the acceptance
  criterion on QEMU is met, the one on the hardware belongs to P1.14.
- The registration is run by every hart that runs the image (`start.S`); P8 must restrict it to the first hart of the
  mask.
- Adopting the v16 runtime sources keeps this design: the spec, the removal and `start.S` replace what v16 has.
