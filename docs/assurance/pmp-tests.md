<!--
SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
SPDX-License-Identifier: CC-BY-4.0
-->
# PMP tests

The PMP (physical memory protection) of the five harts is configured by the user with Microchip's MSS
Configurator (pfsoc_mss), not by the configuration generator. The MSS Configurator XML holds it in
`mss_memory_map/pmp_h0` to `pmp_h4` (`CSR_PMPCFG0` for the entries 0 to 7, `CSR_PMPCFG2` for 8 to 15,
`CSR_PMPADDR0` to `15`). PMP is part of the MSS and the same in every PolarFire SoC; any board's XML can set
it differently. The generator only reads it (`python3 config/gen/mpfs_gen pmp XML`, requirement `GEN-010`).

What matters is that the PMP works on the hardware as configured. This page lists the test programs that
check it (requirement `HW-003`), what the reference XMLs and a boot stage put into the PMP, the test of the LO
and HI windows of the APB peripherals that the AMP contexts of the MSS Configurator rely on (`HW-004`), what
the emulators show, how the tests are run on the Icicle Kit, and what CI covers.

The number of entries: the MSS TRM (DS60001702S, §3.1.4, p. 13) gives 16 per hart ("Each Hart supports a
Physical Memory Protection (PMP) unit with 16 PMP regions"), SiFive's U54-MC documents give 8; QEMU models 8,
Renode 16. The Icicle Kit has 16 on the E51 and on U54 hart 1 (`pmp_probe`, mask `0xffff`, [first comment on
#103](https://github.com/ThyMYthOS/ada_mpfs/issues/103#issuecomment-7038686697)); harts 2 to 4 are not measured.

## The test programs

All five are bare images (no runtime, like `bare_hello`) for the E51 (hart 0) and a U54 (hart 1); `--harts N`
builds the image of U54 hart N (2 to 4) into `bin-u54-h<N>/`, for the board (see "On the board"). They report on
MMUART0; the four tests use the protocol of `Test_Report` (`TEST <name>: PASS` only if every check held; the
name ends in `_e51`, `_u54` for hart 1 and `_u54h<N>` for harts 2 to 4). They share `Pmp_Csr` (the CSRs by number, the encodings, the count and the granularity) and `pmp_try.S`
(one load, store or fetch in M or U mode with its own trap handler) in `examples/pmp_probe`.

| Example | What it checks |
|---|---|
| [`pmp_probe`](../../examples/pmp_probe/README.md) | The number of entries: writes a pattern to `pmpaddr0` to `15` and reads it back (WARL: a missing entry reads zero). Prints `pmp entries <n>` and the mask; then writes all ones (64 bits) to `pmpaddr0` and prints what reads back (`pmp pmpaddr0 ones 0x...`) and the width that gives (`pmp pmpaddr width <bits>`). |
| [`pmp_xml_test`](../../examples/pmp_xml_test/README.md) | The configuration of the XML: reads `pmpcfg0`, `pmpcfg2` and `pmpaddr0` to `15` before anything else and prints them (`at start hart <n> ...` lines; reported, not checked); unless an entry is locked already, counts the entries, measures the width of `pmpaddr` (all ones written to `pmpaddr0` and read back: the lines `pmpaddr0 after writing all ones`, `pmpaddr width`, `pmpaddr bits compared`) and the granularity G, and writes the values of the XML as Microchip's `pmp_configure()` does; then reads every CSR back and compares it with the table `Pmp_Xml`, generated from the XML, as the hart must return it (WARL: configuration bits 6:5 zero, the low bits of `pmpaddr` after G, zero for an entry the hart does not have; `pmpaddr` in the bits the hart implements, at most 53:0, see "Emulators" and "On the board"). Fails if the XML uses an entry the hart does not have. 19 checks. |
| [`pmp_access_test`](../../examples/pmp_access_test/README.md) | The access semantics, with a configuration of its own over four pages of 4 KiB: single loads, stores and instruction fetches in M and U mode, each either completing or raising the access fault it must (`mcause` 1, 5, 7; `mtval` the address). U mode with NAPOT entries R, RW and X and with no matching entry (denied); M mode not subject to entries without L; TOR over two pages, NA4 on one word; the matching entry with the lowest index decides, against a NAPOT entry RWX in the last entry of the hart; L: locked entries apply to M mode, a locked `pmpaddr` and configuration byte ignore writes, and so does `pmpaddr(i-1)` of a locked TOR entry i, while unlocked entries still take them. Needs six entries and a granule of at most 4 KiB; with G > 0 the two NA4 cases are left out. 45 checks. |
| [`pmp_isolation_test`](../../examples/pmp_isolation_test/README.md) | The isolation of U mode from M mode with locked entries, as a partition with its application in U mode and its kernel in M mode sets it up: entries 0 and 1 lock the two code pages R X, entry 2 locks the application's page RW, the kernel's page has no entry. U mode reaches its page and nothing else (the kernel's page faults for load, store and fetch: mcause 5, 7, 1; a store to the code page and a fetch from the data page fault), and cannot read or write `pmpcfg0` (illegal instruction, mcause 2). M mode reaches the page that no entry matches, and is bound by the locked entries with the rights of U mode (a store to the code page and a fetch from the data page fault); its writes to the locked `pmpcfg0` bytes and `pmpaddr2` are ignored. M mode opens the kernel's page to U mode with an entry that is not locked and closes it again; a locked entry without rights over it then locks M mode out as well. A locked entry has the same rights in both modes, so what only M mode reaches is a region that no entry matches. 30 checks. Needs four entries and a granule of at most 4 KiB (requirement `HW-005`). |
| [`apb_window_test`](../../examples/apb_window_test/README.md) | The LO and HI windows under `APBBUS_CR`, see "AMP contexts and `APBBUS_CR`". Checks that a peripheral holds a write in its own window and that an access in the other window has no effect; reports whether that access faulted and what the Bus Error Unit of the hart, `mip` and the PLIC recorded; checks one PMP entry per context in U mode. 29 checks with a HI window, 15 without (Renode), 9 where RTC and timer are not modelled either (QEMU). |

The table of the XML is `examples/pmp_xml_test/src/generated/pmp_xml.ads`, made from the XML of the Icicle Kit
(`config/boards/icicle`) by `python3 config/gen/mpfs_gen pmp --ada <file> <xml>`; `tests/host/pmp` checks that it
is current. `PMP_XML=<file> ./x build pmp_xml_test` builds the test with the table of another XML (generated into
`obj-<hart>/pmp_xml`, the committed file is left alone), for an XML that the user has changed in pfsoc_mss.

Both tests lock entries (the XML of the Icicle Kit sets entry 0 of each U54 locked, and the access test locks
two entries at its end): only a reset undoes that, so each run starts from a reset.

## What the reference XMLs set

Printed by `python3 config/gen/mpfs_gen pmp config/boards/<board>/<file>.xml` for the three XMLs of
`config/boards` (`icicle`, `icicle_es`, `video_kit`); all three set the same:

| Hart | `pmpcfg0` | `pmpcfg2` | Entries not OFF |
|---|---|---|---|
| 0 (E51) | `0x0` | `0x0` | none |
| 1 to 4 (U54) | `0x9f` | `0x0` | entry 0: NAPOT with `pmpaddr0` all ones, the whole address space, RWX, locked |

`MEM_CONFIGS_ENABLED.PMP` is 0 in all three. Each U54 uses one entry of the XML, the E51 none.

Applied, this configuration allows every access of M and U mode on a U54, and because the matching entry with
the lowest index decides and entry 0 is locked and matches every address, no entry that software writes later
has any effect on that hart until the next reset. Any separation by the PMP on the U54s therefore has to be
set in the XML (in pfsoc_mss), or the boot stage must not apply these values. That choice is the user's; the
tests only show what the hart does with the values it is given.

## What a boot stage leaves in the PMP

This is the known trap of the current XMLs: Microchip's boot code writes the PMP of the XML on harts 1 to 4
unconditionally, whatever `MEM_CONFIGS_ENABLED.PMP` says, and the locked open entry 0 then holds until reset.

- **Boot mode 0, an image loaded over JTAG** (how the tests run on the board): nothing of Microchip's runs
  before the image. `pmp_xml_test` prints the CSRs as it finds them at its start (the `at start` lines). Under
  QEMU and Renode all 18 read zero (measured with `pmp_xml_test` on hart 0 and hart 1). On the Icicle Kit they
  are not zero; see "The PMP at power-on" below.
- **Microchip's bare-metal start code** (the platform HAL at the commit of `tools/mchp_diff/oracle.env`):
  `system_startup.c:379-397` calls `init_pmp()` on each of harts 1 to 4 before `u54_n()`, which is
  `pmp_configure()` (`mss_pmp.c:124-159`): `pmpcfg0` and `pmpcfg2` 0, `pmpaddr0` to `15` from the XML, then
  `pmpcfg0` from the XML; `pmpcfg2` and the hook `pmp_master_configs()` only when `MEM_CONFIGS_ENABLED.PMP` is
  set. An image built on that HAL therefore starts on a U54 with entry 0 of the XML locked.
  The project does not use that start code or Microchip's boot loader. `pmp_xml_test` still handles an image
  that finds a locked entry at its start (left by an earlier stage): it writes nothing and compares the CSRs
  as they are (not run).

`pmp_xml_test` itself writes `pmpcfg2` as well, whatever `MEM_CONFIGS_ENABLED.PMP` says, so that every CSR is
compared.

### The PMP at power-on

Measured on the Icicle Kit (`MPFS250T_ES`, boot mode 0, 2026-11-20) with `pmp_xml_test` as the first image after
a power cycle, without `./x hw reset` or `./x hw initialize` before it, on hart 0 and hart 1 (the `at start`
lines; no trap, 16 entries, G = 0 on both):

| Register | Hart 0 (E51) | Hart 1 (U54) |
|---|---|---|
| `pmpcfg0` | `0x0507020106020706` | `0x0206050705070605` |
| `pmpcfg2` | `0x0707070202030102` | `0x0107000606010507` |
| `pmpaddr0` | `0x0000000c6adfffa3` | `0x0000000db07c379a` |
| `pmpaddr1` | `0x0000000d33753c7e` | `0x0000000f2aa9bff9` |
| `pmpaddr2` | `0x000000075dbd9979` | `0x00000007e90e3a4b` |
| `pmpaddr3` | `0x0000000b3511d303` | `0x0000000a6dff9ad3` |
| `pmpaddr4` | `0x0000000d571bd3f4` | `0x0000000a17a0f1c6` |
| `pmpaddr5` | `0x0000000df39b2c3c` | `0x0000000977097569` |
| `pmpaddr6` | `0x0000000d3df4e479` | `0x0000000795c71332` |
| `pmpaddr7` | `0x0000000b96737dfb` | `0x0000000471b2742b` |
| `pmpaddr8` | `0x00000004fdf683d1` | `0x00000003626f88c1` |
| `pmpaddr9` | `0x0000000a2429dd21` | `0x000000068ae13b5b` |
| `pmpaddr10` | `0x0000000cfd93859f` | `0x0000000c69eca0bf` |
| `pmpaddr11` | `0x0000000f65a9b837` | `0x00000002337a57ba` |
| `pmpaddr12` | `0x00000002165f1e27` | `0x0000000e84bbd08a` |
| `pmpaddr13` | `0x0000000e1cd10348` | `0x0000000843509c60` |
| `pmpaddr14` | `0x0000000a3584b7e0` | `0x000000068af33b5b` |
| `pmpaddr15` | `0x0000000e0f2023d1` | `0x000000068af73b5b` |

After a power cycle all 18 PMP registers hold random values. In every configuration byte only bits 2:0 (R, W,
X) are set: A = OFF and L = 0 in all 64 bytes, what the Privileged Spec guarantees at reset, so no entry is active
or locked. No `pmpaddr` value has a bit above 35, which is consistent with the 36 bits measured at `pmpaddr0`
(see "On the board") but is not a measurement of the width of its own.

In the run of the tests (each cell after `./x hw reset` and `./x hw initialize --minimal`, [comment of
2026-11-20 on #103](https://github.com/ThyMYthOS/ada_mpfs/issues/103#issuecomment-7041553523)) the 16 `pmpaddr` read zero and `pmpcfg0` and `pmpcfg2` were not zero (hart 0
`0x0107050106020706` and `0x0707070203030102`, hart 1 `0x0606050505070605` and `0x0107010606010507`, every byte
A = OFF, L clear). Which of the two steps cleared `pmpaddr` was not checked. The non-zero `pmpcfg` is a
power-on value, not a leftover of an earlier image.

So software must not rely on zero PMP registers, after a power cycle or after a reset: an entry is configured
by writing its whole configuration byte (the rights included) and its `pmpaddr`, never by setting bits in what
is there. The tests do that (`Pmp_Csr.Set`, `Set_Cfg`, `Clear_All`), and `pmp_xml_test` reports the registers at
its start without checking them.

## AMP contexts and `APBBUS_CR`

The MSS Configurator has two AMP contexts, A and B. There is no context in the hardware: the Configurator turns
them into `APBBUS_CR` (SYSREG offset `0x80`: per dual APB peripheral 0 = LO window `0x2000_0000` over AXI bus 5,
1 = HI window `0x2800_0000` over AXI bus 6; the peripherals of context B in HI) and into one PMP table per
context, with one NAPOT window over the LO or the HI peripheral block. The MSS TRM (DS60001702S) names this as
the purpose ("This ensures efficient use of the PMP registers to isolate two AMP contexts", §10, p. 152) and
says that a peripheral "accessed in the wrong region" answers with PSLVERR, "reported to the processor core as
an AXI response error" (§3.8, p. 49). If that holds, the LO window of context A does not reach a peripheral of
context B, and one PMP entry per context covers all its APB peripherals.

**Measured on the Icicle Kit** (`MPFS250T_ES`, boot mode 0, E51 and U54 hart 1, each run after `./x hw reset`
and `./x hw initialize --minimal`; [comment of 2026-11-20 on #103](https://github.com/ThyMYthOS/ada_mpfs/issues/103#issuecomment-7041553523), with the earlier version of
`apb_window_test`, which expected the fault of the TRM):

- `APBBUS_CR` holds the bit of MMUART3 (`0x00000008`), and `SR` of MMUART3 then holds a write at the HI address;
- a read at the LO address answers 0 without a fault (the check of the TRM failed on both harts); a write at the
  LO address, with the posted mode of the AHB-APB bridges (`SYSREG.AHBAPB_CR`, offset `0x90`: `APB0_POSTED`
  bit 0, `APB1_POSTED` bit 1) off and on, does not fault and leaves `SR` at HI unchanged. The PSLVERR "reported
  to the processor core as an AXI response error" (TRM §3.8) was not observed on the board: no synchronous
  fault on the core;
- RTC and timer read 0 at both addresses (offset 0; that tells nothing either way);
- in U mode one NAPOT entry per context separates the contexts: the own window answers, the other faults
  (`mcause` 5 and 7), on both harts; G = 0.

An access in the wrong window has no effect, but it does not fault either: the separation of the contexts
comes from the PMP, not from the windows. Open: where the error goes, if anywhere (the Bus Error Unit, an
interrupt), the reverse direction (a peripheral left in LO at its HI address), and RTC and timer with values
that can be told from 0. The current `apb_window_test` measures these; it has not run on the board yet.

Further restrictions, from the TRM and the SVD:

- the HI addresses of RTC and timer are `0x2812_4000` and `0x2812_5000` in the SVD; Table 10-2 of the TRM
  shows `0x2012_4FFF` and `0x2012_5FFF`, apparently an erratum;
- SYSREG, SCB, the AXI switch configuration, MPUCFG and the configuration of MMC and DDRC exist in LO only;
  QSPI, eNVM, IOSCB and USB are on AHB0 only and have no HI alias. So `SUBBLK_CLOCK_CR` and `SOFT_RESET_CR`
  (SYSREG) are reachable from both contexts or from neither, and either context that reaches SYSREG can
  rewrite `APBBUS_CR`.

`apb_window_test` checks the measured behaviour with values that can be told apart: a non-zero pattern is
written through the right window first. The registers are the scratch register `SR` (offset `0x1C`) of MMUART3
and MMUART2, which are not the console and have no side effect, the load value `TIM1LOADVAL` (offset `0x4`) of
the timer and `COMPARE_LOWER` (offset `0x14`) of the RTC, which hold what is written. It clocks the four blocks
and takes them out of reset, then:

| Step | What is measured | Checked |
|---|---|---|
| 0. Set-up | whether `APBBUS_CR` holds the bit of MMUART3 (the HI window); the Bus Error Unit of the hart as found, then set to record a TileLink bus error (cause 5) and to raise its PLIC source | (reported) |
| 1. All in LO | `SR` of MMUART3, `TIM1LOADVAL`, `COMPARE_LOWER`: written and read at LO, read and written at HI | each holds the write at LO; at HI a read does not return it, a write does not change it |
| 2. MMUART3 in HI | `SR` written and read at HI; read at LO; written at LO with the posted mode off, then on; MMUART2, left in LO, at LO and at HI | `SR` of MMUART3 holds the write at HI, a read at LO does not return it, neither LO write changes it; the same for MMUART2 the other way round |
| 3. RTC and timer in HI | `TIM1LOADVAL` at `0x2812_5004`, `COMPARE_LOWER` at `0x2812_4014`; read and written at LO | each holds the write at HI (the addresses of the SVD); at LO a read does not return it, a write does not change it |
| 4. Context A in U mode: one NAPOT entry RW over the 256 KiB at `0x2010_0000` | MMUART2 at LO; MMUART3 at HI (read, write); MMUART3 at LO | MMUART2 answers; the HI accesses fault (5, 7) |
| 4. Context B in U mode: the same entry over `0x2810_0000` | MMUART3 at HI; MMUART2 at LO (read, write); MMUART2 at HI | MMUART3 answers (with a HI window); the LO accesses fault (5, 7) |
| 5. Restore | `APBBUS_CR`, `AHBAPB_CR`, the enables of the Bus Error Unit, the PMP | |

Steps 2 and 3 run only where `APBBUS_CR` holds the bit, that is on the board. Whether an access in the wrong
window faulted is an info line (`wrong window, fault yes` or `no`), not a check. After each such access one line
reports where an error could have gone:

    info: errors after <case>, <access>: mip 0x...., plic pending 182..186 0x.., beu cause 0x.. value 0x... accrued 0x..

with `mip` of the hart, the PLIC pending bits of the sources `E51_BUS_ERROR_UNIT` (182) to
`U54_4_BUS_ERROR_UNIT` (186) (bit 0 is source 182; the PLIC powers up with random pending bits, so the line
`plic pending 182..186 at start` comes first), and `cause`, `value` and `accrued` of the Bus Error Unit of the
hart, which are cleared after each line. The Bus Error Unit is at `0x0170_0000 + 0x1000 * hart`, with `cause`,
`value`, `enable`, `plic_interrupt`, `accrued` and `local_interrupt` at the offsets `0x00` to `0x28`
(`mpfs_hal/common/mss_beu_def.h` of Microchip's platform HAL; cause 5 is `BEU_EVENT_TILELINK_BUS_ERROR`). For the
test `enable` and `plic_interrupt` are set to bit 5 and `local_interrupt` to 0 (`mie` is 0, so nothing is
taken); the three are restored at the end. Where the Bus Error Unit faults the line says `beu absent`; where its
`enable` does not hold the write (QEMU and Renode: both read 0 there) an info line says that its values say
nothing. Each access is announced by a `next:` line, so a bus that hangs shows where. A context layout needs one
PMP entry for all the APB peripherals of its window (two with the entry of the code in this test), where a
layout per peripheral needs one per peripheral (one per MMUARTn and WDOGn pair, which are adjacent).

What the emulators do (measured with `apb_window_test` on hart 0 and hart 1):

| Access | QEMU 10.2.1 | Renode 1.17.0 |
|---|---|---|
| `APBBUS_CR` after setting the bit of MMUART3 | reads 0: not modelled | reads 0: not modelled |
| MMUART3 in LO, `SR` at LO | holds the write | holds the write |
| a HI address (`0x2810_xxxx`, `0x2812_xxxx`), M mode | access fault, `mcause` 5 and 7 | answers, reads 0; a write has no effect |
| RTC `COMPARE_LOWER`, timer `TIM1LOADVAL` at LO | access fault, `mcause` 7: not modelled | hold the write |
| the Bus Error Unit | reads 0, `enable` does not hold a write | reads 0, `enable` does not hold a write |
| context A / B: the address in the window of the other context, U mode | faults (5, 7): the PMP | faults (5, 7): the PMP |

Neither emulator models the HI window, so steps 2 and 3 are left out there (the test says so) and the
measurement is the board's. Not tested by the program, to be looked at on the board: the PLIC sources of a
peripheral in HI (the same source numbers are expected), changing `APBBUS_CR` while a peripheral is in use,
and DMA masters, which are governed by the MPUs, not by the contexts.

## Emulators

| Where | Entries | G | `pmp_xml_test` | `pmp_access_test` | `apb_window_test` |
|---|---|---|---|---|---|
| QEMU 10.2.1, `microchip-icicle-kit` | 8 | 0 | PASS on hart 0 and 1 | PASS on hart 0 and 1 (last entry 7) | PASS on hart 0 and 1, steps 2 and 3 left out |
| Renode 1.17.0, `mpfs-icicle-kit.repl` | 16 | 0 | PASS on hart 0 and 1 | PASS on hart 0 and 1 (last entry 15) | PASS on hart 0 and 1, steps 2 and 3 left out |
| Icicle Kit (`MPFS250T_ES`), hart 0 and 1, earlier versions of the tests ([#103](https://github.com/ThyMYthOS/ada_mpfs/issues/103#issuecomment-7041553523)) | 16 | 0 | PASS on hart 0; FAIL on hart 1 (`pmpaddr0`, see "On the board") | PASS on hart 0 and 1 (45 checks each) | FAIL on hart 0 and 1 (the fault of the TRM, see "AMP contexts and `APBBUS_CR`") |
| Icicle Kit (`MPFS250T_ES`), the current versions, hart 0 to 4 ([results](../lab/results/pmp-entries.md)) | 16 | 0 | PASS on hart 0 to 4 | PASS on hart 0 to 4 | PASS on hart 0 to 4 |

Measured with `./x qemu <example> --hart 0|1` and with the Renode script of `tests/renode` (the lines
`pmp entries`, `pmp granularity G` and `last entry` of the reports); `pmp_probe` gives the same counts in the
smoke tests (`tests/qemu/smoke.expected`, `tests/renode/smoke.expected`). The README of `pmp_probe` names QEMU
10.1.0, where the count was first taken; the runs for this page used 10.2.1 and give the same 8.

`pmp_isolation_test` passes in both emulators (30 checks each, 8 entries in QEMU 10.2.1 and 16 in Renode 1.17.0); it
needs four entries.

The tests adapt to the number they count: the comparison of `pmp_xml_test` expects zero in an entry the hart
does not have, and `pmp_access_test` puts its catch-all entry into the last one. None needs more than six
entries, so they run under QEMU as well.

The width of `pmpaddr`: QEMU returns all 64 bits as they were written (`pmp pmpaddr0 ones 0xffffffffffffffff`,
`pmp pmpaddr width 64`), bits 63:54 included, where the Privileged Spec v1.10 makes them WIRI (writes ignored, a
read is to be ignored); the first run of `pmp_xml_test_u54` under QEMU failed on exactly this, so the comparison
leaves those bits out. Renode returns bits 53:0 (`0x003fffffffffffff`, width 54). The Icicle Kit implements
fewer (see "On the board"), so `pmp_xml_test` compares `pmpaddr` in the bits that the hart returns when all ones
are written, at most 53:0.

## On the board

Run on the Icicle Kit (`MPFS250T_ES`, boot mode 0, E51 and U54 hart 1, 2026-11-20, `tests/hw/run_matrix.sh`, each
cell after `./x hw reset` and `./x hw initialize --minimal`; [comment on #103](https://github.com/ThyMYthOS/ada_mpfs/issues/103#issuecomment-7041553523)) with the earlier versions
of the tests:

| Cell | Verdict | Checks |
|---|---|---|
| `pmp_xml_test_e51` | PASS | 19 ok |
| `pmp_xml_test_u54` | FAIL | 18 ok, 1 failed |
| `pmp_access_test_e51`, `_u54` | PASS | 45 ok each |
| `apb_window_test_e51`, `_u54` | FAIL | 9 ok, 1 failed each |

- `pmpaddr` is WARL and narrower than the earlier `pmp_xml_test` assumed: on hart 1 the all-ones NAPOT value of
  the XML (`0x003fffffffffffff`) written to `pmpaddr0` reads back `0x0000000fffffffff`, bits 35:0, which fits a
  38-bit physical address. The test compared bits 53:0 and failed; a defect of the test, not of the hart. It
  now measures the width first (`pmpaddr0 after writing all ones`, `pmpaddr width`) and compares in those bits;
  `pmp_probe` prints the same (`pmp pmpaddr0 ones`, `pmp pmpaddr width`). The width was not measured on its own
  in that run.
- `pmpcfg0` and `pmpcfg2` were not zero at the start: see "The PMP at power-on".
- The wrong APB window answers instead of faulting: see "AMP contexts and `APBBUS_CR`". `apb_window_test` now
  checks that such an access has no effect and reports the fault, the Bus Error Unit, `mip` and the PLIC.

Not covered by that run: U54 harts 2 to 4, M mode with the configuration of the XML applied (U54 entry 0 locked,
NAPOT, RWX), entries locked before the image starts, and G > 0. The current versions of the four tests and of
`pmp_probe` have run since on the E51 and on U54 harts 1 to 4 (`pmp_xml_test` 19 checks, `pmp_access_test` 45,
`pmp_isolation_test` 30, `apb_window_test` 29): all 20 cells pass, see
[`docs/lab/results/pmp-entries.md`](../lab/results/pmp-entries.md). On U54 harts 3 and 4 the U-mode accesses of
`pmp_access_test` and `apb_window_test` failed (mcause 1) until `start.S` cleared `satp`, `medeleg` and `mideleg`,
which have no reset value; the results have the details. Not covered by any run: M mode with the configuration of
the XML applied, entries locked before the image starts, and G > 0.

The commands for the next run, in boot mode 0 with OpenOCD running (`hw/README.md`):

```sh
# 1. the PMP right after a power cycle: power-cycle the board, start OpenOCD, then WITHOUT ./x hw reset or
#    ./x hw initialize run pmp_xml_test as the first image on each hart. Each hart has its own PMP, so one
#    power cycle serves all five; the "at start hart <n>" lines are the power-on values.
./x hw run pmp_xml_test --hart 0 --secs 5 --expect 'TEST pmp_xml_test_e51: (PASS|FAIL)' --expect-port 0
./x hw run pmp_xml_test --hart 1 --secs 5 --expect 'TEST pmp_xml_test_u54: (PASS|FAIL)' --expect-port 0
./x hw run pmp_xml_test --hart 2 --secs 5 --expect 'TEST pmp_xml_test_u54h2: (PASS|FAIL)' --expect-port 0
#    (--hart 3, --hart 4 the same with _u54h3, _u54h4)

# 2. the number of entries and the width of pmpaddr (pmp_probe reports no verdict)
./x hw reset && ./x hw initialize --minimal
./x hw run pmp_probe --hart 0 --expect 'pmp pmpaddr width [0-9]+' --expect-port 0
./x hw reset && ./x hw initialize --minimal
./x hw run pmp_probe --hart 1 --expect 'pmp pmpaddr width [0-9]+' --expect-port 0

# 3. the four tests on the E51 and U54 hart 1 (rows of tests/qemu/tests.list) and on U54 harts 2 to 4
#    (<row>_u54h<N>: the row of hart 1 run on hart N, image built with --harts N); the script resets and
#    initializes before each cell
tests/hw/run_matrix.sh pmp_xml_test_e51 pmp_xml_test_u54 pmp_access_test_e51 pmp_access_test_u54 \
  pmp_isolation_test_e51 pmp_isolation_test_u54 apb_window_test_e51 apb_window_test_u54
tests/hw/run_matrix.sh pmp_xml_test_u54h2 pmp_xml_test_u54h3 pmp_xml_test_u54h4 \
  pmp_access_test_u54h2 pmp_access_test_u54h3 pmp_access_test_u54h4 \
  pmp_isolation_test_u54h2 pmp_isolation_test_u54h3 pmp_isolation_test_u54h4 \
  apb_window_test_u54h2 apb_window_test_u54h3 apb_window_test_u54h4
```

What to read from the logs (the console of step 1; `build/hw-results/<name>.log` of step 3):

- `grep 'at start hart'`: `pmpcfg0`, `pmpcfg2`, `pmpaddr0` to `15` as found (after a power cycle in step 1,
  after `./x hw reset` and `./x hw initialize --minimal` in step 3);
- `pmp entries`, `pmp granularity G`, `pmpaddr0 after writing all ones`, `pmpaddr width` (and in step 2
  `pmp pmpaddr0 ones`, `pmp pmpaddr width`);
- in `apb_window_test`: the lines `wrong window, fault yes|no` and `errors after ...` (where a PSLVERR goes: the
  `cause`, `value` and `accrued` of the Bus Error Unit, `mip`, the PLIC pending bits of the sources 182 to 186,
  against `plic pending 182..186 at start`), the `beu ... at start` lines, and the checks of RTC and timer at
  `0x2812_4000` and `0x2812_5000`;
- the verdicts.

The tests lock entries or change `APBBUS_CR`, so every run of step 3 starts from a reset (`run_matrix.sh` does
that before each cell). The results go into `docs/lab/results/` with the date, the board and the commit.

## What CI covers

| Where | What |
|---|---|
| `images` workflow, job `build` | builds the five examples for the E51 and the U54 (`./x test examples`), their sizes in `metrics.golden` |
| `images` workflow, job `qemu` | `./x test qemu`: the smoke rows of `pmp_probe` (8 entries, a `pmpaddr` of 64 bits) and the rows `pmp_xml_test_*`, `pmp_access_test_*`, `pmp_isolation_test_*`, `apb_window_test_*` (`_e51`, `_u54`) of `tests/qemu/tests.list` |
| `images` workflow, job `renode` | `./x test renode`: the rows of `tests/renode/smoke.expected`, `pmp_probe` with 16 entries and a `pmpaddr` of 54 bits, and the verdicts of the four tests |
| `registers` workflow, job `svd` | `tests/host/pmp`: the decoding of the PMP of the reference XMLs, a negative case for each error code (`GEN-E100`, `GEN-E101`), the table of `pmp_xml_test` current, and that the lists above run the tests |

Not covered: U54 harts 2 to 4 (the CI images run on hart 1; `run_matrix.sh` runs them on the board), a
`pmpaddr` narrower than 54 bits (the emulators implement 54 or 64), a granularity above 0 (the emulators have
G = 0), the HI window and the Bus Error Unit (modelled by neither emulator), and the MPUs of the bus masters,
which are not part of the PMP of the harts.
