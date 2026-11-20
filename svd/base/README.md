# `svd/base/`

- **Purpose:** Base SVD: the device head `device.svd` and one svdtools fragment `<family>.yaml` per peripheral family (all MMUART instances in `mmuart.yaml`). Imported once from the two directories of the Microchip register map, `MSS` and `MPFS`, with `tools/regmap2svd.py` (the MPFS fragments are the system controller side: `pfsoc_control_scb`, `scb_mailbox`, `qspixip_scb`, `scb_regs_scb`, `pf_us_crypto_top`, the `ioscb_*` blocks, and the SerDes and PCIe blocks `pcscmn`, `pcslane`, `pma_cmn`, `pma_lane`, `gpss_main`, `extpll`, `pciess_main`, `pcie_ctrl` and `pf_pcie_bridge`, all at the IOSCB bus base `0x30000000`); maintained by hand from here on (the register map has many typos and is no longer updated).
- **License:** CC-BY-4.0

Instances of one family (for example MMUART0_LO and its other instances) are the first instance with its registers plus `derivedFrom` instances (name, description, base address only). The first instance carries `groupName: <FAMILY>`, which lets svd2ada share one register type across the family; peripherals without a `groupName` get their own package. The importer writes the `groupName` for every page that lists several instances.
