# `tests/renode/`

- **Purpose:** Renode smoke test of the bare images (`./x test renode`).
- **License:** Apache-2.0

| File | Content |
|---|---|
| `smoke.sh` | Runs every image of `smoke.expected` for a fixed span of virtual time and asserts what it printed on MMUART0. A missing Renode or image, an empty console and any error reported by Renode are failures. |
| `smoke.expected` | The expectations, `image<TAB>string`; Renode models 16 PMP entries, QEMU 8. |
| `bare.resc` | The Renode script: board model, UART file, `LoadELF`, `emulation RunFor`. |

The pinned release (`RENODE_VERSION`, checksum `RENODE_SHA256_X86_64_LINUX` in `tools/toolchain.env`) is installed with `./x toolchain install renode`.
