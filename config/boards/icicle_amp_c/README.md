# `config/boards/icicle_amp_c/`

- **Purpose:** the MSS configuration of the reference system `systems/amp_c` on the Icicle Kit: the project
  owner's own Icicle design (MPFS250T_ES) with the L2 split, the AMP contexts and the locked PMP tables of
  `amp_c`, the input of its prod derivation.
- **Status:** the reference XML of format 0.6.8 and the `.cfg` it was exported from; read by
  `config/gen/mpfs_gen` (`derive systems/amp_c/system.yaml`).
- **License:** Apache-2.0 (project-owned; the XML and the `.cfg` carry no header, `REUSE.toml` annotates them).

| File | Content |
|---|---|
| `amp_c.cfg` | the MSS Configurator configuration (pfsoc_mss, Libero 2026.1) with the settings below |
| `amp_c_mss_cfg.xml` | the XML that pfsoc_mss exported from `amp_c.cfg`, unchanged |

What it sets (`python3 config/gen/mpfs_gen pmp config/boards/icicle_amp_c/amp_c_mss_cfg.xml`):

- L2: 1 way of cache, 15 of LIM, no scratchpad (`L2CACHE_LIM_SIZE 15`, `L2CACHE_SCRATCH_SIZE 0`).
- `MEM_CONFIGS_ENABLED` PMP (`MSS_PMP_ENABLE true`), the PMP tables in Expert Mode
  (`PMP_API_EXPERT_MODE_ENABLED`, `PMP_E51_EXPERT_MODE_ENABLED`).
- Context A: harts 1 and 2 (`io`, `control`), MMUART1 and 2; context B: harts 3 and 4 (`app_a`, `app_b`),
  MMUART3 and 4 (`PMP_INITIATOR_U54_<n>_CONTEXT_<A|B>_EN`, `PMP_MMUART<n>_CONTEXT_<A|B>_EN`); every other
  peripheral key in neither context. `APBBUS_CR` is `0x18`: MMUART3 and 4 on the HI bus. WDOG3 and 4 have no
  context key and stay on the LO bus.

## The locked tables

The Configurator writes three PMP tables: the E51's and one per context, which every hart of the context
gets. They hold only the locked barrier, entries without rights (`---`) that bind U and M mode; the unlocked
allow list of each hart, which separates the partitions of a context in U mode, comes behind them. The tables are the keys
`PMP<i>CFG_<T>` and `CSRPMP_ADDR<i>_<T>` of the `.cfg` with `<T>` `E51`, `CTXA`, `CTXB`: the configuration
byte `0x98` (locked NAPOT) or `0x88` (locked TOR) with `0x80` for the base of a TOR entry (locked OFF), and
`pmpaddr` the address shifted right by 2 (NAPOT: `(base + size / 2 - 1) >> 2`). The windows are those of
`amp_c` as `derive` places them: `monitor` `0x0800_0000`, `control` `0x0804_0000`, `app_a` `0x0808_0000`,
`app_b` `0x080C_0000` (256 KiB each), `io` `0x0810_0000` (128 KiB), the channels `monitor_io` `0x0812_0000`,
`monitor_control` `0x0812_2000`, `monitor_app_a` `0x0812_4000`, `monitor_app_b` `0x0812_8000` and
`app_a_app_b` `0x0812_C000`, and the `fast_text` of `control` in the ITIM of hart 2.

E51 (`pmp_h0`, partition `monitor`), 11 entries:

| Entries | Range | Locks out |
|---|---|---|
| 0, 1 | TOR `[0x0804_0000, 0x0812_0000)` | the windows of `control`, `app_a`, `app_b`, `io` |
| 2, 3 | TOR `[0x0812_C000, 0x0820_0000)` | the channel `app_a_app_b` and the rest of the LIM |
| 4 | NAPOT `0x2000_2000`, 8 KiB | SYSREG, SCB |
| 5 | NAPOT `0x2000_4000`, 8 KiB | the AXI switch, MPUCFG |
| 6 | NAPOT `0x0201_0000`, 4 KiB | the L2 cache controller |
| 7 | NAPOT `0x2800_0000`, 128 MiB | the HI bus window |
| 8 | NAPOT `0x2010_0000`, 32 KiB | MMUART1 to 4 and WDOG1 to 4 on the LO bus |
| 9, 10 | TOR `[0x0180_8000, 0x0182_8000)` | the ITIMs of the U54 harts |

