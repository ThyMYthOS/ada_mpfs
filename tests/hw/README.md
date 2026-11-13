# `tests/hw/`

- **Purpose:** Hardware tests on the Icicle Kit.
- **License:** Apache-2.0

A test application that reports with `Test_Report` (`tests/common/test_report.ads`) is run on the board with
`./x hw run <example> --hart <n> --expect 'TEST <name>: PASS'`: the exit status is 0 only if the verdict
line appeared on a serial port. The scripts and their own tests are described in `hw/README.md`.

`run_matrix.sh [-s SECS] [-o DIR] [NAME ...]` runs every cell of `tests/qemu/tests.list` that makes sense on the board and prints one
line per cell (`PASS`, `FAIL`, `ERROR` or `skip` with the reason); the log of each cell is in `build/hw-results/`. It builds the image
with the hardware limits (`DELAY_ACCURACY=hardware`, `RX_SOURCE=loopback`), resets the board and runs `./x hw initialize --minimal`
before every cell (`-m scratchpad`: builds with `--memory scratchpad` and runs `hw/l2_scratchpad.py` after the initialize), and tries the console set-up `--uart-standin` first, then `--uart-clocks`. The results of the first runs are in
[`docs/lab/results/p1.md`](../../docs/lab/results/p1.md).
