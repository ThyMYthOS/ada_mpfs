# `tests/host/`

- **Purpose:** Host tests (`<suite>/run.sh`; non-zero exit code on FAIL), run by `./x test host`.
- **License:** Apache-2.0

| Suite | Content |
|---|---|
| `x/` | The verbs and option validation of `./x`. |
| `svd/` | SVD merge, check rules, probe. |
| `pac/` | Register package generator on fixtures, and properties of the committed `libs/mpfs_pac/src/generated`. |
| `bare/` | The QEMU smoke test (with a stand-in for QEMU), `tools/metrics.sh` (with stand-ins for size and readelf) and the committed `metrics.golden`, each with negative cases. |
| `report/` | The shared `Host_Report` package (`common/`): a program whose checks hold exits 0; a failed check, no check, a missing `Finish` and an unhandled exception each exit non-zero. |

## `Host_Report`

Native Ada host tests use `common/host_report.ads` (`with` its directory in `Source_Dirs`). It prints the lines of the target tests (`TEST <name>: START`, `ok:`, `FAIL:`, `TEST <name>: PASS|FAIL`) and fails closed: `Start` sets the exit status to failure, and only a `Finish` after at least one check, none of which failed, sets it to success. Shell suites report with their own `pass`/`fail` functions and exit non-zero when a case failed.
