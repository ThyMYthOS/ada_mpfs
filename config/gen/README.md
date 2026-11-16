# `config/gen/`

- **Purpose:** Generator (tool with TSF influence, ALC_TAT).
- **License:** Apache-2.0

| File | Content |
|---|---|
| `mpfs_gen/` | The configuration generator, so far the reader of `system.yaml`: `target.py` (the facts of the chip and the defaults of the runtime, shared with `standalone.py`), `model.py` (the immutable model), `checks.py` (the error codes `GEN-Exxx` and the rules across fields), `yaml_reader.py` (YAML, schema, defaults, normalisation), `presets.py` (the standalone presets of the 30 runtime variants), `__main__.py` (`python3 config/gen/mpfs_gen check FILE...`). Uses `tools/gen_ada`. The format is in `config/README.md`, the tests in `tests/host/system_yaml`. |
| `schema/system.schema.json` | The JSON schema of `system.yaml`, version 1. |
| `standalone.py` | The partition data of an image that is built without a system description: the package `MPFS_Partition` with its checks and the list of link symbols, from the parameters of `./x build`. Uses `tools/gen_ada` and `mpfs_gen/target.py`. The format and the checks are in `config/README.md`, the tests in `tests/host/standalone`. |
