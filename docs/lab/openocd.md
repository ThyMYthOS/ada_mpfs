<!--
SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
SPDX-License-Identifier: CC-BY-4.0
-->
# Access to the board through OpenOCD

Everything the host tools do with the board goes through the OpenOCD of Microchip SoftConsole. This page
says how to talk to it by hand, what a hung access looks like and how to get out of it. The scripts
(`hw/*.py`) do the same; `hw/README.md` holds the measurements this page rests on. The sources of every
statement are listed at the end.

## Starting OpenOCD

```sh
./x hw openocd
```

This runs `hw/start_openocd.sh`, which starts the OpenOCD of the SoftConsole directory named by `SOFT_CONSOLE` in
`hw/lab.conf` (the distribution's OpenOCD has no `microsemi-flashpro` interface). The telnet port is 4444,
the gdb port 3333. OpenOCD runs as a child of the script.

Stop it with Ctrl+C in the terminal that runs it. OpenOCD looks at SIGINT only between two passes of its
event loop, so while it is stuck in a JTAG or abstract-command timeout it ignores Ctrl+C. The script then
sends SIGTERM, waits 3 s (`START_OPENOCD_GRACE`) and kills OpenOCD; a second Ctrl+C kills it at once. The
exit status is 130 after Ctrl+C. Only a SIGKILL of the script itself leaves OpenOCD running.

## The telnet port

```sh
telnet localhost 4444
```

Host and port are `OCD_HOST` and `OCD_PORT` of `hw/lab.conf`. The Tcl RPC port is not used: the SoftConsole
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
| Port 4444 and 3333, SoftConsole OpenOCD, no read_memory, `mdw` not through the Tcl port | `hw/lab.conf`, `hw/start_openocd.sh`, `hw/README.md` |
| Ctrl+C, grace period, exit statuses | `hw/start_openocd.sh`, `hw/README.md` section "Ctrl+C", `tests/host/hw/run.sh` |
| `targets mpfs.hart0_e51`, `mpfs.hartN_u54_N`, `riscv set_prefer_sba off` | `hw/reset.py`, `hw/run_image.py`, `tests/host/hw/run.sh` |
| Decimal numbers without `0x` | stated by the project owner (OpenOCD convention); not in the repository |
| The timeout text, the measured hangs, the unreliable module after a hang | `hw/README.md` sections "`svd_probe.py`" and "Reset and recovery" |
| The recovery sequence and its measurement | `hw/recover.py`, `hw/README.md` section "Reset and recovery" |
| `./x hw reset`, `svd_probe.py --recover` | `hw/reset.py`, `hw/recover.py`, `hw/README.md`, `tools/hw.sh` |
| A reset loses the state | `hw/README.md` section "Reset and recovery" |
| Power-on facts | `hw/README.md` sections "Platform state at power-on in boot mode 0", "`svd_probe.py`" |
| Unattended runs | `hw/README.md`, end of "Reset and recovery" |
