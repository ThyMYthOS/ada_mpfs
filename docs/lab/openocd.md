<!--
SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
SPDX-License-Identifier: CC-BY-4.0
-->
# Access to the board through OpenOCD

Everything the host tools do with the board goes through Microchip's OpenOCD. This page
says how to talk to it by hand, what a hung access looks like and how to get out of it. The scripts
(`hw/*.py`) do the same; `hw/README.md` holds the measurements this page rests on. The sources of every
statement are listed at the end.

## Starting OpenOCD

```sh
./x hw openocd
```

This runs `hw/start_openocd.sh`, which starts the OpenOCD of the directory named by `OPENOCD` in
`hw/lab.conf`, by default the release pinned in `tools/toolchain.env` (`./x toolchain install openocd`; the
distribution's OpenOCD lacks the driver for the embedded FlashPro6). The telnet port is `OCD_PORT` of `hw/lab.conf` (4444
by default), the gdb port `OCD_GDB_PORT` (3333 by default; `./x hw debug` connects the toolchain's GDB to it). OpenOCD runs as a child of the script.

Stop it with Ctrl+C in the terminal that runs it. OpenOCD looks at SIGINT only between two passes of its
event loop, so while it is stuck in a JTAG or abstract-command timeout it ignores Ctrl+C. The script then
sends SIGTERM, waits 3 s (`START_OPENOCD_GRACE`) and kills OpenOCD; a second Ctrl+C kills it at once. The
exit status is 130 after Ctrl+C. Only a SIGKILL of the script itself leaves OpenOCD running.

## Several boards

`./x hw openocd` passes `OCD_PORT` of `hw/lab.conf` as `telnet_port` and `FLASHPRO_SERIAL` (`hw/lab.conf` or the
environment variable) as the serial number of the FlashPro. With several boards connected each one gets its own
`lab.conf` (`--lab FILE`) with its own `OCD_PORT` and `FLASHPRO_SERIAL`, and its OpenOCD needs its own gdb and Tcl
ports, which the script leaves alone (`./x hw openocd -c "gdb_port 3334" -c "tcl_port 6667"`). `./x hw flashpros`
lists the serial numbers; the one it printed for the board in use is the one OpenOCD prints when it finds the adapter.
`./x hw openocd` says first which FlashPro it will use: `start_openocd: FlashPro model efp6 (told from the USB product ID), serial <SERIAL>`,
with the source of the model (`FLASHPRO_TYPE`, the USB product ID, or assumed when no adapter is seen), the serial number from
`FLASHPRO_SERIAL`, or else the only adapter of that model that is connected, or that none or several are and that OpenOCD takes the
first it finds. A serial number that is not among the connected adapters of the model is said so; OpenOCD then reports its own
error when it cannot open the adapter.

A FlashPro whose USB descriptor has no serial number (iSerial not set) cannot be chosen by `FLASHPRO_SERIAL`: `./x hw flashpros`
lists it with `-` as its serial number and its USB location, and `FLASHPRO_USB_LOCATION` (`lab.conf` or the environment) gives
that location to OpenOCD as `adapter usb location`. The location is the name of the adapter's directory in
`/sys/bus/usb/devices` (`1-2.3`: bus, then the ports of the hubs in between) and changes with the USB port. With one adapter of
the model connected neither is needed: OpenOCD takes the one it finds, and the model is told from the USB product ID as it is
for an adapter with a serial number. With several of one model, `start_openocd.sh` says so and asks for `FLASHPRO_SERIAL` or
`FLASHPRO_USB_LOCATION`; with adapters of several models (say a FlashPro6 and a FlashPro5), `FLASHPRO_TYPE`, or the serial
number or location of the one that is meant, says which model. Whether the `microchip-fp6` driver honours `adapter usb
location` was not tried on a board (OpenOCD's help lists the command): a FlashPro6 without a serial number was selected by
`FLASHPRO_TYPE=fp6` alone, with one FlashPro6 and one FlashPro5 connected.

The model of the FlashPro decides the interface file and the command that takes the serial number. `FLASHPRO_TYPE` of
`lab.conf` names it; empty, `hw/flashpros.py --model` tells it from the USB product ID of the adapter:

| Model | `FLASHPRO_TYPE` | USB ID | Interface file | Serial number |
|---|---|---|---|---|
| Embedded FlashPro5 | `efp5` | `1514:2008`, product name other than `FlashPro5` | `embedded_flashpro5.cfg` | `adapter serial` |
| Embedded FlashPro6 | `efp6` | `1514:200b` | `embedded_flashpro6.cfg` | `mchp_efp6 serial` |
| FlashPro5 | `fp5` | `1514:2008`, product name `FlashPro5` | `flashpro5.cfg` | `adapter serial` |
| FlashPro6 | `fp6` | `1514:2009` | `flashpro6.cfg` | `mchp_fp6 serial` |

`2008` is the ID that `interface/flashpro5.cfg` and `interface/embedded_flashpro5.cfg` of the OpenOCD both name, and the
product name `FlashPro5` is what the first one asks for; `200b` is what the Icicle Kit's adapter reports (`Embedded
FP6b`), `2009` is the FlashPro6, as the project owner stated. The udev rules in the OpenOCD package also name `200a`
(the PIC64GX interface), which is left as unknown. With no adapter connected (OpenOCD may run on another machine) the
embedded FlashPro6 is assumed; with adapters of several models, or one of an unknown ID, the script stops and asks for `FLASHPRO_TYPE`.
The interface files are the ones of `interface/` in the OpenOCD package; with the target file they make its board file
(`board/microchip_riscv_efp6.cfg` and so on), but the target script runs `init`, so the serial number, the telnet port
and any arguments of the caller (`-c "gdb_port 3334"`) have to come between the two, and `start_openocd.sh` puts them
there. Only the embedded FlashPro6 was run on a board: for the other models OpenOCD was shown the interface file with
its command for the serial number and the ports, and accepted them, and the tests give the script a sysfs of invented
adapters.

The JTAG clock is `OCD_TCK_MHZ` of `lab.conf` (or the environment variable of that name), in whole MHz. The interface files
set `adapter speed 6000` (kHz); `start_openocd.sh` adds `adapter speed <OCD_TCK_MHZ times 1000>` after the interface file, so
the later command wins, and says `start_openocd: JTAG clock 10 MHz (adapter speed 10000 kHz, OCD_TCK_MHZ)`. Empty, the 6 MHz of
the interface file stay. The argument was checked against a stand-in for OpenOCD; which speeds the embedded FlashPro6 takes
was not tried on a board (FlashPro Express took 1 to 20 MHz in steps of 1 MHz from it, see `hw/README.md`).

This OpenOCD talks to the embedded FlashPro6 itself, no separate server is started: `./x hw run bare_hello` loaded and
ran an image on an Icicle Kit that way. Not run: opening the adapter by its serial number, and two boards at once.

## The telnet port

```sh
telnet localhost 4444
```

Host and port are `OCD_HOST` and `OCD_PORT` of `hw/lab.conf`. The Tcl RPC port is not used: Microchip's
OpenOCD has no `read_memory`, and the output of `md[bhwd]` (`mdw`) does not come back through it.

- Numbers without `0x` are decimal (the OpenOCD convention, as stated by the project owner). The scripts
  always write `0x`.
- Select a hart first: `targets mpfs.hart0_e51` for the E51, `targets mpfs.hart1_u54_1` .. `mpfs.hart4_u54_4`
  for the U54 harts (`targets` alone lists them).
- `riscv set_prefer_sba off`: the scripts send it after selecting the target, so that memory is read through
  the program buffer.
- Read a word: `mdw 0x20002084` (`SYSREG.SUBBLK_CLOCK_CR`). Write one: `mww ADDRESS VALUE`.
- Read the PC: `reg pc`.

## What a hung access looks like

An access to a block whose clock is off, or to a register that stalls the bus, can leave the debug module
busy. OpenOCD then replies, as plain text and not as an error:

```
Timed out after 2s waiting for busy to go low (abstractcs=0x10001002)
```

Measured cases: the first access to `CAN_A_LO` after `SYSREG.SUBBLK_CLOCK_CR`/`SOFT_RESET_CR` were written
(`--enable-clocks`), the first access to `EMMC_SD` and `DDR_CSR_APB` while their clock is off, and `mdw
0x2010C000`. After that further accesses fail as well; `unable to halt hart N` lines for the U54 harts at
power-on are a different thing and harmless for reads through the selected hart.

## Recovery without a power cycle

Measured on the Icicle Kit in boot mode 0 after `mdw 0x2010C000` had hung:

1. `riscv dmi_read 0x16` read `0x10000102` (`abstractcs`: busy clear, cmderr=1).
2. `riscv dmi_write 0x16 0x700` clears cmderr.
3. `reset halt`.
4. `mdw 0x20002084` (`SYSREG.SUBBLK_CLOCK_CR`) reads `0x00000001`, its power-on value: the platform is back.

The tools do this for you:

- `./x hw reset` runs the sequence, prints the reply of every step, reads `SYSREG.SUBBLK_CLOCK_CR` and
  `SYSREG.SOFT_RESET_CR` and compares them with the reset values of the SVD (it needs the merged SVD,
  `./x svd merge`). If they differ it toggles the debug module (`riscv dmi_write 0x10 0x0`, then `0x1`) and
  resets again. Exit status 0 only if the check passed; 2 means: power-cycle the board and restart OpenOCD.
  It is also fine to run it when nothing is hung.
- `./x svd probe --recover ...` (`svd_probe.py --recover`) runs the same sequence by itself when an access
  stalls the debug module and goes on with the next peripheral (at most 3 times by default). Without
  `--recover` the probe stops at the first stall and advises `./x hw reset`.

A debug module that was stuck busy is not trusted even when clearing cmderr has made it idle: after the hangs
of `EMMC_SD` and `DDR_CSR_APB` the next accesses failed (three `unreadable` in a row at `MMUART1_LO.IER`).
Reset in that case too.

## A reset loses the state

`reset halt` returns the platform to its power-on state. Everything that a program or a poke set up is gone:
clocks enabled with `--enable-clocks`, `--poke` writes, a PLL or boot state that software had set up. The
reset halt leaves the hart halted. In boot mode 0 that is the state in which the probes start anyway.

## After Ctrl+C

`run_image.py`, `run_probe.py` and `monitor.py` end at once with exit status 130, also while OpenOCD does
not answer. They do not clean up: the hart can be halted or still running the image. Send `resume` or
`halt` over telnet, or reset the board. `svd_probe.py` tries to resume the hart once and says if it may
still be halted.

## The boot stub

In boot mode 0 the E51 runs the boot stub that `SCB_REGS.BOOT_ROM0..7` hold (`0x20003120`..`0x2000313C`, the
reset vector `BOOT_ADDR`; the reset values in `svd/base/scb_regs.yaml` are its eight words). It is decoded
here from those words (`riscv64-elf-objdump -D -b binary -m riscv:rv64 --adjust-vma=0x20003120`); it was not
read back from the board:

```
20003120  csrrs a0,mhartid,x0
20003124  c.slli a0,2
20003126  lui    a4,0x20002
2000312a  lwu    a5,4(a4)        SYSREG.TEMP1 (0x20002004)
2000312e  c.beqz a5,2000312a     wait until TEMP1 is not zero
20003130  fence.i
20003134  c.add  a5,a0
20003136  lwu    t1,0(a5)        jump through the table that TEMP1 points to
2000313a  c.jr   t1
```

The hart waits in the loop at `0x2000312A`..`0x2000312E` until software writes a non-zero address to `TEMP1`.
The PC of a halted hart can be anywhere between `0x20003120` and `0x2000312E`; `0x2000312E` was seen on a
board.

## Platform state at power-on (boot mode 0)

Measured right after power-on with the hart halted by the tool (taken from `hw/README.md`, section "Platform
state at power-on in boot mode 0" and the sections it refers to):

- `SYSREG.DFIAPB_CR` reads `0x2` (corner clock on, reset released). `CFG_DDR_SGMII_PHY` reads all zero until
  `SYSREG.DFIAPB_CR=0x1` is written; then `DDRPHY_MODE` reads `0x2`. The zeros come from the gated MSS
  corner, not from the SVD.
- `CAN_A_LO.INT_STATUS` reads 0, also after `SYSREG.DFIAPB_CR=1` and/or `SCB_REGS.MSSIO_CONTROL_CR=0x3800`
  (power-on value `0x7A0`). With `--enable-clocks` the first CAN access stalled the debug module; the cause
  is not known.
- `SYSREG.SUBBLK_CLOCK_CR` reads `0x00000001`. After `--enable-clocks` (writes `0xFFFFFFFF`) it reads back
  `0x3FFDFFFF` on the MPFS250T (bits 31, 30 and 17 do not read back 1).
- The U54 harts do not halt at power-on (`unable to halt hart 1..4`).
- PLIC: `PENDING3` bit 23 (source 119, `F2M_1`) was set after a power cycle and `reset halt` cleared it. The
  threshold, enable and priority registers have a device-specific power-up pattern, mostly repeatable across
  power cycles, and identical across a `reset halt`.
- The ATHENA block must not be accessed on this chip (MPFS250T is not an S device): an access resets the
  OpenOCD connection.
- A run after `reset halt` and a clean power-on run agreed on all `SYSREG` and `SCB_REGS` configuration
  registers; only the PLIC, the CLINT `MTIMECMP` registers and `MMUART0` `DLR` and `THR` differed.
- A block without clock or reset can answer every read with the same word (`FRQMETER` read `0xA8148A` for
  all 12 registers while it was gated).

## Do not, in an unattended run

Do not poke `SCB_REGS.DEVICE_CONFIG_CR`, `SCB_REGS.RAM_SHUTDOWN_CR` or `SCB_REGS.MSS_RESET_CR`, and never
read or write `THR` of an MMUART (`hw/README.md`).

## Sources

| Statement | Source |
|---|---|
| Port 4444 and 3333, Microchip's OpenOCD, no read_memory, `mdw` not through the Tcl port | `hw/lab.conf`, `hw/start_openocd.sh`, `hw/README.md` |
| Ctrl+C, grace period, exit statuses | `hw/start_openocd.sh`, `hw/README.md` section "Ctrl+C", `tests/host/hw/run.sh` |
| `targets mpfs.hart0_e51`, `mpfs.hartN_u54_N`, `riscv set_prefer_sba off` | `hw/reset.py`, `hw/run_image.py`, `tests/host/hw/run.sh` |
| Decimal numbers without `0x` | stated by the project owner (OpenOCD convention); not in the repository |
| The timeout text, the measured hangs, the unreliable module after a hang | `hw/README.md` sections "`svd_probe.py`" and "Reset and recovery" |
| The recovery sequence and its measurement | `hw/recover.py`, `hw/README.md` section "Reset and recovery" |
| `./x hw reset`, `svd_probe.py --recover` | `hw/reset.py`, `hw/recover.py`, `hw/README.md`, `tools/hw.sh` |
| A reset loses the state | `hw/README.md` section "Reset and recovery" |
| Power-on facts | `hw/README.md` sections "Platform state at power-on in boot mode 0", "`svd_probe.py`" |
| Unattended runs | `hw/README.md`, end of "Reset and recovery" |
