# `tests/`

- **Purpose:** Tests by level.
- **License:** Apache-2.0

| Directory | Content |
|---|---|
| `common/` | `Test_Report`, shared by the test applications. |
| `host/` | Host tests, one suite per directory (`<suite>/run.sh`). |
| `hw/` | Hardware tests on the Icicle Kit. |
| `negative/` | Builds and links that must fail. |
| `prove/` | SPARK projects proved by `./x prove`, and the project its tests must see fail. |
| `qemu/` | QEMU smoke test and test applications. |
| `renode/` | Renode smoke test. |
