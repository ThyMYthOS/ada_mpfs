# `tests/hw/`

- **Purpose:** Hardware tests on the Icicle Kit.
- **License:** Apache-2.0

A test application that reports with `Test_Report` (`tests/common/test_report.ads`) is run on the board with
`./x hw run <example> --hart <n> --expect 'TEST <name>: PASS'`: the exit status is 0 only if the verdict
line appeared on a serial port. The scripts and their own tests are described in `hw/README.md`.
