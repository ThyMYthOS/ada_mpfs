# mss_init_spike

A spike of a bootloader that sets the MSS up itself: an Ada image for the E51 that writes the system registers of the MSS
from the MSS Configurator XML of a board (`config/boards/icicle_es`), then sends what it did on MMUART2 and, once per second, a
status line on MMUART0. It is a primary
image (`__mpfs_boot_role` = 1, no boot stage before it) that is loaded into the LIM over JTAG like the other examples. It has
not run on a board by this change: the owner ran its predecessor (one console, MMUART0 at 115200); see "Not verified".

**Scope**, which is all there is: the reference clock (the RTC divisor, the SCB access timer, the DFI/APB clock, the dynamic
enables of the PHY), the IO mux and bank set-up, the `MSSIO_CONTROL_CR` handshake, the SGMII channel set-up as far as
`hw/mss_init.py` does it (reset, calibration, PLL and DLL lock; the second lane reset of rev C silicon) and the MSS PLL up to
its lock. **No clock switch**: nothing writes `ENVM_CR`, `CLOCK_CONFIG_CR` or `MSSCLKMUX`, so the CPU and the APB clock stay
as the reset left them (80 MHz CPU, 40 MHz APB: the clock for which the divisor of 115200 baud is 22). No DDR, no partitioning, no placement in
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
  `(Kind, Register, Value, Mask, Count, text range)` and a table of the five phases (`refclk`, `io`, `mssio`, `sgmii`, `pll`).
  One step of `mss_init.py` is one entry: `Write`, `Modify` (read, set the bits of `Value`, clear those of `Mask`, write),
  `Poll` (until `word and Mask = Value`, `Count` microseconds at most) and `Wait` (`Count` microseconds). The one step that is
  a decision on a value read at run time, `IfSet` (SPARE_STAT bit 31: rev C or later silicon resets the lanes a second
  time), is a `Skip_If_Clear` entry (read the address, skip the next `Count` entries if `word and Mask` is 0) followed by the
  entries of the steps it guards. With the XML of `icicle_es` that is 96 entries for the 93 steps. Texts are ranges of one
  constant string; the table says which XML it was made from (`XML_Source`, `XML_SHA256`, `Design`).
- **Registers come from the PAC.** No register address is written in a source of the image. An entry's `Register` is
  `Peripheral.Register'Address` of an object of the register package (`libs/mpfs_pac`, `MPFS_Registers.*`: `SYSREG.IOMUX0_CR`,
  `IOSCB_PLL_MSS.PLL_CTRL`), so the compiler resolves the address and a name that the PAC does not have does not compile. The
  generated package renames the peripherals that it uses (`IOSCB_PLL_MSS : ...Peripheral renames MPFS_Registers.IOSCB_PLL_MSS.
  IOSCB_PLL_MSS_Periph;`) and the interpreter accesses the address as one 32-bit word. The alternatives were a numeric table that
  the Ada side checks against the PAC (the address of an object is not a static expression, so the check cannot be a
  `Compile_Time_Error`) and generated straight-line code (a second place for the order of the steps, which then would not be
  data); this keeps one table, typed names and the sequence in Python only. The package is `No_Elaboration_Code`: the compiler
  makes the table static data. The emitter takes the register of each address from the merged SVD (`svdread.register_map`)
  and refuses, with exit status 2 and the step named, an address that no register covers or a register that is not a plain
  32-bit one; every register that the sequence writes is in the SVD (`IOSCB_PLL_MSS`, `IOSCB_CFM_MSS`, the SGMII blocks and
  the others are generated blocks of the register map), so no SVD addition was needed. The registers that the snapshots and
  the proofs read (`SYSREG.CLOCK_CONFIG_CR`, `SCB_REGS.MSSIO_CONTROL_CR`, `CLINT.MTIME`, the MMUART0 registers) are named in
  the sources the same way.
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
  `./x build`, `./x test examples`, `./x metrics` and `./x repro` cover it without a build script of its own. It has no row in
  `tests/qemu/tests.list`: the runner wants every port but the one of the row silent, and this image writes the status lines on
  MMUART0 while the log is on MMUART2; `tests/host/mss_init_spike` reads each port instead. It is linked with the `light-tasking` runtime (see "The log and the sink" for why).

## The log, the console and the status port

