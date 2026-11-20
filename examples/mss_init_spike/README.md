# mss_init_spike

A spike of a bootloader that sets the MSS up itself: an Ada image for the E51 that writes the system registers of the MSS
from the MSS Configurator XML of a board (`config/boards/icicle_es`) and then prints what it did on the UART. It is a primary
image (`__mpfs_boot_role` = 1, no boot stage before it) that is loaded into the LIM over JTAG like the other examples. It has
not run on a board: see "Not verified" below.

**Scope**, which is all there is: the reference clock (the RTC divisor, the SCB access timer, the DFI/APB clock, the dynamic
enables of the PHY), the IO mux and bank set-up, the `MSSIO_CONTROL_CR` handshake, the SGMII channel set-up as far as
`hw/mss_init.py` does it (reset, calibration, PLL and DLL lock; the second lane reset of rev C silicon) and the MSS PLL up to
its lock. **No clock switch**: nothing writes `ENVM_CR`, `CLOCK_CONFIG_CR` or `MSSCLKMUX`, so the CPU and the APB clock stay
as the reset left them (80 MHz and the clock for which the console divisor is 22). No DDR, no partitioning, no placement in
the eNVM.

## How it is made

The sequence is written down once, in Python: `hw/mss_init.py`, which `./x hw initialize` runs through OpenOCD (values from
the XML, the order, the read-modify-writes, the polls and the delays from the code). This spike does not copy it.

    config/boards/icicle_es/*.xml ──┐
                                    ├─ config/gen/mss_init_table.py ──> src/generated/mpfs_init_table.ads ──> Mss_Init (interpreter)
    hw/mss_init.py  (phases())  ────┘

- **The emitter** is `config/gen/mss_init_table.py`, a script next to `standalone.py` and built the same way (library
  `tools/gen_ada`, deterministic output, `--check` byte for byte, the licence header from `gen_ada.spdx`). It is a script of its
  own and not a subcommand of `config/gen/mpfs_gen`, because that package reads and checks inputs and has no emitter yet, while
  `standalone.py` is the existing model of a generator that writes one Ada package; the first emitter of the register values
  is one more such script. It imports `hw/mss_init.py` the way `hw/mss_init.py` imports the reader. To get the phases
  without a second list of the steps, `full()` of `hw/mss_init.py` is now the flattened `phases()`; `./x hw initialize` runs
  the same steps in the same order as before (`tests/host/hw`). `mss_init.run()` got an optional `on_timeout`, which the
  test of the spike uses.
- **The table** `MPFS_Init_Table` (generated, committed in `src/generated/`) is a constant array of entries
  `(Kind, Address, Value, Mask, Count, text range)` and a table of the five phases (`refclk`, `io`, `mssio`, `sgmii`, `pll`).
  One step of `mss_init.py` is one entry: `Write`, `Modify` (read, set the bits of `Value`, clear those of `Mask`, write),
  `Poll` (until `word and Mask = Value`, `Count` microseconds at most) and `Wait` (`Count` microseconds). The one step that is
  a decision on a value read at run time, `IfSet` (SPARE_STAT bit 31: rev C or later silicon resets the lanes a second
  time), is a `Skip_If_Clear` entry (read the address, skip the next `Count` entries if `word and Mask` is 0) followed by the
  entries of the steps it guards. With the XML of `icicle_es` that is 96 entries for the 93 steps. Texts are ranges of one
  constant string; the table says which XML it was made from (`XML_Source`, `XML_SHA256`, `Design`).
- **The interpreter** `Mss_Init` runs one phase at a time and knows only those five kinds. Time is counted in cycles of the
  hart (`mcycle`, 80 cycles per microsecond), not in `mtime`: `mtime` does not count before the reference clock is set up,
  and the first delay of the sequence (the MSSIO handshake) comes before the write that starts it (`phases()` says: with the
  `CLK_CNTL` write of the phase `sgmii`). The CPU stays on its boot clock because there is no clock switch, which is what
  makes the cycle count a time base; a poll budget is the timeout of the Python step in microseconds.
- **Timeouts** are a run-time parameter of the interpreter, `Mss_Init.Timeout_Policy`: `Stop` (a poll that runs out of its
  budget ends the sequence) or `Continue` (it is recorded and the sequence goes on). Two mains share everything else:
  `mss_init_spike` (the board, `Stop`) and `mss_init_spike_qemu` (QEMU, `Continue`). It is not a constant of the generated
  package, so the same table serves both and the test can show that the board image really stops.
- **The image** is an example (`examples/mss_init_spike`) and not a project under `boot/spike/`, because that costs the least:
  `./x build`, `./x test examples`, `./x metrics`, `./x repro` and the console row of `tests/qemu/tests.list` cover it without a
  build script of its own. It is linked with the `light` runtime and prints through `GNAT.IO`, so the console is the one of the
  runtime: a primary image brings MMUART0 up itself (clock, reset, divisor 22) with the first output, which comes before the
  first register of the sequence.

## Build, regenerate, run under QEMU

    ./x build mss_init_spike --hart e51                # bin-e51/mss_init_spike.elf and mss_init_spike_qemu.elf
    python3 config/gen/mss_init_table.py --xml config/boards/icicle_es/ICICLE_MSS_mss_cfg.xml           # rewrite the table
    python3 config/gen/mss_init_table.py --xml config/boards/icicle_es/ICICLE_MSS_mss_cfg.xml --check   # is it current
    ./x qemu mss_init_spike                            # first image: the board image, which stops at the first timeout
    ./x test qemu tests mss_init_spike_qemu_e51        # the QEMU image to its end
    bash tests/host/mss_init_spike/run.sh              # the comparison with the sequence of hw/mss_init.py

The table needs the merged SVD (`./x svd merge`, which `tools/svd.py ensure` makes current), because the reader checks the XML
against it. For another board: another `--xml` (the generator names it in the table) and another `--output`, or replace
the committed table. `MSS_INIT_TABLE_DIR=<dir> ./x build mss_init_spike` takes `mpfs_init_table.ads` from another directory.

Under QEMU the console shows (the numbers are those of the run on QEMU 10.2.1):

    mss_init_spike_qemu: MSS init from config/boards/icicle_es/ICICLE_MSS_mss_cfg.xml
    mss_init_spike_qemu: design ICICLE_MSS, Libero 2022.2, part MPFS250T_ES, format 0.6.5
    mss_init_spike_qemu: xml sha256 8e3f849a7dbc904023f5f3c50f7d867249d2e092b29a0b0a80540e184faaa4ad
    mss_init_spike_qemu: 96 table entries in 5 phases, a poll that times out is reported and the sequence goes on
    mss_init_spike_qemu: phase 1 refclk: entries 1-6, 6 run, 0 poll timeout(s), mtime 0x00001640
    ...
    mss_init_spike_qemu: phase 4 sgmii: entries 42-76, 32 run, 2 poll timeout(s), mtime 0x00026e78
    mss_init_spike_qemu: TIMEOUT entry 67: PLL_CNTL: SGMII PLL locked, 0x20007c08 and 0x00000080 is 0x00000000, wanted 0x00000080
    mss_init_spike_qemu: TIMEOUT entry 68: RECAL_CNTL: DLL locked, 0x20007c14 and 0x00800000 is 0x00000000, wanted 0x00800000
    mss_init_spike_qemu: phase 5 pll: entries 77-96, 20 run, 0 poll timeout(s), mtime 0x0002727d
    mss_init_spike_qemu: mtime 0x0002729f then 0x000272c0 after 100 us by mcycle: advancing
    mss_init_spike_qemu: MSS PLL: PLL_CTRL 0x02000000, LOCK 1
    mss_init_spike_qemu: 93 of 96 entries run, 2 poll timeout(s)
    mss_init_spike_qemu: MSS INIT DONE WITH TIMEOUTS

QEMU models some of the registers (the PHY's `PVT_STAT`, `PLL_CTRL` of the MSS PLL) and reads 0 from the others, so two polls
time out and the PLL lock bit reads 1 whatever was written. "mtime advances" and "LOCK 1" prove nothing under QEMU: they are
for the board.

## The test

`tests/host/mss_init_spike/run.sh` boots the QEMU image with `-trace memory_region_ops_read/write` (QEMU traces the accesses
to the MSS registers by the name of the device: `mchp.pfsoc.sysreg`, `.ddr_sgmii_phy`, `.ioscb.pll_mss` ...; no change of QEMU
is needed) and `compare_trace.py` runs the steps of `mss_init.full(values)` of the same XML through `mss_init.run()` with a
write function that takes the next write of the trace, and compares address, value and width. A Modify writes what the image
read: the read function gives the word that the trace shows (QEMU reads 0 from most registers and 0x4040 from `PVT_STAT`), so
the write must be `(read or set) and not clear`. A poll and the decision on the silicon revision need a read of their register
in the trace. The comparison covers every write of the image except those to its console (MMUART0): the sequence is all the
image writes, and a write that is not in it fails. With the XML of `icicle_es` 83 writes equal the sequence of 93 steps
(4 Modify steps, 1 IfSet, 5 polls, of which 2 are not met by what QEMU reads).

Negative controls: the image built from a table with one value flipped (`--tamper-write 10`, built with
`MSS_INIT_TABLE_DIR`) fails at the 11th write, `SYSREG.IOMUX4_CR`: wanted `0x88CC4444`, wrote `0x88CC4445`; the trace of the real
image fails against the XML of `config/boards/icicle` (write 7, `IOMUX0_CR`), against the sequence without the IO set-up
and with one write left out of the trace. The board image under QEMU stops at the first poll that times out and ends with
`MSS INIT FAILED`. The generator cases check that the committed table is current, that the output is the same twice and that the
entries of the table are the steps of `mss_init.full()`.

## On the Icicle Kit

What to do (nothing here has been run on a board):

1. Power-cycle the board, boot mode 0 (the harts idle, no HSS: `./x hw bootmode 0`), OpenOCD running (`./x hw openocd`). Do
   **not** run `./x hw initialize` first: the image sets the MSS up itself, and a second set-up of the SGMII block on top of the
   first would hide a failure of this one. `./x hw run` does not reset the board and does not touch the MSS (it clears the PLIC
   enables, halts the hart, loads the ELF into the LIM and resumes it; without `--uart-clocks` and `--uart-standin` it writes no
   `SYSREG` register), so a power-cycled board stays as it was. `./x hw reset` undoes what the image did.
2. Build and run on hart 0 with a time that covers the budgets (the longest poll is 5 s):

       ./x build mss_init_spike --hart e51
       ./x hw run examples/mss_init_spike/bin-e51/mss_init_spike.elf --hart 0 --secs 20 --expect 'mss_init_spike: MSS INIT OK' --expect-port 0

   The serial ports are those of `hw/lab.conf` (MMUART0 on the CP2108). The image does not clear the PLIC enables or `fcsr`,
   which `./x hw initialize` does through the debugger.
3. Expected lines on MMUART0, in this order: the three header lines (`MSS init from config/boards/icicle_es/...`, the design,
   `xml sha256 8e3f...`), `96 table entries in 5 phases, a poll that times out stops the sequence`, one line per phase
   (`phase 1 refclk ... phase 5 pll`, each with `0 poll timeout(s)`), `mtime ... then ... after 100 us by mcycle: advancing`,
   `MSS PLL: PLL_CTRL 0x........, LOCK 1`, `96 of 96 entries run, 0 poll timeout(s)` on rev C or later silicon (93 of 96 on an earlier one: the
   second lane reset is skipped, as under QEMU), and `MSS INIT OK`. The `mtime` of phases 1 to 3 is probably still 0 (a
   guess from `hw/README.md`: `mtime` counts after the sixth write of the minimal sequence, which here is the `CLK_CNTL` write in phase 4);
   the value after phase 4 and the two reads at the end show whether it counts (1.003 MHz was measured with `./x hw initialize`). Entry numbers are those of
   the table (`src/generated/mpfs_init_table.ads`, the comment at each entry).
4. If MSS init fails: the image prints `TIMEOUT entry N: <what>, <address> and <mask> is <value>, wanted <value>` for the first
   poll that ran out of time and ends with `MSS INIT FAILED`, without the later phases; the PLL line is still printed. Look at that
   entry in the table and at the phase before it: `PVT_STAT` (entries 52 and 62 of the table: the IO power detectors, the
   calibration), `PLL_CNTL` and `RECAL_CNTL` (entries 67 and 68: SGMII PLL and DLL lock), `PLL_CTRL` (entry 96: MSS PLL lock). If nothing is printed at
   all the console is the problem and not the sequence (compare with `./x hw run bare_hello`). If the lines stop after a phase,
   the next phase is the one that broke the UART or the bus: the IO phase changes the IO mux, and the console pins are
   among them. A hung debug module needs `./x hw reset` or a power cycle.
5. Compare with the oracle: `./x hw initialize --dry-run --xml config/boards/icicle_es/ICICLE_MSS_mss_cfg.xml` lists the steps
   that `./x hw initialize` would write; after a run of the image, `./x hw initialize` on a second power-cycled board and a read
   of the registers it wrote (`./x svd probe`) should give the same values as after the image, and the writes of the image
   equal those of `--dry-run` in the order and the values (what the test shows under QEMU, 83 of them). The writes that
   differ by design: the PLIC enables and `fcsr`, which only `./x hw initialize` clears.

## Not verified

- Nothing on a board. That the image's UART output survives the IO mux phase, that the polls pass in the 2 s and 5 s of the
  Python steps when the timing is `mcycle` at 80 MHz and not the host's clock (and that the two debugger round trips of
  OpenOCD that `./x hw initialize` has between writes are not what lets a register settle), that `mtime` counts afterwards, and
  that the MSS PLL locks.
- The cycle count as a time base is the measured 80 MHz of the boot clock (`hw/README.md`, `CLAUDE.md`); it was not measured by
  this image.
- The second lane reset of rev C silicon (`Skip_If_Clear` on `SPARE_STAT` bit 31) runs only on a part that reads that bit as 1;
  QEMU reads 0, so the comparison does not show those three entries.
- The XML of `config/boards/icicle` and `video_kit`: the table is made for them by the same generator, but only `icicle_es` is
  committed and compared.
- A mid-sequence read-modify-write of a register that QEMU does not model (`SUBBLK_CLOCK_CR`, `SOFT_RESET_CR`, `IOC_REG0`, `PVT_STAT`
  on the board) writes what the board returns; the test only shows that the image writes `(read or set) and not clear` of the
  word it read.