Context A (`pmp_h1`, `pmp_h2`, partitions `io` and `control`), 10 entries:

| Entries | Range | Locks out |
|---|---|---|
| 0 | NAPOT `0x0800_0000`, 256 KiB | the window of `monitor` |
| 1 | NAPOT `0x0808_0000`, 512 KiB | the windows of `app_a` and `app_b` |
| 2, 3 | TOR `[0x0812_4000, 0x0820_0000)` | the channels of `app_a` and `app_b` and the rest of the LIM |
| 4 | NAPOT `0x2000_0000`, 16 KiB | MMUART0, WDOG0, SYSREG, SCB |
| 5 | NAPOT `0x2000_4000`, 8 KiB | the AXI switch, MPUCFG |
| 6 | NAPOT `0x0201_0000`, 4 KiB | the L2 cache controller |
| 7 | NAPOT `0x2800_0000`, 128 MiB | the HI bus window (context B) |
| 8 | NAPOT `0x2010_4000`, 16 KiB | MMUART3, 4 and WDOG3, 4 on the LO bus |
| 9 | NAPOT `0x0100_0000`, 8 KiB | the DTIM of the E51 |

Context B (`pmp_h3`, `pmp_h4`, partitions `app_a` and `app_b`), 9 entries:

| Entries | Range | Locks out |
|---|---|---|
| 0 | NAPOT `0x0800_0000`, 512 KiB | the windows of `monitor` and `control` |
| 1, 2 | TOR `[0x0810_0000, 0x0812_4000)` | the window of `io`, the channels `monitor_io` and `monitor_control` |
| 3 | NAPOT `0x2000_0000`, 1 MiB | the LO range up to `0x2010_0000`: MMUART0, WDOG0, SYSREG, SCB, the AXI switch, MPUCFG, `CFG_DDR_SGMII_PHY` |
| 4 | NAPOT `0x2010_0000`, 16 KiB | MMUART1, 2 and WDOG1, 2 on the LO bus |
| 5 | NAPOT `0x0201_0000`, 4 KiB | the L2 cache controller |
| 6 | NAPOT `0x0180_0000`, 64 KiB | the ITIMs of the E51 and of hart 1 |
| 7 | NAPOT `0x0181_0000`, 32 KiB | the ITIM of hart 2 (`fast_text` of `control`) |
| 8 | NAPOT `0x0100_0000`, 8 KiB | the DTIM of the E51 |

## What is not locked

Deliberately, for the budget of 16 entries:

- context A: the ITIMs of harts 0, 3 and 4, which `amp_c` does not use (an unused ITIM is not foreign to the
  checks);
- context B: the unused LIM above `0x0813_4000`;
- all three: PLIC and CLINT, the PDMA, the IOSCB, the system controller and the eNVM controller.

## Budget per hart

Locked entries of the XML plus the unlocked allow list that the kernel of the hart sets, at most 16:

| Hart | Partition | Locked | Unlocked | Allow list |
|---|---|---|---|---|
| 0 | `monitor` | 11 | 5 | the page of `mtime`, its window, its channels (32 KiB and 16 KiB), MMUART0 and WDOG0 |
| 1 | `io` | 10 | 4 | the page of `mtime`, its window, `monitor_io`, MMUART1 and WDOG1 |
| 2 | `control` | 10 | 6 | `fast_text` (16 KiB and 8 KiB), the page of `mtime`, its window, `monitor_control`, MMUART2 and WDOG2 |
| 3 | `app_a` | 9 | 7 | the page of `mtime`, its window, `monitor_app_a`, `app_a_app_b` (16 KiB twice), WDOG3 (LO), MMUART3 (HI) |
| 4 | `app_b` | 9 | 5 | the page of `mtime`, its window, `monitor_app_b` with `app_a_app_b` (32 KiB and 16 KiB), WDOG4 (LO) |
