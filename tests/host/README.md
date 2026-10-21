# `tests/host/`

- **Purpose:** Host tests (`<suite>/run.sh`; non-zero exit code on FAIL), run by `./x test host`.
- **License:** Apache-2.0

| Suite | Content |
|---|---|
| `x/` | The verbs and option validation of `./x`. |
| `svd/` | SVD merge, check rules, probe. |
| `pac/` | Register package generator on fixtures, and properties of the committed `libs/mpfs_pac/src/generated`. |
| `bare/` | The QEMU smoke test (with a stand-in for QEMU), `tools/metrics.sh` (with stand-ins for size and readelf) and the committed `metrics.golden`, each with negative cases. |
