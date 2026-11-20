<!--
SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
SPDX-License-Identifier: CC-BY-4.0
-->
# PMP on the Icicle Kit

How many `pmpaddr` registers the E51 and a U54 implement, and what the test programs of the PMP
([`pmp-tests.md`](../../assurance/pmp-tests.md)) do on the board.

## Run of 2026-11-20

| | |
|---|---|
| Board | Icicle Kit, die `MPFS250T_ES` (the MSS Configurator XML of `config/boards/icicle_es` was used for `initialize`); embedded FlashPro6, serial number `B347B62F`; boot mode 0 (not read back, not changed) |
| Commit | the earlier tip of the branch of the PMP test programs (`0991f13`, "examples: Test the PMP of the harts and the LO and HI peripheral windows", since rewritten; the tip now is `c887476`) for the cells below: **the earlier versions of the tests**, which the current ones replace. The count of entries was first taken at `424bc7c` with the same `pmp_probe` |
| Toolchain | the pins of `tools/toolchain.env`; OpenOCD `0.12.0-mchp.0.0.3` |
| Method | `./x hw reset` and `./x hw initialize --minimal --xml config/boards/icicle_es/ICICLE_MSS_mss_cfg.xml` before every run |
| Console | MMUART0 on `/dev/ttyUSB0`, 115200 8N1 |

### Number of entries

`./x hw run examples/pmp_probe/bin-<e51|u54>/pmp_probe.elf --hart <0|1> --secs 5`. `pmp_mask.S` writes a pattern of ones to
`pmpaddr0` to `pmpaddr15`, reads it back and clears it again; an entry that does not exist reads back zero.

| Hart | Core | `pmp entries` | `pmp mask` | Trap |
|---|---|---|---|---|
| 0 | E51 | 16 | `0xffff` | none |
| 1 | U54 | 16 | `0xffff` | none |

16 entries on both core types, as Microchip documents and as Renode models; QEMU 10.1 reports 8. The probe
looks at `pmpaddr0` to `pmpaddr15` only, so 16 is the count within that range. The granularity G is 0 on both
harts (`pmp_xml_test`).

### The test programs

`LAB_CONF=build/lab/claude-lab.conf tests/hw/run_matrix.sh -s 25 pmp_xml_test_e51 pmp_xml_test_u54
pmp_access_test_e51 pmp_access_test_u54 apb_window_test_e51 apb_window_test_u54`: **3 pass, 3 fail**, every cell
with no flag (`--uart-standin` not needed).

| Cell | Verdict | Checks | Note |
|---|---|---|---|
| `pmp_xml_test_e51` | PASS | 19 ok | |
| `pmp_xml_test_u54` | FAIL | 18 ok, 1 failed | `pmpaddr0`: found `0x0000000fffffffff`, expected `0x003fffffffffffff` |
| `pmp_access_test_e51` | PASS | 45 ok | |
| `pmp_access_test_u54` | PASS | 45 ok | |
| `apb_window_test_e51` | FAIL | 9 ok, 1 failed | "MMUART3 in HI: a read at the LO address faults (TRM 3.8)" |
| `apb_window_test_u54` | FAIL | 9 ok, 1 failed | the same check |

### Findings

- **`pmpaddr` width on a U54.** Written with the all-ones NAPOT value of the XML (bits 53:0), `pmpaddr0` reads
  back with bits 35:0 set. That matches a 38-bit physical address; the width was not probed on its own. The test
  leaves out only bits 63:54, so it fails on hart 1. The E51 has no entry in the XML, so the comparison does not
  reach this case there.
- **Reset value of `pmpcfg0` and `pmpcfg2` is not zero.** At the start of `pmp_xml_test` the 16 `pmpaddr` read
  zero, the configuration registers do not: hart 0 `pmpcfg0` `0x0107050106020706`, `pmpcfg2`
  `0x0707070203030102`; hart 1 `0x0606050505070605` and `0x0107010606010507`. Every byte has the A field 0 (OFF)
  and L clear, so no entry is active or locked; `pmp_access_test` found no locked entry at its start. QEMU and
  Renode read all 18 zero.
- **The wrong APB window answers instead of faulting.** With `APBBUS_CR.MMUART3` set (`APBBUS_CR` reads
  `0x00000008`), `SR` of MMUART3 holds a write at the HI address, and a read at the LO address answers 0 without
  a fault. A write at the LO address, with the posted mode (`AHBAPB_CR`) off and on, does not fault and leaves
  `SR` at the HI address unchanged; `mip` did not change (hart 0 `0x0`, hart 1 `0x222` as at start). MMUART3 in LO
  read at the HI address answers 0 as well; RTC and timer read 0 at both addresses, also with the bits set
  (`APBBUS_CR` `0x00440008`).
- **The PMP separates the contexts.** In U mode, one NAPOT entry over the window of the context's own
  peripherals lets MMUART2 (LO) and MMUART3 (HI) answer, and the access to the window of the other context
  faults with mcause 5 (read) and 7 (write), on both harts; the other checks of `apb_window_test` pass.

### After a power cycle

