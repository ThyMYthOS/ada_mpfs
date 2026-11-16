<!--
SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
SPDX-License-Identifier: CC-BY-4.0
-->
# Results of the SVD probe on the Icicle Kit

What `./x svd probe` reported for the blocks that have no clock or are held in reset, and how the probe tells them. The tool and its
rules are described in [`hw/README.md`](../../../hw/README.md) ("Gated blocks and the default"); the rules are in `hw/svd_probe.list`.

## Run of 2026-11-16

| | |
|---|---|
| Board | Icicle Kit, `MPFS250T_ES`, one board |
| Boot mode | 0 (the PC of the E51 after `./x hw reset` was `0x20003120`, the boot stub); the board had been in boot mode 1 before |
| Probe | the commit that makes the probe report `gated` (clock rules for SUBBLK_CLOCK_CR and SOFT_RESET_CR), then the same with the rule for `DFIAPB_CR` |
| Merged SVD | `build/svd/PolarfireSoC.svd` of the checkout, not re-merged for this run (`svdtools` is not installed on the host that ran it) |
| Lab | OpenOCD on another machine, telnet port 4444 |

### Whole-device runs

`./x hw reset` ran before each run. The counts are the last line of the probe.

| Run | Registers | Not ok | gated | ok | state | noref | readAction | DLAB | Excluded |
|---|---|---|---|---|---|---|---|---|---|
| power-on, `SUBBLK_CLOCK_CR` and `SOFT_RESET_CR` rules | 3152 | 65 | 1778 | 828 | 18 | 274 | 179 | 10 | 2692 |
| `--enable-clocks` | 2860 | 0 | 0 | 2466 | 29 | 303 | 52 | 10 | 2984 |
| power-on, with the `DFIAPB_CR` rule, after the run above and `./x hw reset` (not clean, see below) | 3152 | 2 | 2171 | 507 | 17 | 266 | 179 | 10 | 2692 |
| power-on, with the `DFIAPB_CR` rule, board power-cycled before | 3152 | 12 | 2171 | 497 | 17 | 266 | 179 | 10 | 2692 |

The runs took 3 min 26 s, 3 min 28 s and (the clean run) 3 min 16 s. The 65 not ok registers of the first run are 53 of `CFG_DDR_SGMII_PHY` and 12 of `FRQMETER`.
The blocks that were gated in the first run: `GEM_A_LO` and `GEM_B_LO` (461 registers each), `CAN_A_LO` and `CAN_B_LO` (328 each), `USB` (64),
`GPIO_IOBANK0_LO`, `GPIO_IOBANK1_LO` and `GPIO_FAB_LO` (42 each) and `QSPIXIP` (10). With `--enable-clocks` the CAN blocks are not read
(skip rule: the first access stalled the debug module once) and no register is gated or not ok.

### What gates `CFG_DDR_SGMII_PHY`

The 53 mismatches of the block at power-on all read `0x00000000`. `SYSREG.DFIAPB_CR` (power-on value `0x2`: `RESET` set, `CLOCKON`
clear) gates the MSS corner that holds the block. Measured on the block alone:

| `./x svd probe CFG_DDR_SGMII_PHY` | Registers | Not ok | state |
|---|---|---|---|
| power-on | 393 | 53 | 1 |
| `--poke SYSREG.DFIAPB_CR=0x1` | 393 | 0 | 2 |

The probe therefore has a rule `clock CFG_DDR_SGMII_PHY DFIAPB_CR:CLOCKON:RESET`. With it, the whole-device runs report all 393
registers of the block as gated, with the reason `clock off: DFIAPB_CR.CLOCKON=0 and in reset: DFIAPB_CR.RESET=1`.

### The clean power-on run

The board was power-cycled, `./x hw reset` ran, and no `--enable-clocks` run had been made before. The 12 registers that are not ok
are all `FRQMETER` (the 53 of `CFG_DDR_SGMII_PHY` are gated now): every register reads `0x00AC1402`, and the probe prints its note about
identical reads. The first run read `0x00A81402` in the same registers. The value is the same in every register of one run, differs
between the runs and is not the reset value of any of them; what it is, is not known. 497 registers are ok, 2171 gated (the same
blocks and counts as in the run before, `CFG_DDR_SGMII_PHY` 393 more than in the first run).

### The blocks of the small run

`./x svd probe GPIO_IOBANK0_LO FRQMETER GEM_A_LO` (before the `DFIAPB_CR` rule): 515 registers, 503 gated (`GEM_A_LO` 461,
`GPIO_IOBANK0_LO` 42), 12 not ok, all of them `FRQMETER`, which read `0x00A81402` in every register (the probe prints its note about
identical reads; the block has no field in `SUBBLK_CLOCK_CR` that the rules know).

### `./x hw reset` does not restore everything

The third whole-device run followed the `--enable-clocks` run and a `./x hw reset`, not a power cycle. It differs from the first
run in the registers that are not gated:

- `FRQMETER` read `0` in its registers (one mismatch, `RUNTIME` = 0 against the reset value `0x2710`) where the first run and the clean run
  read `0x00A81402` and `0x00AC1402` in every register;
- `SCB_REGS.MSSIO_CONTROL_CR` read `0x00000780` where `0x00000720` is expected: `--enable-clocks` writes `0x3800` to it as part of the
  reference clock set-up, and the reset does not undo that.

So the third run is not a clean power-on run, and the two registers show that a state written by `--enable-clocks` survives
`./x hw reset` (the check of `./x hw reset` covers `SUBBLK_CLOCK_CR` and `SOFT_RESET_CR`).

## Not done

- The gates of `CAN_A_LO` and `CAN_B_LO` are confirmed only as far as the clock bits read 0 at power-on: with `--enable-clocks` the
  blocks are not read. The gate of `FRQMETER` is not known.
- `FRQMETER`: it reads one word in every register at power-on (and with `--enable-clocks` it reads like a block that works); no field of
  `SUBBLK_CLOCK_CR` is known for it, so the probe cannot call it gated.
- One board, boot mode 0, one run of each kind.
