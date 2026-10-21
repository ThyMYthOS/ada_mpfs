# report_test

The first test application of the `Test_Report` protocol (`tests/common/test_report.ads`). It checks
what the hart class of the image promises, and reports `report_test_e51` or `report_test_u54`:

- the hart id is 0 to 4;
- `misa` has the compressed extension;
- the E51 has neither the F nor the D extension, a U54 has both.

It is built like `bare_hello` (it shares `start.S` and `Bare_Console` with it) for the E51 and the U54.
`tests/qemu/tests.list` names both images; `./x test qemu` boots them and asserts the verdict.

    ./x build report_test [--hart u54]
    ./x qemu report_test
    ./x test qemu tests
