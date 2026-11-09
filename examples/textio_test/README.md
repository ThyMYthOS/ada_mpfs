# textio_test

The console of the runtime `crates/mpfs_rts`: `System.Text_IO`, polled output and input on one MMUART. Which MMUART,
and whether the runtime sets it up, is link-time data (`__mpfs_console_base`, `__mpfs_console_init`,
`__mpfs_console_dlr`, `__mpfs_console_dfr`; see `crates/mpfs_rts/README.md`). One project, six images, each linked with
its own console symbols (`Mpfs_Link`, per main), linked with the `light` runtime (`RUNTIME=mpfs_rts`; `-P
light-tasking` and `-P embedded` build the same images with those runtimes). Every report goes out through
`System.Text_IO` (`src/bare_console.adb` is a body of `Bare_Console` over it), so a serial port that shows the lines
shows that the console works.

| Image | Console | Init | What it proves |
|---|---|---|---|
| `textio_test` | MMUART of the hart (hart 0: MMUART0, U54 hart 1: MMUART1) | 1 | The first output initialised the service; the registers of that MMUART are those of the link symbols (8N1, divisor 22, DFR 0, FIFOs on); `GNAT.IO` reaches the same port; with `MCR.LOOP` every byte put comes back through `Is_Rx_Ready` and `Get` and the receiver is empty afterwards |
| `console_mmuart1_test` to `console_mmuart3_test` | MMUART1 to MMUART3 | 1 | The report is on that port and on no other (the runner of `tests/qemu` fails a test that writes to another port); the registers of that MMUART are those of the link symbols |
| `console_mmuart4_test` | MMUART4 | 1 | The same on a port the board does not bring out, with the divisor 21 and the fraction 45/64: DFR and `MM0.EFBR` (fractional baud rate mode) are set |
| `console_noinit_test` | MMUART of the hart | 0 | `Initialize` writes no setup register (a value left in DFR, and LCR, are found again): the boot stage has set the port up and the runtime only writes and reads |

`examples/console_none_test` has the console `none`. The images report as `<image>_e51` and `<image>_u54`.

    ./x build textio_test --hart e51          # all six images
    ./x test qemu tests textio_test_e51 console_mmuart1_test_e51 console_noinit_test_u54
    ./x hw run examples/textio_test/bin-e51/textio_test.elf --hart 0 --uart-clocks \
        --expect 'TEST textio_test_e51: PASS' --expect-port 0   # U54 hart 1: textio_test_u54, port 1

(`./x hw run <example>` would take the first image of the directory, so the images are named by their file.)

`console.expected` is not used: every image has its own `.expected` file, whose lines the host asserts on the port of
the image. Under QEMU the registers behind `+0x20` of an MMUART are plain memory and the serial model ignores the
divisor, so the divisor and the fraction are checked as register contents, not as a baud rate; the runtime uses the
16550 offsets (data port at `+0`, the divisor latches at `+0` and `+4` with `LCR.DLAB`, `FCR` at `+8`) that both the
board and QEMU have. The board needs the clock and the reset of the MMUARTs released by something before the image
runs (`--uart-clocks`, later the boot stage); `console_noinit_test` needs the divisor and the format as well
(`--uart-standin`).

Each image has its own partition: `./x build` writes the console of each main from the `IMAGE_<main>=` lines of
`example.conf` (`--console mmuart1` and so on, `--console-init 0`) and `textio_test` takes `--console` of the build
(default: the MMUART of the lowest hart, hart n: MMUARTn; `./x test qemu` reads the E51 images on serial 0 and the U54 images on serial 1, `tests/qemu/tests.list`). MMUART4 (hart 4) is not brought out on the board: only MMUART0 to MMUART3 are on the CP2108, so an image for U54 hart 4 prints nowhere that a serial port shows. `tests/host/rts_boot` builds `textio_test`
with each console symbol left out and expects the link to fail.
