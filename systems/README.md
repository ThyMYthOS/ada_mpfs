# `systems/`

- **Purpose:** System descriptions (`system.yaml`) and the reference systems `amp_a`..`amp_d`, one directory each.
  The format is in [`config/README.md`](../config/README.md#system-description); `python3 config/gen/mpfs_gen check
  systems/*/system.yaml` validates them, `python3 config/gen/mpfs_gen derive --check systems/*/system.yaml` derives
  them with the XML of their board. `amp_c` is a prod system with an XML of its own
  ([`config/boards/icicle_amp_c`](../config/boards/icicle_amp_c/README.md)). Their window sizes are example data,
  not measurements.
- **License:** Apache-2.0
