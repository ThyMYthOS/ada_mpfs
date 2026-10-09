# `svd/base/`

- **Purpose:** Base SVD: the device head `device.svd` and one svdtools fragment `<family>.yaml` per peripheral family (all MMUART instances in `mmuart.yaml`). Imported once from the Microchip register map with `tools/regmap2svd.py`; maintained by hand from here on (the register map has many typos and is no longer updated).
- **License:** CC-BY-4.0

Instances of one family (for example MMUART0_LO and its other instances) are the first instance with its registers plus `derivedFrom` instances (name, description, base address only). The first instance carries `groupName: <FAMILY>`, which lets svd2ada share one register type across the family; peripherals without a `groupName` get their own package. The importer writes the `groupName` for every page that lists several instances.
