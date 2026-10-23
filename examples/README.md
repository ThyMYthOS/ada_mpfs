# `examples/`

- **Purpose:** Example programs (template: `examples/STYLE.md`).
- **Owning phase:** P0.7 onwards
- **License:** Apache-2.0

`./x list` prints the examples with their default hart; `./x new <name>` scaffolds a new one. The
conventions (project layout, scenario variables, `example.conf`) are in `STYLE.md`.

| Example | Harts | What it does | Checked by |
|---|---|---|---|
| `bare_hello` | E51, U54 | The smallest image there is, without runtime: prints `bare hello E51 hart 0` or `bare hello U54 hart 1` on MMUART0. | `./x test qemu` (smoke), `./x test renode`, `./x test negative`, `metrics.golden` |
| `pmp_probe` | E51, U54 | Counts the PMP entries of the hart that runs it and prints the count and a mask. | `./x test qemu` (smoke), `./x test renode` |
| `report_test` | E51, U54 | The first application of the `Test_Report` protocol: checks the hart id, the compressed extension and the F and D extensions of the hart class. | `./x test qemu` (`tests/qemu/tests.list`) |
| `tasking_test` | E51, U54 (hart 1), U54 hart 3 (`u54-h3`) | The tasking runtime runs on the hart of the image: two tasks of different priority wake at the same instant (the higher runs first, none early), `delay until` and `Clock` bounds, a periodic 10 ms task over 200 ms. Linked with a `light-tasking` runtime variant that `crates/mpfs_rts/gen_runtime.sh` builds (`RUNTIME=mpfs_rts`); reports with `Test_Report` as `tasking_test_e51`, `_u54`, `_u54h3`. | `./x build tasking_test --hart e51\|u54 [--harts 3]`, `./x test qemu` (`tests/qemu/tests.list`, `console.expected`, QEMU with `-smp 5`), `./x test examples`, `./x repro`, `metrics.golden` |
| `interrupt_test` | E51, U54 (hart 1), U54 hart 3 (`u54-h3`) | The PLIC and the CLINT of the runtime are those of the hart that runs the image (P1.4): `Context_Of` and the register addresses of all five harts against the PAC, an `Attach_Handler` on MMUART0 (source 90) that receives `console.in` through the own PLIC context, enable/priority/threshold of the own context, `msip` read and clear, `mtimecmp` of the other harts untouched. Linked with a `light-tasking` variant and the PAC (`mpfs_pac.gpr`); reports as `interrupt_test_e51`, `_u54`, `_u54h3`. | `./x build interrupt_test --hart e51\|u54 [--harts 3]`, `./x test qemu` (`console.in`, `console.expected`, `-smp 5`), `tests/host/rts_plic` (no 64-bit store into the PLIC window), `./x repro`, `metrics.golden` |
| `fp_context_test` | U54 | Regression test for defect no. 1 (FP context, P1.5): three tasks hold a different value in each of the callee-saved registers `fs0` - `fs11` across `delay until` (two of them) and across the timer interrupt (one that never waits) and check that they still have it. Passes with the fixed `context_switch.S` of the runtime; with the upstream restore from `t0` all twelve registers of all three tasks are lost. Linked with a `light-tasking` variant; reports as `fp_context_test_u54`. | `./x build fp_context_test`, `./x test qemu` (`tests/qemu/tests.list`, `console.expected`), `tests/host/rts_context`, `./x repro`, `metrics.golden` |
| `float_test` | E51, U54 | Floating point on both hart classes (P1.5): arithmetic and rounding bit for bit against IEEE 754, `Float` and `Long_Float`, the rounding attributes and conversions, `Sqrt` (exact on the U54, within 2 ulp of the software square root on the E51) and `'Image` against the reference text. Linked with the `light` variant (soft float on the E51, hard float on the U54); reports as `float_test_e51`, `float_test_u54`. | `./x build float_test --hart e51\|u54`, `./x test qemu` (`tests/qemu/tests.list`, `console.expected`), `./x repro`, `metrics.golden` |
| `trap_test` | E51, U54 | An early trap is reported correctly (defect no. 5: `mtvec` before the first trap): an illegal instruction during elaboration goes through the trap stub of the runtime's `start.S`, and the test checks the recorded `mcause`, `mepc`, `mtval` and hart and reports with `Test_Report`. Linked with the `light` runtime variant (`RUNTIME=mpfs_rts`); `MPFS_PLACEMENT` and `MPFS_BOOT_ROLE` select the boot scenario. | `./x test qemu` (`tests/qemu/tests.list`, `console.expected`), `tests/host/rts_boot`, `./x repro`, `metrics.golden` |
| `common/` | | Not an example: the linker scripts and the build script that the examples share (see its `README.md`). | |

Run an example under QEMU with `./x qemu <name> [--hart N]`, or on the Icicle Kit with
`./x hw run <name> --uart-standin --expect REGEX` (`--uart-standin` because nothing sets the UARTs up in
boot mode 0; see `hw/README.md`). The bare images are linked into the L2 LIM and are loaded by
OpenOCD; none of them is placed in the eNVM yet.
