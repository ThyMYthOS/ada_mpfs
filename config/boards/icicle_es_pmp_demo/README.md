# `config/boards/icicle_es_pmp_demo/`

- **Purpose:** Microchip's PMP demo for the Icicle Kit with engineering sample silicon (MPFS250T_ES): an MSS
  configuration that uses the AMP contexts A and B and per-context PMP tables, as input of the checks of the
  PMP and the contexts.
- **Status:** the MSS Configurator XML of the demo only; the reference XML of format 0.5.3.
- **License:** Apache-2.0; `ICICLE_MSS_mss_cfg.xml` states no license. The project treats it as configuration
  data without creative expression (decision of the project owner; `LicenseRef-Microchip-MSS-config-data`,
  origin and commit in `PROVENANCE.md`).

| File | Content |
|---|---|
| `ICICLE_MSS_mss_cfg.xml` | the MSS Configurator XML of `applications/mpfs-pmp-demo` of Microchip's bare-metal examples (Libero 2021.1, format 0.5.3), unchanged, CRLF line ends as upstream; read by `config/gen/mpfs_gen xml` |

What it sets (`python3 config/gen/mpfs_gen pmp`, `derive` with `tests/host/derive/fixtures/pmp_demo`):

- `MEM_CONFIGS_ENABLED` `0x3` (PMP and MPU tables enabled).
- Context A: harts 1 and 2, `CONTEXT_A_EN` `0x4F69_5406`; context B: harts 3 and 4, `CONTEXT_B_EN` `0x12_A818`,
  which is also `APBBUS_CR` (MMUART3 and 4, SPI1, I2C1, CAN1, GEM1 and GPIO1 on the HI bus).
- No PMP entry on the E51. On each U54 every entry in use is locked NAPOT, from entry 4 on (entries 0 to 3 are
  left free), and the last is a deny-all over the whole space:
  - harts 1 and 2, entries 4 to 14: the LO peripheral block `[0x2010_0000, 0x2013_FFFF]`, the PLIC
    (4 MiB), SYSREG, the eMMC configuration, USB, QSPI (16 MiB), `0x2200_0000` (128 KiB), the L2 controller and
    the CLINT RW, DDR `[0x8000_0000, 2 MiB]` RWX;
  - harts 3 and 4, entries 4 to 10: the HI peripheral block `[0x2810_0000, 0x2813_FFFF]`, the PLIC, SYSREG, the
    L2 controller and the CLINT RW, DDR `[0x8020_0000, 2 MiB]` RWX.

Against a system with one partition per context the contexts pass, and the PMP is refused for a prod image: the
locked entries grant SYSREG and the L2 controller to U and M mode (`GEN-E126`, `GEN-E125`, `GEN-E127`) and do not
cover the partitions' windows in the LIM (`GEN-E120`; the demo runs from DDR). The generated allow list comes
after the locked deny-all, which hides it, and on harts 1 and 2 it does not fit the one entry left (`GEN-E129`).
11 entries do not fit the 8 of QEMU (`GEN-E103` with `--pmp-entries 8`).

Format 0.5.3 has no `GPIO_INTERRUPT_FAB_CR`, `ALT_GPIO_INTERRUPT_FAB_CR` and `CONFIGURED_PERIPHERALS` (nor
`DDR_CLK`, `MSS_CLKS_VERSION`, `SYSREG_CLKS_VERSION`); the derivations take the defaults of Microchip's HAL for
the first three. Every other register agrees with Microchip's generator (`tools/mchp_diff`: 342 of 342 compared
defines).
