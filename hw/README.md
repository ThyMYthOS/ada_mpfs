# `hw/`

- **Purpose:** Host-side tools that talk to an Icicle Kit through OpenOCD and its serial ports.
- **License:** Apache-2.0

| File | Content |
|---|---|
| `lab.conf` | What differs between machines: the SoftConsole path (`SC`), the OpenOCD host and port, the serial devices (`UART_PATTERN`, `{n}` is the MMUART number) and their number. `--lab FILE` or `LAB_CONF` names another one. |
| `lab.py` | Reads `lab.conf` and finds the RISC-V compiler: the version pinned in `tools/toolchain.env` (`GNAT_RISCV64_VERSION`) below `MPFS_ADA_TOOLCHAINS`; another version, or none, is an error. `run` turns a message-carrying exit into status 2. |
| `start_openocd.sh` | Starts the OpenOCD of SoftConsole (the distribution's has no `microsemi-flashpro` interface). Telnet on :4444, gdb on :3333. |
| `ocd.py` | OpenOCD telnet client and serial capture. |
| `run_image.py` | Loads an ELF onto one hart, runs it, prints the serial ports and the first trap. `--expect REGEX` sets the exit status (0 matched, 1 not matched or no output); `--expect-port N` restricts it to one port. `--uart-standin` (off by default) clocks and sets up the UARTs for an image that expects a boot stage to have done it. |
| `run_probe.py` | Runs a probe (`probe_*.S`, `trap.S` is the trap recorder `run_image.py` loads) on one hart and prints its result block; `--expect REGEX` as above. |
| `monitor.py` | Shows what the serial ports print; `--expect REGEX` as above. |
| `svd_probe.py` | Compares the reset values of SVD registers with the board (`./x svd probe [--enable-clocks] [PERIPHERAL...]`); see below. |
| `svd_probe.list` | The rules of `svd_probe.py`: blocks it does not read by default (`skip`), registers that hold runtime state (`state`) and registers of which only some bits are live (`state-mask PATTERN MASK reason`: QSPIXIP.DirectAccess bits 23-16, the pin levels; CRYPTO.CONFIG bits 27-24, a fabric handshake). |

Exit status of `run_image.py`, `run_probe.py` and `monitor.py`: 0 success, 1 the expectation was not met, 2 a set-up error (no OpenOCD,
no serial port, no toolchain, bad arguments). `./x hw openocd|run|probe|monitor` is the shell around them (`tools/hw.sh`).
`tests/host/hw/run.sh` tests the scripts against a stand-in for the OpenOCD telnet port and files in place of the serial ports; the
hardware itself is not part of any automatic test.

## `svd_probe.py`

Reads the registers of the selected peripherals through the OpenOCD telnet port with the hart halted and compares them with `<resetValue>` under `<resetMask>`. One line per register, always `<kind>  0x<address> <PERIPHERAL.REGISTER>`; `ok`, `mismatch`, `state` and `noref` continue with ` = 0x<value>`, the value read in hex as wide as the register (`ok          0x20002008 SYSREG.CLOCK_CONFIG_CR = 0x00000010`), so a log can be compared with another run, and the kind is the prefix of the line:

| Line | Meaning |
|---|---|
| `ok` | The value matches. |
| `mismatch` | The value differs; the expected value is shown too. |
| `state` | The value differs, but the register matches a `state` rule of `svd_probe.list` (status, FIFO, message RAM, a register `--enable-clocks` wrote), or only the live bits of a `state-mask` rule differ: it only has its reset value after a reset-halt. `--compare-state` reports it as `mismatch`. |
| `noref` | Nothing to compare: the SVD has no `<resetValue>` (CLINT MTIME/MTIMECMP, the USB registers, the PLIC threshold, enable and priority registers) or `<resetMask>` is 0. |
| `unreadable` | The access failed; the text OpenOCD replied is shown. |
| `skipped` | Not read. `skipped (readAction)`: the SVD gives the register or one of its fields a `readAction`, and the read would consume data or clear status (PLIC claim/complete, UART RBR, SPI/I2C data, CAN receive RAM, USB FIFOs, ...); `--read-destructive` reads them anyway and warns. The other lines name a block excluded by a `skip` rule, or the rest of a peripheral after an unreadable register (`--keep-going` reads on). |

By default the rules file excludes `ATHENA` (the Icicle Kit chip, MPFS250T, is not an S device: an access to the Athena block resets the OpenOCD connection), `TRACE` and `IOSCBCFG` (never measured), `ENVM` and the `*_HI` aliases (not measured separately yet). The CAN blocks (`CAN_A_LO`, `CAN_B_LO` and their `_HI` aliases) are excluded only together with `--enable-clocks` (rule kind `skip-enable-clocks`): the first access to `CAN_A_LO` after the `--enable-clocks` writes stalled the debug module at power-on, which then needed a power cycle of the board; the cause is not yet understood. Without `--enable-clocks` the block reads 0 and is probed normally. `EMMC_SD` and `DDR_CSR_APB` are the other way round (rule kind `skip-no-clocks`): while their clock is off the first access hangs the debug module, so they are excluded unless `--enable-clocks` is given. The report names the reason; `--skip-file FILE` uses another rules file, `--skip PERIPHERAL` leaves a peripheral out silently. The exclusion applies to whole-device runs (`--all` or no name): `--include PATTERN` reads a block anyway there, and a peripheral named on the command line is always read (`./x svd probe ENVM`), with a note on stderr that the block is on the default skip list and why.

A bus error in a program-buffer read can make OpenOCD drop the session. The probe then stops at once with exit status 2, names the register (or block) it accessed last and hints at the cause; it also stops after `--max-failures N` (default 3) unreadable registers in a row. `--block [PATTERN=]N` limits the registers per read command, for all peripherals or for those matching `PATTERN` (`--block 'CAN*=16'`); `--block 1` reads one register at a time and finds the register that kills the session. At the end the hart is resumed; if the connection is gone, the probe reconnects once, and if that fails it says that the hart is still halted and exits with status 2.

Before the first read the probe checks in OpenOCD's target table (`targets`) that the selected hart is halted, also with `--no-halt`; otherwise it stops with exit status 2 and shows the table and the reply to `halt`. Harts that did not halt (`unable to halt hart 1..4` at power-on: the U54 harts) are mentioned in one `svd_probe: note:` line on stdout; reads go through the selected hart only, so they do not matter.

A reply such as `Timed out after 2s waiting for busy to go low (abstractcs=0x10001002)` means that the debug module is stuck busy: an access hung (the first access to `CAN_A_LO` after the `--enable-clocks` writes did). OpenOCD sends this as plain text, not as an error. The probe stops at once, whatever `--keep-going` and `--max-failures` say, and shows the reply. It makes one recovery attempt (`riscv dmi_write 0x16 0x700` clears cmderr, `riscv dmi_read 0x16` reads abstractcs; if OpenOCD does not know these commands there is no attempt). If the debug module stays busy it does **not** resume the hart (that would hang as well), names the block and the register, and asks for a power cycle of the board and a restart of OpenOCD: the debug module does not recover otherwise. If it is idle again, the register is reported as `unreadable` and the run goes on with the next peripheral.

PLIC: `PENDING0..5` have the reset value 0, but their bits follow the interrupt sources: after a power cycle `PENDING3` bit 23 (source 119, `F2M_1`, a fabric interrupt line) was set and pended again right after every completion, and `reset halt` cleared it. A rule of `svd_probe.list` reports a difference as `state`. The threshold, enable and priority registers have no reset value in the SVD (a device-specific power-up pattern, mostly repeatable across power cycles: 168 of 186 priority words and 23 of 54 enable words were identical, the thresholds were identical, and all of them were identical word for word across a `reset halt`), so they are reported as `noref` and not compared. The claim registers are skipped as `readAction`; a claim value is a function of `PENDING`, `ENABLE`, `PRIORITY` and `THRESHOLD` (verified for 123 of 123 reads) and is 0 after a `reset halt`.

Ctrl+C stops the probe at once, also when OpenOCD does not answer because the bus is hung (the read otherwise waits for `--timeout`). It prints one line, makes one attempt to resume the hart with a 2 s timeout (no retry and no new connection; none with `--no-halt`), says what it read so far and whether the hart may still be halted, and exits with status 130. A second Ctrl+C during that attempt leaves immediately. **After an interrupt the hart can remain halted**: send `resume` to OpenOCD (telnet :4444) or reset the board.

Exit status: 0 all registers `ok`, `state`, `noref` or `skipped`; 1 at least one `mismatch` or `unreadable`; 2 the probe stopped early, could not resume the hart, or the arguments or the set-up are wrong; 130 interrupted with Ctrl+C.

`tests/host/svd/probe_test.py` tests the probe against stand-ins for the telnet port that reset the connection, refuse the resume, hang or answer with errors, and that receive Ctrl+C; real hardware is not part of any automatic test.
