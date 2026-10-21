# `tests/prove/`

- **Purpose:** SPARK projects for `./x prove`.
- **License:** Apache-2.0

| Directory | Content |
|---|---|
| `sample/` | `Sample_Math`, proved free of run-time errors with contracts that state the result. Listed in `tools/prove.list`. |
| `fixtures/unprovable/` | A project with an overflow that cannot be proved. Not in `tools/prove.list`: `tests/host/prove/run.sh` runs `tools/prove.sh` on it and requires a failure. |
