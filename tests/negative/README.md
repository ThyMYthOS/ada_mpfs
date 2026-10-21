# `tests/negative/`

- **Purpose:** Negative builds (`run_negative.sh`, `cases.list`).
- **Owning phase:** P0.8
- **License:** Apache-2.0

| File | Content |
|---|---|
| `run_negative.sh` | `./x test negative`: links the objects of `examples/bare_hello` for two hart classes and checks the outcome of each case of `cases.list`. A case that must fail passes only if the link fails with the named message and leaves no image. |
| `cases.list` | Two control cases (same ABI, must link) and the two directions of the ABI mismatch (lp64 with lp64d objects, must fail). |
