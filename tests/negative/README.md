# `tests/negative/`

- **Purpose:** Negative cases: builds and links that must fail (`run_negative.sh`, `cases.list`, `fixtures/`).
- **License:** Apache-2.0

| File | Content |
|---|---|
| `run_negative.sh` | `./x test negative`: runs the cases of `cases.list`. A case that must fail passes only if the link or the build fails with the message the case names (a failure for another reason does not count), and a failed link leaves no image. Control cases (the same objects and sources without the fault) must succeed, so a negative cannot pass because the setup is broken. An empty list, a list without a control or without a negative case of a kind, a missing fixture, a missing tool or object are failures. |
| `cases.list` | `name, kind, arg, expect, pattern`. Kind `link`: objects of `examples/bare_hello` for two hart classes (`e51:u54`) are linked; the two ABIs must not mix. Kind `build`: `examples/bare_hello` is compiled with gprbuild in a fresh copy of the tree, with the scenario variables of the case (`MPFS_HART=r5`, passed as `-X`) and, if the case names one, a fixture. |
| `fixtures/<name>/` | Files that replace those of `src/` in a build case: `unreferenced_constant` (a warning, which is an error under `-gnatwa -gnatwe`), `elaboration_code` (a unit that needs elaboration code in an image without a binder). |

`tests/host/negative/run.sh` tests the runner against stand-ins for the compiler driver and gprbuild.