`pmp_xml_test` as the first image on each hart, with `./x hw run pmp_xml_test --hart <0|1> --secs 10` and without
`./x hw reset` or `./x hw initialize` before it (the earlier version of the test, as above). All 18 registers are
set, none is zero: the 16 `pmpaddr` hold values of at most 36 bits (the largest is `0x0000000f65a9b837`), and the
configuration bytes have only bits 2:0 set, with A = OFF and L clear. Hart 0 reads `pmpcfg0` `0x0507020106020706` and
`pmpcfg2` `0x0707070202030102`, `pmpaddr0` `0x0000000c6adfffa3`; hart 1 reads `0x0206050705070605`,
`0x0107000606010507` and `pmpaddr0` `0x0000000db07c379a`. After `./x hw reset` and `./x hw initialize --minimal`
the `pmpaddr` read zero (run above) and the configuration bytes were not zero: the state after that reset
differs from the one after the power cycle; why was not examined. 16 entries, G = 0 on both harts; hart 1 ended with FAIL
as in the run above (the reason was not looked at in this run).

### The current versions of the tests, E51 and U54 harts 1 to 4

The tests of #129 (the current versions: `pmp_xml_test` measures the width of `pmpaddr`, `apb_window_test`
checks the effect of an access in the wrong window and reports the Bus Error Unit) with `start.S` of the bare
images clearing `satp`, `medeleg` and `mideleg` on a hart with S mode, and the new `pmp_isolation_test`:
`tests/hw/run_matrix.sh -s 25` on the cells below, in two calls, each cell after `./x hw reset` and
`./x hw initialize --minimal`. **20 pass, 0 fail.**

| Test | E51 | U54 hart 1 | U54 harts 2, 3, 4 | Checks |
|---|---|---|---|---|
| `pmp_xml_test` | PASS | PASS | PASS | 19 |
| `pmp_access_test` | PASS | PASS | PASS | 45 |
| `pmp_isolation_test` | PASS | PASS | PASS | 30 |
| `apb_window_test` | PASS | PASS | PASS | 29 |

`misa` of the harts (read in M mode): E51 `0x8000000000101105`, extensions A, C, I, M and U (no S, no FPU); U54
hart 1 `0x800000000014112d`, A, C, D, F, I, M, S and U. `mvendorid`, `marchid` and `mimpid` read 0 on both. The E51
has U mode and the PMP applies to it; it has no S mode.

**`satp` has no reset value (the failure of harts 3 and 4).** With the first versions of the tests, `pmp_access_test` and
`apb_window_test` failed on U54 harts 3 and 4 and passed on hart 2 (and hart 1): every access in U mode raised
mcause 1 with `mepc` and `mtval` the address of the code, even with an entry NAPOT RWX over the whole space, and
also in S mode. After `./x hw reset` and `./x hw initialize --minimal`, `satp` read `0x036d478f` (hart 1),
`0x00e5c09a` (hart 2), `0x80000000002adbbd` (hart 3) and `0x8000000000842a03` (hart 4): on harts 3 and 4 the MODE
field (bits 63:60) was set, so a fetch below M mode went through a page table. `medeleg` read `0x9008`, `0x1000`,
`0x3000` and `0x8` and `mideleg` random values as well; no bit for an access fault or an ecall was set, so
they did no harm here. M mode does not use `satp`, and the PMP itself worked on hart 3 (the M-mode checks of
locked entries passed). A probe that wrote `satp = 0` before the access made U mode work on harts 3 and 4
(mcause 8, the ecall), and `start.S` now does it. The PMP CSRs are in the same state: no reset value
(see "After a power cycle").

**Isolation of U mode from M mode with locked entries** (`pmp_isolation_test`, 30 checks, the same on all five
harts): U mode reaches its page (loads and stores) and nothing else; the kernel's page, which has no entry,
faults for load, store and fetch (mcause 5, 7, 1); the locked code page cannot be written and the data page cannot
be executed (7, 1); `csrw` and `csrr` of `pmpcfg0` in U mode are illegal instructions (mcause 2). M mode reaches
the page without an entry and is bound by the locked entries with the rights of U mode (the store to the
locked code page and the fetch from the data page fault); its writes to the locked `pmpcfg0` bytes and
`pmpaddr2` are ignored; it opens the kernel's page to U mode with an unlocked entry and closes it again; a
locked entry without rights over it locks M mode out (mcause 5, 7) and U mode too. A locked entry has the same
rights in both modes: what only M mode reaches is a region that no entry matches.

### Not covered

- M mode with the configuration of the XML applied (U54 entry 0 locked, NAPOT, RWX): nothing was run with it.
- Entries that are locked before the image starts (the project does not use Microchip's start code or boot
  loader): boot mode 0 leaves none.
- G > 0: the board has G = 0.
- The cells of the first versions of the tests (above) are kept as measured; they failed where the tests
  were wrong or where they reported what the board does. The current versions pass.
- `pmp_access_test`, `pmp_isolation_test` and `pmp_xml_test` lock entries, so each run started from a reset;
  every cell ran once on 2026-11-20, no repeat for scatter.
