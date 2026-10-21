# `tests/common/`

- **Purpose:** Code shared by the test applications that run on the target.
- **License:** Apache-2.0

| File | Content |
|---|---|
| `test_report.ads`, `test_report.adb` | `Test_Report`: the console protocol of every test application (`TEST <name>: START`, `ok:`/`FAIL:` lines, `TEST <name>: PASS|FAIL`), over `Bare_Console` (MMUART0, no runtime). Used by `examples/report_test`; read by `tests/qemu/run_tests.sh`. |
