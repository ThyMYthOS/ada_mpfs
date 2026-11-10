# tasking_embedded_test

The `tasking_test` of the `embedded` profile: the sources are those of `examples/tasking_test/src`, linked with the `embedded`
runtime variant of `crates/mpfs_rts`. Only the name differs (`src/test_name_*.ads`, mapped to `Test_Name` by the
project file; see "Profile variants" in `examples/STYLE.md`), so the report reads `tasking_embedded_test_e51` or `tasking_embedded_test_u54` and the rows are
in `tests/qemu/tests.list`. What the test checks is in the README of `examples/tasking_test`. `console.expected` is
that of `tasking_test`; `tests/host/qemu_tests` checks that the two are the same file.

    ./x build tasking_embedded_test --hart e51                 # bin-e51/
    ./x build tasking_embedded_test --hart u54                 # bin-u54/
    ./x test qemu tests tasking_embedded_test_e51 tasking_embedded_test_u54
