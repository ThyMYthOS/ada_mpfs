# float_tasking_test

The `float_test` of the `light-tasking` profile: the sources are those of `examples/float_test/src`, linked with the `light-tasking`
runtime variant of `crates/mpfs_rts`. Only the name differs (`src/test_name_*.ads`, mapped to `Test_Name` by the
project file; see "Profile variants" in `examples/STYLE.md`), so the report reads `float_tasking_test_e51` or `float_tasking_test_u54` and the rows are
in `tests/qemu/tests.list`. What the test checks is in the README of `examples/float_test`. `console.expected` is
that of `float_test`; `tests/host/qemu_tests` checks that the two are the same file.

    ./x build float_tasking_test --hart e51                 # bin-e51/
    ./x build float_tasking_test --hart u54                 # bin-u54/
    ./x test qemu tests float_tasking_test_e51 float_tasking_test_u54
