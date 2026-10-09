# `svd/`

- **Purpose:** PolarFire SoC SVD. `base/`, `patches/` and `additions/` are merged into `PolarfireSoC.svd` by `./x svd merge` (stage order is fixed, see `device.yaml`). The merged SVD is not committed: `./x svd merge` writes it to `build/svd/PolarfireSoC.svd` and records its SHA-256 in `PolarfireSoC.sha256`; `./x svd check` rebuilds it and fails on a rule violation or a different hash.
- **License:** CC-BY-4.0

| Path | Content |
|---|---|
| `base/` | One svdtools fragment (`<family>.yaml`) per peripheral family, adding the peripheral and its instances, plus the device head `device.svd`. Imported once from the Microchip register map and maintained by hand from there on. |
| `patches/` | svdtools patches, one file per peripheral. |
| `additions/` | Blocks without register documentation: `plic.yaml`, `clint.yaml`, `interrupts.yaml`; `local_interrupts.yaml` (own schema, not merged into the SVD). |
| `device.yaml` | Root of the svdtools run: the assembled base plus the ordered includes. |
| `schema/` | CMSIS-SVD XSD used for validation. |
| `PolarfireSoC.sha256` | Hash of the merged SVD, which is the input of the register package generator. |

Every file in `patches/` and `additions/` starts with a header (checked by `./x svd check`):

```yaml
# source: <where the information comes from>   (one or more lines)
# status: unverified                           (or verified-<silicon>-<yyyy-mm-dd>)
# owner: <name>
```
