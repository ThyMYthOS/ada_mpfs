# `examples/common/`

- **Purpose:** Sources shared by the examples.
- **License:** Apache-2.0

| Path | Content |
|---|---|
| `bare_build.sh` | Build of an image that binds and links nothing of the runtime (sourced by the `build.sh` of an example). |
| `ld/mpfs-memory.ld` | The MEMORY block of the SoC: literal ORIGINs, LENGTHs by `--defsym`. |
| `ld/place-lim.ld` | Placement of an image in the L2 LIM. |
