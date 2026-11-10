# elab_embedded_test

The `elab_tasking_test` of the `embedded` profile: the sources are those of `examples/elab_tasking_test/src`, linked with the `embedded`
runtime variant of `crates/mpfs_rts`. Only the name differs (`src/test_name_*.ads`, mapped to `Test_Name` by the
project file; see "Profile variants" in `examples/STYLE.md`), so the report reads `elab_embedded_test_e51` or `elab_embedded_test_u54` and the rows are
in `tests/qemu/tests.list`. What the test checks is in the README of `examples/elab_tasking_test`. `console.expected` is
that of `elab_tasking_test`; `tests/host/qemu_tests` checks that the two are the same file.

    ./x build elab_embedded_test --hart e51                 # bin-e51/
    ./x build elab_embedded_test --hart u54                 # bin-u54/
    ./x test qemu tests elab_embedded_test_e51 elab_embedded_test_u54