On the Icicle Kit the UART prints only while MSSIO is enabled (`SCB_REGS.MSSIO_CONTROL_CR.MSS_IO_EN`, which `./x hw initialize
--minimal` writes as 0x3800; the IO mux is not needed there, its reset default routes the MMUARTs, but on another board the IO
mux and bank set-up of its XML must be in place first). The handshake of the sequence itself writes `MSSIO_CONTROL_CR` 0x0F00,
0x0800, 0x1800, 0x3800: `MSS_IO_EN` is clear for at least 3 ms, and anything sent while the IO banks are configured is lost or
garbled. So the image **sends nothing to any UART until the hardware is configured**: everything it reports goes into a log in
RAM, and the console is opened after the last phase (also after a stop at a poll that timed out, so that the log of a failing run
is visible). The output therefore appears all at once at the end of the run, not while it runs.

Two ports, both driven by the image's own small driver (`uart`, typed registers of the PAC; the runtime's console is not used,
so the `__mpfs_console_*` link symbols play no part and `example.conf` says `CONSOLE=none`):

- **MMUART2 is the console, 115200 baud**: the log (all phases, snapshots, the verdict) goes out there, driven by the interrupt
  "transmit holding register empty".
- **MMUART0 is a write-only status port, 230400 baud**, with blocking writes (wait for `LSR.THRE` before each byte, 50 ms per
  byte at most, so that a dead port cannot hang the image; no receive, no interrupt). Nothing is written to it before the
  verdict is out on MMUART2. Then, if the sequence ended well and `mtime` advanced in the proof that the image makes (otherwise
  the log says so and there is no loop), the main program writes one line per second:
  `tick N: mtime 0x........ PLL_CTRL 0x........ LOCK b fabric: ...` (`N` counts up; `mtime` and `PLL_CTRL` are read through the PAC), which
  shows on the board that `mtime` counts and the MSS PLL stays locked, and what the fabric has interrupted (next section). After a stop at a poll (`MSS INIT FAILED`) there is no loop.
  The board main loops forever; the QEMU main (`mss_init_spike_qemu`) writes 3 lines at a period of 50 ms
  (`Tick_Count` and `Period_Ms`, constants of that main) so that the test ends.
- **The period** is one of `delay until` on `Ada.Real_Time` (the next time is the last plus the period): the relative `delay` is
  not in the profile (Ravenscar and Jorvik restrict it), and `delay until` has no drift. The tickless timer of the runtime needs
  `mtime` to count, which the reference-clock steps of the sequence start; this is why the loop is only entered after the proof
  that it advances.
- **Divisors**: integer, `Divisor_For (Clock, Baud) = (Clock + 8 * Baud) / (16 * Baud)` in one place of `uart.ads`, with two named
  constants for the APB clock of the boot configuration (`APB_Clock_Hz` = 40 MHz: the CPU runs at 80 MHz, AHB and APB at half) and the
  rate: 22 for 115200 and 11 for 230400, both **1.36 % below** the nominal rate (40 MHz / (16 * 22) = 113636 baud, 40 MHz / (16 * 11)
  = 227273 baud), well inside what a UART takes. The fractional baud rate of the MMUART (`DFR`, `MM0.EFBR`; the runtime uses it
  for a console that needs it) would give 10 + 54/64 for 230400 (0.064 % error); it is **not used**, because it has been tried only
  under QEMU and not on the board. A limit: the clock is that of the boot configuration and is not read from the XML, so the
  divisors are right as long as the CPU stays on the boot clock (this image never switches it).

