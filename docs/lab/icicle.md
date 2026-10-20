<!--
SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
SPDX-License-Identifier: CC-BY-4.0
-->
# Icicle Kit inventory

A template for the person who owns an Icicle Kit (Microchip PolarFire SoC, board `MPFS250T_ES`) and wants
to use it with this repository. Fill in the fields marked **FILL IN** for your board and keep the page with
the board. A value marked *to verify on the board* is an expectation that nobody has confirmed; replace it
by what you measure. Where a value comes from is listed at the end.

## The board

| Field | Value |
|---|---|
| Board | Icicle Kit, `MPFS250T_ES` (the die name that `hw/lab.conf.example` has for the boot mode programmer) |
| Serial number / label | **FILL IN** |
| JTAG IDCODE | **FILL IN** (read with OpenOCD at start-up). The value `0x0F81A1CF` was read from a board; compare yours with it, a different value may mean a different silicon revision (to verify on the board) |
| Silicon | **FILL IN**: engineering sample (`_ES`) or production. Icicle Kits mostly carry engineering samples; series silicon needs another die name for `./x hw bootmode` (`BOOTMODE_DIE` in `hw/lab.conf`) |
| Version of the factory reference design | **FILL IN** before it is replaced: read it from the label or release notes of the kit and from the design information that FlashPro Express or Libero shows for the device. Keep the bitstream (`.job`) file of the factory design: it is what "Restoring the factory state" needs |
| Boot mode | **FILL IN**: the mode the board is in when you receive it, and the mode it is in now (0..3). Boot mode 0 is the mode in which all measurements of `hw/README.md` were made |
| Serial ports | The CP2108 USB-to-UART bridge shows four interfaces. Interface `if00`..`if03` are MMUART0..MMUART3 (`/dev/serial/by-id/usb-Silicon_Labs_CP2108_*-if0<n>-port0`). *To verify on the board*: print a message on one MMUART and see which interface shows it, then set `UART_PATTERN` in `hw/lab.conf` if it differs |
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

## Restoring the factory state

"Factory state" is the factory reference design in the FPGA part and the boot mode the board was delivered
in, both of which you recorded above. The steps are the usual ones of the tools; the exact menu names
depend on your version and are to verify on the board. Not run on a board by the author of this page.

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
   and read the IDCODE and the PC again. In boot mode 0 the PC of the E51 after power-on is expected to be
   `0x2000312E`, the boot stub (to verify on the board). Enter the result in "Changes made to the board".

## Where the values come from

| Statement | Source |
|---|---|
| `MPFS250T_ES`, `FCVG484`, engineering samples, the jar, `fpgenprog`, permanent change | `hw/lab.conf.example`, `hw/bootmode.py`, `hw/README.md` section "Boot mode" (the facts about the jar were stated by the project owner; not run on a board by the author of this change) |
| IDCODE `0x0F81A1CF` read from a board | stated by the project owner; not recorded in another file of the repository |
| CP2108 interfaces `if00`..`if03` as MMUART0..3 | `hw/lab.conf` (`UART_PATTERN` and its comment); to verify on the board |
| SoftConsole v2022.2, OpenOCD of SoftConsole, FlashPro6 | `hw/lab.conf`, `hw/start_openocd.sh` |
| Boot mode 0 for the measurements; `./x hw reset` | `hw/README.md` |
| E51 PC `0x2000312E` in boot mode 0 | stated by the project owner; not recorded in `hw/README.md`; to verify on the board |
| FlashPro Express, Libero, Program_Debug, udev rules | general knowledge of the tools, not from the repository; to verify on the board |
