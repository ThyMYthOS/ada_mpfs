<!--
SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
SPDX-License-Identifier: CC-BY-4.0
-->
# The USB and MMUART alias measurements, repeated

`svd/base/usb.yaml`, `svd/base/mmuart.yaml` and `svd/patches/MMUART0_LO.yaml` carry what was measured on the Icicle Kit on
2026-10-28: the stored bits and reset values of the USB registers and what the MMUART aliases at `+0x80`, `+0x100` and `+0x108` do.
This is a repetition of those measurements on 2026-11-16, to see whether the board gives the same.

## Run of 2026-11-16

| | |
|---|---|
| Board | Icicle Kit, `MPFS250T_ES`, power-cycled, boot mode 0 (`./x hw reset` before the run) |
| Method | a Python script through the telnet port of OpenOCD (`hw/ocd.py`) on hart 0 (E51, halted): the writes and reads of the claims, each register restored afterwards. The script is not part of the repository. |
| Clocks | on, as `--enable-clocks` does it: `SYSREG.SUBBLK_CLOCK_CR` `0x3FFDFFFF`, `SOFT_RESET_CR` `0` |

At power-on, before the clocks, the USB block reads 0 in every register that was read (`TX_IRQ_ENABLE`, `USB_ENABLE`, `HW_VERSION`,
`EP_INFO`, `RAM_INFO`, `LINK_INFO`): the block has no clock (the probe reports it as `gated`, see [`svd-probe.md`](svd-probe.md)). The reset
values in `usb.yaml` are therefore what the registers read with the clocks on, not what they read at power-on.

### Result

144 measurements, 0 differ from the claims in the YAML files.

| Claim | Measurements |
|---|---|
| Reset values: `TX_IRQ_ENABLE` `0x1F`, `RX_IRQ_ENABLE` `0x1E`, `USB_ENABLE` `0x06`, `HW_VERSION` `0x0C04`, `EP_INFO` `0x44`, `RAM_INFO` `0x4B`, `LINK_INFO` `0x5C`, `VBUS_CSR` 0 | 8 |
| Bits stored by the interrupt enables after a write of all ones (`0x1F`, `0x1E`, all 8 bits) | 3 |
| Indexed registers at `INDEX` 0, 1, 4, 5, 8 and 15: `TX_MAX_P`, `RX_MAX_P`, the type and interval bytes (EP1 and EP4 store all bits, EP0 `0xC0` and `0x1F`, EP5, EP8 and EP15 read 0), `INDEXED_FIFO_SIZE` (`0xDE`, `0x33`, 0) | 42 |
| `TX_FIFO_SIZE`, `RX_FIFO_SIZE` (`0x1F` after a write of `0xFF`), `TX_FIFO_ADDR`, `RX_FIFO_ADDR` (`0x3FFF` after a write of `0xFFFF`) at `INDEX` 1, 4 and 5, and the reset value 0 of `TX_FIFO_SIZE` | 15 |
| `RQ_PKT_CNT[0..15]` reset 0, and a write of `0xFFFFFFFF` reads `0xFFFF` for EP1..EP4 and 0 for EP0, EP5, EP8 and EP15 | 22 |
| `RX_DPBUF_DIS`, `TX_DPBUF_DIS` (`0xFFFE`), `C_T_UCH` (`0x4074`), `C_T_HHSRTN` (`0x05E6`), `C_T_HSBT` (`0x000F` after a write of `0xFFFF`), their reset values and stored bits | 10 |
| `DMA_INTR` reads 0 with an 8, a 16 and a 32-bit access | 3 |
| `TAR[n]` for n = 0, 1, 4, 5, 15: function address and hub port `0x7F`, hub address `0xFF` after a 32-bit write of all ones (`0x7FFF007F`); EP0 has no RX registers; EP5 and EP15 read 0 | 10 |
| `DMA_CHANNEL[n]` for n = 0, 3 (store `CNTL` `0x6FE`, `ADDR` `0x12345678`, `COUNT` `0x00ABCDEF`; a 16-bit read of `ADDR` returns the low half) and n = 4, 7 (read 0) | 18 |
| `SOFT_RST` reads 0 after a write of `0x03` | 1 |
| MMUART1 in loopback: `+0x00`, `+0x80` and `+0x100` read `DLL`, `+0x04`, `+0x84` and `+0x104` read `DLM` at LCR `0x83`; `LSR` `0x60`, after a character `0x61`; a read of `+0x100` returns the character and pops the FIFO; `IIR` `0xC1` at `+0x08`, `+0x88` and `+0x108`; a write of `0x03` to each of the three clears the receive FIFO | 12 |

### Not repeated

- The cable test of the first run (a USB cable to a host with `POWER.SOFT_CONN` set: no interrupt arrived, `DEV_CTRL` stayed `0x80`): no
  cable was attached. The interrupt status bits and their clear on read stay unverified, as `usb.yaml` says.
- Whether `SOFT_RST` resets the core (only the readback of the write was measured), the split of `LINK_INFO` into its two fields (from the
  vendor driver), the clear on read of `DMA_INTR`, the size of the FIFO RAM in bytes.
- One board.
