<!--
SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
SPDX-License-Identifier: CC-BY-4.0
-->
# Icicle Kit inventory

A template for the person who owns an Icicle Kit (Microchip PolarFire SoC, board `MPFS250T_ES`) and wants
to use it with this repository. The project does not need an exact inventory: fill in the fields marked **FILL IN** as far as they help
you to restore the board, and keep the page with the board. A value marked *to verify on the board* is an expectation that nobody has confirmed; replace it
by what you measure. Where a value comes from is listed at the end.

## The board

| Field | Value |
|---|---|
| Board | Icicle Kit, `MPFS250T_ES` (the die name that `hw/lab.conf.example` has for the boot mode programmer) |
| Serial number / label | **FILL IN** |
| JTAG IDCODE | **FILL IN** (read with OpenOCD at start-up). The value `0x0F81A1CF` was read from a board; compare yours with it, a different value may mean a different silicon revision. OpenOCD read `0x0f81a1cf` (GateField, part `0xf81a`, version 0) on the board of the project owner (to verify on yours) |
| Silicon | **FILL IN**: engineering sample (`_ES`) or production. Icicle Kits mostly carry engineering samples; series silicon needs another die name for `./x hw bootmode` (`BOOTMODE_DIE` in `hw/lab.conf`) |
| Version of the factory reference design | **FILL IN** before it is replaced: read it from the label or release notes of the kit and from the design information that FlashPro Express or Libero shows for the device. Keep the bitstream (`.job`) file of the factory design: it is what "Restoring the factory state" needs |
| Boot mode | **FILL IN**: the mode the board is in when you receive it, and the mode it is in now (0..3). Boot mode 0 is the mode in which all measurements of `hw/README.md` were made |
| Serial ports | The CP2108 USB-to-UART bridge shows four interfaces. Interface `if00`..`if03` are MMUART0..MMUART3 (`/dev/serial/by-id/usb-Silicon_Labs_CP2108_*-if0<n>-port0`). Checked on a board by the project owner: MMUART0..3 show up on `if00`..`if03` (`./x hw run bare_hello --hart 0 --uart-standin` printed `bare hello E51 hart 0` on `if00`). On another board, print a message on one MMUART and see which interface shows it, then set `UART_PATTERN` in `hw/lab.conf` if it differs. If the board hangs on another machine, `socat` there can tunnel each UART to a TCP port, which `hw/lab.conf` names as `tcp://HOST:PORT` (`UART_PATTERN`, `UART<n>`; see "Serial ports" in [`hw/README.md`](../../hw/README.md)) |
| Date and name of whoever last changed the board | **FILL IN** |

### Changes made to the board

Every change that survives a power cycle belongs here, because the repository cannot see it: a new boot
mode (`./x hw bootmode`, which reprograms the FPGA part), a design programmed with FlashPro Express, a
jumper or a switch.

| Date | Change | By |
|---|---|---|
| | | |

## Tools and versions

| Tool | What for | Version here |
|---|---|---|
| Microchip SoftConsole | Its OpenOCD fork has the `microsemi-flashpro` interface that the distribution's OpenOCD lacks and talks to the FlashPro6 on the board (`./x hw openocd`). Its `extras/mpfs/mpfsBootmodeProgrammer.jar` switches the boot mode. The lab setup of the project was developed with v2022.2 (`SOFT_CONSOLE` in `hw/lab.conf`) | **FILL IN** |
| FlashPro Express, or Libero SoC | Programs a `.job` file (the factory design) into the FPGA part. Libero also provides `fpgenprog`, which the boot mode programmer needs (`FPGENPROG` in `hw/lab.conf`) | **FILL IN** |
| Program_Debug | Microchip's tool for programming and debugging through the board's FlashPro6 | **FILL IN** (to verify on the board whether you need it) |
| Java | Runs the boot mode programmer (`JAVA` in `hw/lab.conf`) | **FILL IN** |
| udev rules | Access to the FlashPro6 and to the CP2108 ports without root. Install the rules that come with SoftConsole or Libero (the files and their names: to verify on your installation), reload udev and re-plug the USB cable | **FILL IN**: where the rules file is |
| OpenOCD | See `docs/lab/openocd.md` | the one of SoftConsole |
| RISC-V compiler | Pinned in `tools/toolchain.env` (`./x toolchain install`) | see the file |

## What boot mode 0 leaves undone

In boot mode 0 no boot software runs, so the MSS keeps its reset state. Without `./x hw initialize` `CLINT.MTIME`
reads 0 and does not count (measured on the board of the project owner, P1.14: the counter stayed at 0 for as long as it was
watched), and the SGMII/DDR PHY registers read 0. Every image that uses `Ada.Real_Time`, `delay until` or the
`mtime` of the PAC needs it, and `tests/hw/run_matrix.sh` runs it before every cell.

    ./x hw initialize --minimal      # the six writes below: all that MTIME needs
    ./x hw initialize                # the full sequence of the first-stage boot software, without the clock switch
    ./x hw initialize --dry-run      # print the steps, write nothing (no OpenOCD needed)
    ./x hw reset                     # back to the power-on state (undoes initialize)

The full sequence is what Microchip's first-stage boot software (HSS, `mss_nwc_init`, `sgmii_setup`, `mss_pll_config`) does
to the MSS before it switches the clock (details in `hw/README.md`, "Initialize"); after it the PHY block is readable and the
MSS PLL is locked, and the CPU stays on its boot clock (80 MHz measured: 79 `mcycle` per `mtime` tick). `--minimal` does the
six writes of `mss_init.REFCLK` (also `./x svd probe --enable-clocks`), in this order:

