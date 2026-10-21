# `tests/host/`

- **Purpose:** Host tests (`<suite>/run.sh`; non-zero exit code on FAIL), run by `./x test host`.
- **License:** Apache-2.0

| Suite | Content |
|---|---|
| `x/` | The verbs and option validation of `./x`. |
| `svd/` | SVD merge, check rules, probe. |
| `pac/` | Register package generator on fixtures, and properties of the committed `libs/mpfs_pac/src/generated`. |
| `bare/` | The QEMU smoke test (with a stand-in for QEMU), `tools/metrics.sh` (with stand-ins for size and readelf) and the committed `metrics.golden`, each with negative cases. |
| `negative/` | `tests/negative/run_negative.sh` against stand-ins for the compiler driver and gprbuild: ABI mismatch accepted, a failure for another reason, a leftover image, a missing fixture or object, a fixture that lost its fault, malformed lists. |
| `analyze/` | `tools/analyze.sh` with a stand-in for adalang_analyzer: no analyzer, another version, no baseline, a silent analyzer, a new finding, the two rule sets and their baselines, `--update-baseline` (also with an analyzer that writes nothing), empty and malformed lists. |
| `prove/` | `tools/prove.sh`: with a stand-in for gnatprove (another version, unproved checks, no summary, a failing exit status, a medium message, a missing project, a bad list); with the pinned gnatprove, the committed projects prove and a project with an unprovable overflow fails. The cases with the real gnatprove are reported as skipped when it is not installed. |
| `stack/` | `tools/stack_report` on `.su`/`.ci` fixtures with known frames, a recursion, a dynamic frame and a call into code without a frame (the summed chain is checked; a missing directory, no `.su` files and no argument fail), and `./x stack` on a copy of the tree: the real compiler on an example, and an example that ignores `STACK_ANALYSIS`, which must fail. |
| `qemu_tests/` | `tests/qemu/run_tests.sh` against a stand-in for QEMU: every way a test can pass or fail (verdict, FAIL line, hang, stray port output, `console.expected`, xfail signature, malformed list, old QEMU). |
| `report/` | The shared `Host_Report` package (`common/`): a program whose checks hold exits 0; a failed check, no check, a missing `Finish` and an unhandled exception each exit non-zero. |

## `Host_Report`

Native Ada host tests use `common/host_report.ads` (`with` its directory in `Source_Dirs`). It prints the lines of the target tests (`TEST <name>: START`, `ok:`, `FAIL:`, `TEST <name>: PASS|FAIL`) and fails closed: `Start` sets the exit status to failure, and only a `Finish` after at least one check, none of which failed, sets it to success. Shell suites report with their own `pass`/`fail` functions and exit non-zero when a case failed.
