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
gets. They hold only the locked barrier, entries that bind U and M mode alike; the generator adds the unlocked
allow list of each hart behind them (`config/README.md`). The tables are the keys `PMP<i>CFG_<T>` and
`CSRPMP_ADDR<i>_<T>` of the `.cfg` with `<T>` `E51`, `CTXA`, `CTXB`: every entry in use is a locked NAPOT entry,
the configuration byte `0x98` (no rights) or `0x9B` (`rw-`), and `pmpaddr` is `(base + size / 2 - 1) >> 2`.
The windows are those of `amp_c` as `derive` places them: `monitor` `0x0800_0000`, `control` `0x0804_0000`,
`app_a` `0x0808_0000`, `app_b` `0x080C_0000` (256 KiB each), `io` `0x0810_0000` (128 KiB), the shared block of
channels largest first, `app_a_app_b` `0x0812_0000` (32 KiB), `monitor_app_a` `0x0812_8000` and `monitor_app_b`
`0x0812_C000` (16 KiB), `monitor_io` `0x0813_0000` and `monitor_control` `0x0813_2000` (8 KiB), and the
`fast_text` of `control` in the ITIM of hart 2.

The E51 (`pmp_h0`, partition `monitor`) has no entry: the monitor supervises the system (the bus error units and
the watchdogs of the other harts), so its M mode is not locked out of anything; its U mode is held to its own
ranges by the allow list alone.

Context A (`pmp_h1`, `pmp_h2`, partitions `io` and `control`), 9 entries:

| Entry | Range | Rights | Locks out |
|---|---|---|---|
| 0 | NAPOT `0x0800_0000`, 256 KiB | `---` | the window of `monitor` |
| 1 | NAPOT `0x0808_0000`, 512 KiB | `---` | the windows of `app_a` and `app_b` |
| 2 | NAPOT `0x0812_0000`, 64 KiB | `---` | the channels `app_a_app_b`, `monitor_app_a` and `monitor_app_b` |
| 3 | NAPOT `0x2000_0000`, 32 KiB | `---` | MMUART0, WDOG0, SYSREG, SCB, the AXI switch, MPUCFG, `CFG_DDR_SGMII_PHY` |
| 4 | NAPOT `0x0201_0000`, 4 KiB | `---` | the L2 cache controller |
| 5 | NAPOT `0x2800_0000`, 128 MiB | `---` | the HI bus window (context B) |
| 6 | NAPOT `0x2010_4000`, 16 KiB | `---` | MMUART3, 4 and WDOG3, 4 on the LO bus |
| 7 | NAPOT `0x0100_0000`, 8 KiB | `---` | the DTIM of the E51 |
| 8 | NAPOT `0x0170_0000`, 32 KiB | `---` | the bus error units |

Context B (`pmp_h3`, `pmp_h4`, partitions `app_a` and `app_b`), 10 entries:

| Entry | Range | Rights | Locks out |
|---|---|---|---|
| 0 | NAPOT `0x0800_0000`, 512 KiB | `---` | the windows of `monitor` and `control` |
| 1 | NAPOT `0x0810_0000`, 128 KiB | `---` | the window of `io` |
| 2 | NAPOT `0x0813_0000`, 16 KiB | `---` | the channels `monitor_io` and `monitor_control` |
| 3 | NAPOT `0x2010_5000`, 4 KiB | `rw-` | grants WDOG3 (LO bus) to both harts |
| 4 | NAPOT `0x2010_7000`, 4 KiB | `rw-` | grants WDOG4 (LO bus) to both harts |
| 5 | NAPOT `0x2000_0000`, 2 MiB | `---` | the LO bus window: context A, MMUART0, WDOG0 to 2, SYSREG, SCB, the AXI switch, MPUCFG, `CFG_DDR_SGMII_PHY` |
| 6 | NAPOT `0x0201_0000`, 4 KiB | `---` | the L2 cache controller |
| 7 | NAPOT `0x0181_0000`, 32 KiB | `---` | the ITIM of hart 2 (`fast_text` of `control`) |
| 8 | NAPOT `0x0100_0000`, 8 KiB | `---` | the DTIM of the E51 |
| 9 | NAPOT `0x0170_0000`, 32 KiB | `---` | the bus error units |

WDOG3 and WDOG4 have no context key and stay on the LO bus, which entry 5 locks out; entries 3 and 4 before it
let them through, for U and M mode of both harts of the context.

## What is not locked

Deliberately, for the budget of 16 entries:

- the E51: nothing (the monitor, above);
- contexts A and B: the unused LIM above `0x0813_4000`, the ITIMs that no partition uses (an unused ITIM is not
  foreign to the checks), the PDMA, the eNVM controller, the system controller, the IOSCB, and PLIC and CLINT.

## Remaining warnings

`derive --check systems/amp_c/system.yaml` passes with these warnings:

- `GEN-E128`: within a context the tables cannot separate the partitions in M mode: `io` and `control` reach
  each other's windows, channels (`monitor_io`, `monitor_control`) and peripherals, `io` also the `fast_text` of
  `control` in the ITIM of hart 2; `app_a` and `app_b` the same.
- `GEN-E136`: the locked entries 3 and 4 of context B grant WDOG4 to U mode of `app_a` and WDOG3 to U mode of
  `app_b` (the same weakness: one table for the context).
- `GEN-E127`: M mode of harts 1 to 4 reaches the PDMA, the eNVM controller, the system controller and the
  IOSCB, which the tables leave open.

## Budget per hart

Locked entries of the XML plus the unlocked allow list the generator adds (`derive`), at most 16. The generator
leaves out what a locked entry already grants (WDOG3 and WDOG4 in context B).

| Hart | Partition | Locked | Unlocked | Allow list |
|---|---|---|---|---|
| 0 | `monitor` | 0 | 5 | the page of `mtime`, its window, `monitor_app_a` with `monitor_app_b` (32 KiB), `monitor_io` with `monitor_control` (16 KiB), MMUART0 and WDOG0 |
| 1 | `io` | 9 | 4 | the page of `mtime`, its window, `monitor_io`, MMUART1 and WDOG1 |
| 2 | `control` | 9 | 6 | `fast_text` (16 KiB and 8 KiB), the page of `mtime`, its window, `monitor_control`, MMUART2 and WDOG2 |
| 3 | `app_a` | 10 | 5 | the page of `mtime`, its window, `app_a_app_b` and `monitor_app_a` (32 KiB and 16 KiB), MMUART3 (HI) |
| 4 | `app_b` | 10 | 4 | the page of `mtime`, its window, `app_a_app_b`, `monitor_app_b` |
