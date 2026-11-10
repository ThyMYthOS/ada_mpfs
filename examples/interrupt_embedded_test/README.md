# interrupt_embedded_test

The `interrupt_test` of the `embedded` profile: the sources are those of `examples/interrupt_test/src`, linked with the `embedded`
runtime variant of `crates/mpfs_rts`. Only the name differs (`src/test_name_*.ads`, mapped to `Test_Name` by the
project file; see "Profile variants" in `examples/STYLE.md`), so the report reads `interrupt_embedded_test_e51` or `interrupt_embedded_test_u54` and the rows are
in `tests/qemu/tests.list`. What the test checks is in the README of `examples/interrupt_test`. `console.in` and `console.expected` are
those of `interrupt_test`; `tests/host/qemu_tests` checks that they are the same files.

    ./x build interrupt_embedded_test --hart e51                 # bin-e51/
    ./x build interrupt_embedded_test --hart u54                 # bin-u54/
    ./x test qemu tests interrupt_embedded_test_e51 interrupt_embedded_test_u54
