# `tests/qemu/`

- **Purpose:** QEMU tests: the smoke test and the test applications that report with `Test_Report`.
- **License:** Apache-2.0

| File | Content |
|---|---|
| `smoke.sh` | `./x test qemu`: boots every image named in `smoke.expected` under QEMU and asserts what it printed on MMUART0. QEMU that is missing, too old (`QEMU_MIN` in `tools/toolchain.env`) or without the machine, a missing image and an empty console are failures, never skips. |
| `smoke.expected` | The expectations, `image<TAB>string`, edited by hand. |
| `qemu_preflight.sh` | The QEMU preconditions, sourced by `smoke.sh`. |
| `run_tests.sh` | `./x test qemu` (after the smoke test): boots every row of `tests.list` and asserts its verdict. A `pass` test needs its image, the `TEST <name>: START` and `TEST <name>: PASS` lines on its serial port, no `FAIL:` line, every line of its `<image>.expected` (else of `console.expected`, in the example directory) and silence on the other four ports. An `xfail` row documents a known defect and must fail with its `observe` signature: an unexpected pass or a different failure fails the run. A hang is killed by a watchdog and fails. An empty or malformed list fails. `./x test qemu tests [name...]` runs only these (and only the named ones), `./x test qemu smoke` only the smoke test. |
| `tests.list` | The rows `name, dir, serial, expect, observe, why`, TAB-separated, edited by hand. |

The `Test_Report` protocol (`tests/common/test_report.ads`; `tests/host/common/host_report.ads` prints the same lines on the host) is the same at every level: `TEST <name>: START`, `  ok: <what>` and `  FAIL: <what>` per check, `TEST <name>: PASS|FAIL`. A test that makes no check reports FAIL. `tests/host/qemu_tests/run.sh` tests the runner against a stand-in for QEMU.
