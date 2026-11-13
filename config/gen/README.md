# `config/gen/`

- **Purpose:** Generator (tool with TSF influence, ALC_TAT).
- **License:** Apache-2.0

| File | Content |
|---|---|
| `standalone.py` | The partition data of an image that is built without a system description: the package `MPFS_Partition` with its checks and the list of link symbols, from the parameters of `./x build`. Uses `tools/gen_ada`. The format and the checks are in `config/README.md`, the tests in `tests/host/standalone`. |