| Unit | What it does |
|---|---|
| `mss_init` | The interpreter of the table, one phase at a time; time in cycles of the hart. |
| `log` | The ring buffer (`Ring_Size.Size` bytes, a power of two, 4096; `src/ring/ring_size.ads`, another directory with `MSS_INIT_RING_DIR`): a single-producer single-consumer ring with atomic indices, no protected object. `Put` never blocks and touches no hardware; when the ring is full the rest of the message is dropped and counted (`Dropped`), and the end of the run says `N bytes dropped`. |
| `uart` | The driver of a port (`MMUART0` or `MMUART2`) at a baud rate: SYSREG clock and then reset, `LCR.DLAB`, the divisor latches, 8N1, FIFOs (the order of the runtime's console), `Tx_Ready`, `Tx_Empty`, `Write`, the transmit interrupt enable, `Read_State`. Typed PAC registers, no raw address. |
| `sink` | The console on MMUART2, driven by the interrupt "transmit holding register empty" (IER.ETBEI): a plain procedure attached with `System.BB.Interrupts.Attach_Handler` to the source `Ada.Interrupts.Names.MMUART2` (PLIC priority 3), no task and no protected object. It moves up to 16 bytes (the FIFO depth) from the log into THR per interrupt and disables the interrupt when the log is empty. `Open` brings the port up, attaches the handler and enables the interrupt; `Flush` waits until the log is empty and `LSR.TEMT` is set, within a budget; `Kick` (after each `Put`) enables the interrupt again. |
| `ticker` | MMUART0: `Open` (bring-up at 230400) and `Put_Tick` (the status line with the fabric table, blocking writes). |
| `fabric` | The fabric interrupts: attach, count, mask, describe. |
| `fabric_seam` | A test seam of the QEMU image only (see "Fabric interrupts"). |
| `console` | `Put` and friends: into the log, then `Kick` (which does nothing while the sink is closed). |
| `spike` | The flow of both images: banner, the phases with a snapshot each, the proofs, then `Open`, `Flush`, the state of MMUART2, the summary, the log line and the verdict, then the status loop. |
| `mss_init_spike`, `mss_init_spike_qemu` | The mains: the board image (a timeout stops the sequence, 1 s period without end) and the QEMU image (it goes on, 3 lines at 50 ms). |

**The gate.** Before `Open` nothing is written to MMUART2 or MMUART0 at all (no data, no IER, no divisor, no LCR, no read, and not
the SYSREG clock and reset of a port either): the bring-up of a port is the first thing the image does with it, after the last
write of the table; MMUART0 comes up after the log has been sent. The PLIC source is not set up before `Open` either (`Open`
attaches the handler), and the device raises no interrupt while its IER is clear.

**The ring and the handler on one hart, without protected objects.** `Head` is written by the producer (the main program) only
and `Tail` by the consumer (the handler) only, both atomic, counting bytes modulo 2**32 with a ring size that is a power of two;
the data is volatile. The producer stores the bytes and then publishes them by writing `Head`; the handler reads `Head`, then the
byte, then writes `Tail`. A hart sees its own accesses in program order, also in a handler that interrupts it, so the handler never
sees a `Head` whose bytes are not stored, and the producer reads `Tail` before it reuses a place (a stale `Tail` only makes the
ring look fuller). The handler runs to its end between two instructions of the producer and the producer does not run meanwhile.
The wake-up: the producer enables the interrupt only after it has stored and published (`Console.Put`: `Log.Put`, then `Sink.Kick`);
the handler disables it only when it has just seen the log empty. If the handler runs before the publication it finds the log empty
and disables the interrupt, and the `Kick` that follows enables it again; if it runs after, it sends the bytes, and a later `Kick`
at worst causes one more interrupt in which it finds nothing. So no byte stays in the log with the interrupt disabled. This holds on
one hart (two harts would need fences).

**Why `light-tasking`.** The `light` runtime has no interrupt handlers (`crates/mpfs_rts/README.md`): no `System.BB.Interrupts`
(it has no trap handler of its own, only the trap stub of `start.S`). `light-tasking` is the lowest profile that has it, and it
is still the lowest one that can do this (it is the profile of `interrupt_test`); the environment task runs the main, there is no
other task and no protected object. `Ada.Interrupts.Names` is used for the source number only. The cost is in `metrics.golden`.

**Snapshots.** After each phase the log gets `snapshot N CLOCK_CONFIG_CR ... MSSIO_CONTROL_CR ... SUBBLK_CLOCK_CR ...
SOFT_RESET_CR ..., mcycle/mtime R (dcycles / dmtime)`: the clock configuration (it must stay as it was: no clock switch), whether
`MSS_IO_EN` (bit 13 of 0x3800: 0x2000) is set, which peripherals have their clock and are out of reset (MMUART0 is bit 5, MMUART2
bit 7), and the ratio of `mcycle` to `mtime` over 200 microseconds (80 for a CPU of 80 MHz and an `mtime` of 1 MHz; `mtime stopped`
if it does not count; meaningless under QEMU). The registers of a port are not read before it is up, because it has no clock
before its bring-up and a read from it could hang the bus; after the log has been sent the line `MMUART2 LCR .. MCR .. DLR .. DMR ..`
shows the state of the console (`LCR` 0x03 = 8N1, `DLR` 0x16 = 22 and `DMR` 0 for the divisor 22).

## Fabric interrupts

The status lines on MMUART0 carry every interrupt that has come from the FPGA fabric. The sources are the PLIC sources
`F2M_0` to `F2M_63`, IDs 118 to 181 ("fabric to MSS", `svd/additions/interrupts.yaml`, `Ada.Interrupts.Names` of the runtime);
there is no `F2H_*` and no other source in that range (117 has none). Not in it: the MSS peripherals' own sources, the bus error
units, and the GPIO direct lines 13 to 50, which `SYSREG.GPIO_INTERRUPT_FAB_CR` switches between the pads and the fabric.
The owner measured after some power-ups that source 119 (`F2M_1`) is pending at reset (`svd/additions/plic.yaml`).

- **One handler** (`fabric.adb`): a plain procedure `Fabric_Interrupt (Id)` attached with `System.BB.Interrupts.Attach_Handler`
  to every source of the range at `Interrupt_Priority'First`, which the runtime maps to PLIC level 1 (the lowest that interrupts).
  It counts per source in a table of atomic counters, remembers the `mtime` of the first occurrence, and then **masks the source**
  in the PLIC: it clears the enable bit of the source for hart 0, machine mode, in the PAC's PLIC registers
  (`PLIC_Periph.ENABLE_H0_M`, typed). The runtime has no public "disable" (`System.BB.RISCV_PLIC` has `Enable` only), and a
  priority of 0, which would also silence a source, cannot be given through `Attach_Handler`. The mask is one-shot and the source
  stays masked: a level-sensitive line that stays asserted would fire again after every claim and complete, so without it a stuck
  line would be an interrupt storm. Every source that fired is reported once, with its count at the time of masking (1, or more if
  the runtime delivered a second one before the mask took effect), and shown `masked`.
- **When**: the sources are attached right after the console sink is opened, after the last table write, not during the
  sequence: the gate idea is that nothing from outside may disturb the sequence (no PLIC priority and no enable bit are written
  before the last table write; the test checks it). An interrupt that is pending at that moment fires right after the attach
  and is logged like any other; that would be a finding (for example source 119 after some power-ups).
- **No SYSREG register** is written for the fabric lines to arrive: the F2M sources reach the PLIC by default. `FAB_INTEN_U54_n`
  and `FAB_INTEN_MISC` route fabric lines and the Ethernet MACs to the local interrupts of the U54 harts directly, and
  `GPIO_INTERRUPT_FAB_CR` the GPIO lines; the image uses none of them, and `hw/mss_init.py` and the XML do not write them. Whether a
  design needs any of them for its lines is not known here.
- **Output**: `tick N: mtime ... PLL_CTRL ... LOCK 1 fabric: none` as long as nothing came, then the sources in ascending order,
  each `F2M_<n>(<id>) x<count> @0x<mtime of the first occurrence> masked`, two to a line; more sources go on continuation lines
  that start with the same `tick N: fabric:`. Every source that has occurred appears in every following tick line. The console log
  has, once before the verdict, `fabric interrupts before the loop: none` or `119 x1, 123 x2`, so the first occurrence is not lost if
  only the console is watched. The board main loops forever, so the table keeps being shown.
- **QEMU has no fabric lines** and no way to raise one: the SiFive PLIC model refuses a write to a pending register (`sifive_plic_write:
  invalid pending write`, tried), and the machine has no input for them. The 16550's own interrupt works because the model
  drives it. The logic is covered with a test seam: the QEMU main passes `Fabric_Seam.Before_Tick`, which in tick 2 calls the code
  that the handler runs (`Fabric.Record_Occurrence`) for `F2M_1` twice (the second as if the runtime had delivered it before the
  mask took effect) and `F2M_5` once. The board main has no seam. The real path from the fabric (the line, the PLIC, the trap, the
  handler) is **not exercised** by any test.

## Build, regenerate, run under QEMU

    ./x build mss_init_spike --hart e51                # bin-e51/mss_init_spike.elf and mss_init_spike_qemu.elf
    python3 config/gen/mss_init_table.py --xml config/boards/icicle_es/ICICLE_MSS_mss_cfg.xml           # rewrite the table
    python3 config/gen/mss_init_table.py --xml config/boards/icicle_es/ICICLE_MSS_mss_cfg.xml --check   # is it current
    ./x qemu mss_init_spike                            # first image: the board image, which stops at the first timeout
                                                       # (the console is MMUART2: ./x qemu shows MMUART0 on stdio, so
                                                       # use tests/host/mss_init_spike/run.sh, which reads each port)
    bash tests/host/mss_init_spike/run.sh              # the comparison with the sequence of hw/mss_init.py

The table needs the merged SVD (`./x svd merge`, which `tools/svd.py ensure` makes current), because the reader checks the XML
against it. For another board see "Your own XML".

Under QEMU the console, MMUART2, shows (the numbers are those of a run on QEMU 10.2.1):

    mss_init_spike_qemu: MSS init from config/boards/icicle_es/ICICLE_MSS_mss_cfg.xml
    mss_init_spike_qemu: design ICICLE_MSS, Libero 2022.2, part MPFS250T_ES, format 0.6.5
    mss_init_spike_qemu: xml sha256 8e3f849a7dbc904023f5f3c50f7d867249d2e092b29a0b0a80540e184faaa4ad
    mss_init_spike_qemu: 96 table entries in 5 phases, a poll that times out is reported and the sequence goes on
    mss_init_spike_qemu: phase 1 refclk: entries 1-6, 6 run, 0 poll timeout(s), mtime 0x00004e4c
    mss_init_spike_qemu: snapshot 1 CLOCK_CONFIG_CR 0x00000000 MSSIO_CONTROL_CR 0x00000000 SUBBLK_CLOCK_CR 0x00000000 SOFT_RESET_CR 0x00000000, mcycle/mtime ...
    ...
    mss_init_spike_qemu: phase 4 sgmii: entries 42-76, 32 run, 2 poll timeout(s), mtime 0x0002c935
    mss_init_spike_qemu: TIMEOUT entry 67: PLL_CNTL: SGMII PLL locked, 0x20007c08 and 0x00000080 is 0x00000000, wanted 0x00000080
    mss_init_spike_qemu: TIMEOUT entry 68: RECAL_CNTL: DLL locked, 0x20007c14 and 0x00800000 is 0x00000000, wanted 0x00800000
    mss_init_spike_qemu: snapshot 4 ...
    mss_init_spike_qemu: phase 5 pll: entries 77-96, 20 run, 0 poll timeout(s), mtime 0x0002f846
    mss_init_spike_qemu: snapshot 5 ...
    mss_init_spike_qemu: mtime 0x00030e28 then 0x00030e3b after 100 us by mcycle: advancing
    mss_init_spike_qemu: MSS PLL: PLL_CTRL 0x02000000, LOCK 1
    mss_init_spike_qemu: MMUART2 LCR 0x00000003 MCR 0x00000008 DLR 0x00000016 DMR 0x00000000
    mss_init_spike_qemu: 93 of 96 entries run, 2 poll timeout(s)
    mss_init_spike_qemu: log: 2271 bytes through the ring, 0 dropped, 229 sink interrupt(s)
    mss_init_spike_qemu: fabric interrupts before the loop: none
    mss_init_spike_qemu: status line on MMUART0 (230400 baud) every 50 ms
    mss_init_spike_qemu: MSS INIT DONE WITH TIMEOUTS

On MMUART2 (the console); MMUART0 then shows

    tick 1: mtime 0x0004ccd1 PLL_CTRL 0x02000000 LOCK 1 fabric: none
    tick 2: mtime 0x00059072 PLL_CTRL 0x02000000 LOCK 1 fabric: F2M_1(119) x2 @0x00058fe8 masked, F2M_5(123) x1 @0x00059068 masked
    tick 3: mtime 0x0006525c PLL_CTRL 0x02000000 LOCK 1 fabric: F2M_1(119) x2 @0x00058fe8 masked, F2M_5(123) x1 @0x00059068 masked

The `log:` line counts the bytes that went through the ring before it, which the test compares with the bytes that arrived;
QEMU's 16550 raises the interrupt "transmit holding register empty" and it reaches the PLIC of the machine
`microchip-icicle-kit`, so the QEMU image sends by interrupt like the board image. The QEMU model ignores the divisor, so the
divisors are checked as register contents.

QEMU models some of the registers (the PHY's `PVT_STAT`, `PLL_CTRL` of the MSS PLL) and reads 0 from the others, so two polls
time out and the PLL lock bit reads 1 whatever was written. "mtime advances" and "LOCK 1" prove nothing under QEMU: they are
for the board.

## Your own XML

**Where an XML comes from.** The MSS Configurator of Libero SoC writes `<design>_mss_cfg.xml` (formats 0.6.5 and 0.6.8 are
read). `config/boards/` has three: `icicle_es` (the one that the committed table and the test use), `icicle` (Libero 2024.2,
a different pin assignment) and `video_kit`. The reader refuses a DTD or entities and checks every value against the merged SVD.

**Check it** before building:

    python3 config/gen/mpfs_gen xml --check FILE      # FILE: ok, or one line per violated rule (GEN-Exxx)
    python3 config/gen/mpfs_gen xml FILE              # the registers of the core sections
    ./x hw initialize --dry-run --xml FILE            # the steps that the table will have, with their values

**Build against it.** The key `MSS_XML=` of `example.conf` (a path relative to the repository root, or absolute; empty in
the committed file) or the environment variable of the same name, which wins:

    MSS_XML=config/boards/icicle/ICICLE_MSS_mss_cfg.xml ./x build mss_init_spike --hart e51

`./x build` then runs `config/gen/mss_init_table.py` on that XML into `build/mss-init/mss_init_spike-e51/` (not into the
source tree) and the project takes the table from there (`MSS_INIT_TABLE_DIR`). `MSS_INIT_OPTS=` (`example.conf` or
environment) passes options to the emitter, for example `--skip-io`; it needs an XML. An XML that the reader rejects stops the
build with exit status 2 and the lines of the reader (`FILE: GEN-Exxx PATH: message`), and no image is built. Without an XML the
committed table (`src/generated/mpfs_init_table.ads`, made from `icicle_es`) is linked, so the default image is the one of
`metrics.golden`; with the XML of `icicle_es` the generated table is the same text, but the ELF differs in the debug path of
the table. `MSS_XML` of `hw/lab.conf` (the board for `./x hw initialize`) is not read by the build; when it names another
file than the one the table is made from, or the build takes the committed table, `./x build` prints
`x: warning: MSS_XML of hw/lab.conf names ...` and goes on. A table of your own without `./x build`:

    python3 config/gen/mss_init_table.py --xml FILE --output DIR/mpfs_init_table.ads
    MSS_INIT_TABLE_DIR=DIR ./x build mss_init_spike --hart e51

**What comes from where.** Only the values come from the XML: the RTC period, the IO mux and bank set-up, the SGMII channel
registers, the MSS PLL and its multiplexers. The order of the steps, the read-modify-writes, the polls with their masks and
timeouts, the delays, the decision on the silicon revision, the values that no XML has (SCB access timer, `DFIAPB_CR`, the
MSSIO handshake, the soft resets) and the off mode of a design without an SGMII channel (`mss_init.py` builds that table
shorter, without the wait for the SGMII PLL) stay in `hw/mss_init.py`.

**What shows which XML ran.** The first lines of the console are `MSS init from <XML>`, the design and `xml sha256 <hash>`.

**Compare by hand.** The writes of the image must be the lines `mww` of `./x hw initialize --dry-run --xml FILE`, in that order
(the Modify steps write what they read). Under QEMU: `qemu-system-riscv64 -M microchip-icicle-kit -smp 5 -m 2G -display none
-bios none -kernel bin-e51/mss_init_spike_qemu.elf -serial file:s0 -serial null -serial null -serial null -serial null
-trace memory_region_ops_write -D trace.log`, then `python3 tests/host/mss_init_spike/compare_trace.py` on a trace taken with
both `-trace memory_region_ops_read` and `_write` and `--xml FILE` does the comparison.

## The test

The comparison with the QEMU trace is bound to the committed table, so to `icicle_es`; the suite also builds the image
of `config/boards/icicle` through `MSS_XML` and compares its trace with the sequence of that XML (the same 83 writes of 93 steps).

`tests/host/mss_init_spike/run.sh` boots the QEMU image with `-trace memory_region_ops_read/write` (QEMU traces the accesses
to the MSS registers by the name of the device: `mchp.pfsoc.sysreg`, `.ddr_sgmii_phy`, `.ioscb.pll_mss` ...; no change of QEMU
is needed) and `compare_trace.py` runs the steps of `mss_init.full(values)` of the same XML through `mss_init.run()` with a
write function that takes the next write of the trace, and compares address, value and width. A Modify writes what the image
read: the read function gives the word that the trace shows (QEMU reads 0 from most registers and 0x4040 from `PVT_STAT`), so
the write must be `(read or set) and not clear`. A poll and the decision on the silicon revision need a read of their register
in the trace. The comparison covers every write of the image except those to its two ports, the PLIC and the CLINT: the
sequence and the four SYSREG writes that bring the ports up (MMUART2, then MMUART0) are all the image writes, and a write that
is not in them fails. The gate: no access to MMUART0 or MMUART2 may come before the bring-up of MMUART2, which is after the last
write of the table, and none to MMUART0 before the last byte of the log has been written to MMUART2; the ports are written at the
16550 offsets of the driver only (no fractional baud rate register), the divisor latches are 22 (MMUART2) and 11 (MMUART0) with DMR 0,
and MMUART0 gets no IER write (it is driven by polling). With the XML of `icicle_es` 83 writes equal the sequence of 93 steps
(4 Modify steps, 1 IfSet, 5 polls, of which 2 are not met by what QEMU reads).

`check_console.py` checks the console: the bytes that arrived before the `log:` line are the bytes the line says went through the
ring, the lines are all there in the order of the run, the verdict is last, the sink sent by interrupt (`sink interrupt(s)` above
0). On MMUART0 `check_console.py` finds the three status lines with `N` = 1, 2, 3 and growing `mtime` after the log, and nothing
after a stop at a poll. The same for the board image
after its stop at the first poll that timed out (`MSS INIT FAILED` last, the TIMEOUT line and the phases before it in the log), and
for an image with a ring of 512 bytes (`MSS_INIT_RING_DIR`), where the dropped bytes are counted and the line `N bytes dropped`
says the number that the `log:` line has.

Negative controls: the image built from a table with one value flipped (`--tamper-write 10`, built with
`MSS_INIT_TABLE_DIR`) fails at the 11th write, `SYSREG.IOMUX4_CR`: wanted `0x88CC4444`, wrote `0x88CC4445`; the trace of the real
image fails against the XML of `config/boards/icicle` (write 7, `IOMUX0_CR`), against the sequence without the IO set-up
and with one write left out of the trace; a byte written to MMUART0, and an interrupt enable of it, inserted into the trace during the
sequence fail the gate, and so do a byte on MMUART2, the clock of a port, a byte on MMUART0 before the last log byte, a wrong divisor,
an IER write to MMUART0 and a write to the fractional baud rate register. The board image under QEMU stops at the first poll that times out and ends with
`MSS INIT FAILED`. The generator cases check that the committed table is current, that the output is the same twice, that the
entries of the table are the steps of `mss_init.full()` and that the register each one names is the register of the merged SVD at the
address of the step, and that a step on an address with no register is refused (exit status 2).

## On the Icicle Kit

What to do (nothing here has been run on a board):

1. Power-cycle the board, boot mode 0 (the harts idle, no HSS: `./x hw bootmode 0`), OpenOCD running (`./x hw openocd`). Do
   **not** run `./x hw initialize` first: the image sets the MSS up itself, and a second set-up of the SGMII block on top of the
   first would hide a failure of this one. `./x hw run` does not reset the board and does not touch the MSS (it clears the PLIC
   enables, halts the hart, loads the ELF into the LIM and resumes it; without `--uart-clocks` and `--uart-standin` it writes no
   `SYSREG` register), so a power-cycled board stays as it was. `./x hw reset` undoes what the image did.
2. Build and run on hart 0 with a time that covers the budgets (the longest poll is 5 s); the console is MMUART2, so
   `--expect-port 2`, and the status lines of MMUART0 need 230400 baud on the host side (`--baud 0=230400`, or `UART0_BAUD=230400`
   in `hw/lab.conf`; the default stays 115200 for every port):

       ./x build mss_init_spike --hart e51
       ./x hw run examples/mss_init_spike/bin-e51/mss_init_spike.elf --hart 0 --secs 20 --expect 'mss_init_spike: MSS INIT OK' --expect-port 2 --baud 0=230400

   `UART_COUNT` of `hw/lab.conf` must be at least 3 so that MMUART2 is read (`--view blocks` or `live` shows MMUART0 to MMUART2). The
   serial ports are those of `hw/lab.conf` (MMUART0 to MMUART3 on the CP2108). The image does not clear the PLIC enables or `fcsr`,
   which `./x hw initialize` does through the debugger. The tick lines never end on the board: `--secs` ends the run, and the image
   goes on until it is reset.
3. The output appears all at once at the end of the run (the log is sent after the last phase, 2 to 3 KB at 115200 baud: about
   0.3 s), and for a run that stops at a poll after at most the time of that poll (2 s, 5 s for the PLL lock). Expected lines on
   MMUART2, in this order: the three header lines (`MSS init from config/boards/icicle_es/...`, the design,
   `xml sha256 8e3f...`), `96 table entries in 5 phases, a poll that times out stops the sequence`, one line per phase
   (`phase 1 refclk ... phase 5 pll`, each with `0 poll timeout(s)`), `mtime ... then ... after 100 us by mcycle: advancing`,
   `MSS PLL: PLL_CTRL 0x........, LOCK 1`, `MMUART2 LCR 0x00000003 ... DLR 0x00000016 DMR 0x00000000`, `96 of 96 entries run, 0 poll timeout(s)`, `log: N bytes through the ring, 0 dropped, I sink interrupt(s)` (I above 0), `fabric interrupts before the loop: ...`, `status line on MMUART0 (230400 baud) every 1000 ms` (96 of 96 entries run on rev C or later silicon or later silicon, 93 of 96 on an earlier one: the
   second lane reset is skipped, as under QEMU), and `MSS INIT OK`. Then, on MMUART0 at 230400 baud, once per second
   `tick 1: mtime 0x........ PLL_CTRL 0x........ LOCK 1 fabric: none`, `tick 2: ...`: `mtime` grows by about 1000000 per line (1 MHz), `LOCK` stays 1, and the fabric part shows `none` or the sources that fired (see "Fabric interrupts"). On the console, `fabric interrupts before the loop: none` or e.g. `119 x1` precedes the verdict. At
   the wrong baud rate (a terminal at 115200) the lines are garbage or short runs of odd characters; at 230400 on a console that
   is MMUART2 (115200) it is garbage the same way. The `mtime` of phases 1 to 3 is probably still 0 (a
   guess from `hw/README.md`: `mtime` counts after the sixth write of the minimal sequence, which here is the `CLK_CNTL` write in phase 4);
   the `snapshot` lines (after each phase `mcycle/mtime` is about 80 if it counts, `mtime stopped` if not), the value after phase 4 and the two reads at the end show whether it counts (1.003 MHz was measured with `./x hw initialize`). Entry numbers are those of
   the table (`src/generated/mpfs_init_table.ads`, the comment at each entry).
4. If MSS init fails: the image prints `TIMEOUT entry N: <what>, <address> and <mask> is <value>, wanted <value>` for the first
   poll that ran out of time and ends with `MSS INIT FAILED`, without the later phases; the PLL line is still printed. Look at that
   entry in the table and at the phase before it: `PVT_STAT` (entries 52 and 62 of the table: the IO power detectors, the
   calibration), `PLL_CNTL` and `RECAL_CNTL` (entries 67 and 68: SGMII PLL and DLL lock), `PLL_CTRL` (entry 96: MSS PLL lock). If nothing is printed at
   all, the console is the problem and not the sequence: look at the `MMUART2` line and the snapshots if any arrive, and compare with `./x hw run examples/textio_test/bin-e51/textio_test.elf --hart 0` (which prints correctly after a full run). If the output is
   garbled although `textio_test` prints correctly, the divisor and the clock are fine and the IO banks or `MSS_IO_EN` are the
   suspects: `MSSIO_CONTROL_CR` in the last snapshot must show 0x3800 (`MSS_IO_EN` set), `CLOCK_CONFIG_CR` must be what it was at
   reset (no clock switch: if it differs, something switched the clock and the divisor 22 is wrong), and the `MMUART2` line
   must show `LCR` 0x03, `DLR` 0x16, `DMR` 0. `SUBBLK_CLOCK_CR` bit 7 and `SOFT_RESET_CR` bit 7 clear show the port has its clock and is
   out of reset. If nothing arrives at all after a run that did not stop, the sink never sent: `log:` is not there, and the
   interrupt (PLIC source of MMUART2 on hart 0) did not reach the handler; `Flush` gives up after 5 s. A hung debug module needs
   `./x hw reset` or a power cycle.
5. Compare with the oracle: `./x hw initialize --dry-run --xml config/boards/icicle_es/ICICLE_MSS_mss_cfg.xml` lists the steps
   that `./x hw initialize` would write; after a run of the image, `./x hw initialize` on a second power-cycled board and a read
   of the registers it wrote (`./x svd probe`) should give the same values as after the image, and the writes of the image
   equal those of `--dry-run` in the order and the values (what the test shows under QEMU, 83 of them). The writes that
   differ by design: the PLIC enables and `fcsr`, which only `./x hw initialize` clears.

## Not verified

- This version on a board (the owner ran its predecessor with one console on MMUART0). That the fabric interrupt path (a line from a fabric design through the PLIC, the trap and the handler, up to the mask and the report:
  only the owner's observation of source 119 pending after some power-ups exists, no design that drives the lines was run), that the sink's interrupt on MMUART2
  reaches the handler on the E51 of the board (it does under QEMU), that the output of MMUART2 and the status lines of MMUART0
  are correct on the board, that `delay until` keeps a period of 1 s there, that MMUART0 at 230400 baud (divisor 11, 1.36 % off) is
  read correctly by the host, that the fractional baud rate gives what it should (not used), that the polls pass in the 2 s and 5 s of the
  Python steps when the timing is `mcycle` at 80 MHz and not the host's clock (and that the two debugger round trips of
  OpenOCD that `./x hw initialize` has between writes are not what lets a register settle), that `mtime` counts afterwards, and
  that the MSS PLL locks.
- The cycle count as a time base is the measured 80 MHz of the boot clock (`hw/README.md`, `CLAUDE.md`); it was not measured by
  this image.
- The second lane reset of rev C silicon (`Skip_If_Clear` on `SPARE_STAT` bit 31) runs only on a part that reads that bit as 1;
  QEMU reads 0, so the comparison does not show those three entries.
- The XML of `video_kit`: the table is made by the same generator but not built or compared; `icicle_es` is the committed
  table and `icicle` is built and compared under QEMU by the test, neither on a board.
- A mid-sequence read-modify-write of a register that QEMU does not model (`SUBBLK_CLOCK_CR`, `SOFT_RESET_CR`, `IOC_REG0`, `PVT_STAT`
  on the board) writes what the board returns; the test only shows that the image writes `(read or set) and not clear` of the
  word it read.
