# textio_tasking_test

The `textio_test` of the `light-tasking` profile: the sources are those of `examples/textio_test/src`, linked with the `light-tasking`
runtime variant of `crates/mpfs_rts`. Only the name differs (`src/test_name_*.ads`, mapped to `Test_Name` by the
project file; see "Profile variants" in `examples/STYLE.md`), so the report reads `textio_tasking_test_e51` or `textio_tasking_test_u54` and the rows are
in `tests/qemu/tests.list`. What the test checks is in the README of `examples/textio_test`. `console.expected` is
that of `textio_test`; `tests/host/qemu_tests` checks that the two are the same file.

Only the image of the console on MMUART0 is built here; the other consoles are selected by link symbols and do not depend on the profile (`textio_test`).

    ./x build textio_tasking_test --hart e51                 # bin-e51/
    ./x build textio_tasking_test --hart u54                 # bin-u54/
    ./x test qemu tests textio_tasking_test_e51 textio_tasking_test_u54
