# `tests/qemu/`

- **Purpose:** QEMU tests (`run_tests.sh`, `tests.list`).
- **Owning phase:** P0.8
- **License:** Apache-2.0

| File | Content |
|---|---|
| `smoke.sh` | `./x test qemu`: boots every image named in `smoke.expected` under QEMU and asserts what it printed on MMUART0. QEMU that is missing, too old (`QEMU_MIN` in `tools/toolchain.env`) or without the machine, a missing image and an empty console are failures, never skips. |
| `smoke.expected` | The expectations, `image<TAB>string`, edited by hand. |
| `qemu_preflight.sh` | The QEMU preconditions, sourced by `smoke.sh`. |