| # | Write | Value | What for |
|---|---|---|---|
| 1 | `SYSREG.RTC_CLOCK_CR` | `0x0000007D` | RTC divisor: `PERIOD` 125 of the 125 MHz reference clock, clock still off |
| 2 | `SYSREG.RTC_CLOCK_CR` | `0x0001007D` | RTC clock on (bit 16): the 1 MHz tick that `mtime` counts |
| 3 | `IOSCBCFG.TIMER` | `0x0008A080` | timing of the accesses to the SCB bus |
| 4 | `SYSREG.DFIAPB_CR` | `0x00000001` | clock of the DFI/APB bus of the PHY block on, reset released |
| 5 | `SCB_REGS.MSSIO_CONTROL_CR` | `0x00003800` | `CORE_UP`, `FLASH_VALID`, `MSS_IO_EN` |
| 6 | `CFG_DDR_SGMII_PHY.CLK_CNTL` | `0xF00050CC` | the clock receiver of the reference: **this write starts `MTIME`** |

Measured by applying them one at a time after `./x hw reset` and reading `MTIME` twice, half a second apart: it stays 0 after
writes 1 to 5 and counts after write 6. Write 6 alone does nothing, and neither does it after writes 1 and 2 only: it needs 3 to 5 before it
(probably because the PHY block is not reachable until then; not measured). `MTIME` runs at 1 MHz: 997,252 ticks per second against the host clock over 20 s
(the OpenOCD round trip is within 0.3 %), so the 125 MHz reference clock and `PERIOD` 125 of `initialize` are right.

State that a `reset halt` does **not** clear, found by the hardware runs: the PLIC enables of every context (the enable words of
the S mode contexts were random), `fcsr` of the U54 and the `mtimecmp` registers (one of them read 32 after a reset). A context of
another hart that still has a source enabled takes the interrupt from the hart that runs, and an invalid `frm` in `fcsr` makes the
floating-point instructions with dynamic rounding illegal. `./x hw reset` and `./x hw initialize` therefore clear the PLIC enables of
all nine contexts and write `fcsr` = 0 on the four U54 (`hw/hart_state.py`); `run_image.py` clears the enables again before it loads
an image. `mtimecmp` is not cleared: a test that looks at it compares with the value at its start. Reads of LIM that nothing has written since power-up return random data without a trap, see
[`results/p1.md`](results/p1.md).

## Restoring the factory state

"Factory state" is the factory reference design in the FPGA part and the boot mode the board was delivered
in, both of which you recorded above. The steps are the usual ones of the tools; the exact menu names
depend on your version. The project owner restored the factory state on a board by these steps and it worked; the author of this page did not run them.

1. Get the factory design: the `.job` file of the Icicle Kit reference design that matches the version
   recorded above (from Microchip's release of that version, or from the copy you saved).
2. Connect the USB cable of the embedded FlashPro6 and power the board (which connector: see the board's
   documentation).
3. Program the `.job` file with FlashPro Express (choose the programmer, load the job, *Run*, action
   *PROGRAM*).
4. Restore the boot mode that you recorded: `./x hw bootmode N --dry-run` shows the command, `./x hw bootmode
   N` asks before it writes. The boot mode change is permanent and itself reprograms the FPGA part, so do
   it after the design is in place, or check afterwards that the design is still what you programmed.
5. Power-cycle the board.
6. Check: `./x hw openocd`, then `./x hw reset` (it must end with exit status 0 and "the hart is halted"),
   and read the IDCODE again. Read the PC of the E51 after power-on, before the reset: in boot mode 0 the hart
   waits in the boot stub (`SCB_REGS.BOOT_ROM0..7`, decoded in `docs/lab/openocd.md`), so the PC of the halted
   hart is between `0x20003120` and `0x2000312E`. Enter the result in "Changes made to the board".

## Where the values come from

| Statement | Source |
|---|---|
| `MPFS250T_ES`, `FCVG484`, engineering samples, the jar, `fpgenprog`, permanent change | `hw/lab.conf.example`, `hw/bootmode.py`, `hw/README.md` section "Boot mode" (the facts about the jar were stated by the project owner; not run on a board by the author of this change) |
| IDCODE `0x0F81A1CF` read from a board | stated by the project owner; not recorded in another file of the repository |
| CP2108 interfaces `if00`..`if03` as MMUART0..3 | `hw/lab.conf` (`UART_PATTERN` and its comment); MMUART0..3 on `if00`..`if03` checked on a board by the project owner |
| SoftConsole v2022.2, OpenOCD of SoftConsole, FlashPro6 | `hw/lab.conf`, `hw/start_openocd.sh` |
| Boot mode 0 for the measurements; `./x hw reset` | `hw/README.md` |
| E51 PC between `0x20003120` and `0x2000312E` in boot mode 0 | stated by the project owner (`0x2000312E` seen on a board; the PC can be anywhere in that range). The stub itself is decoded from the reset values of `SCB_REGS.BOOT_ROM0..7` in `svd/base/scb_regs.yaml`, see `docs/lab/openocd.md` |
| FlashPro Express, Libero, Program_Debug, udev rules | general knowledge of the tools, not from the repository; to verify on the board |
