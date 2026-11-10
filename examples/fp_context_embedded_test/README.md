# fp_context_embedded_test

The `fp_context_test` of the `embedded` profile: the sources are those of `examples/fp_context_test/src`, linked with the `embedded`
runtime variant of `crates/mpfs_rts`. Only the name differs (`src/test_name_*.ads`, mapped to `Test_Name` by the
project file; see "Profile variants" in `examples/STYLE.md`), so the report reads `fp_context_embedded_test_u54` and the rows are
in `tests/qemu/tests.list`. What the test checks is in the README of `examples/fp_context_test`. `console.expected` is
that of `fp_context_test`; `tests/host/qemu_tests` checks that the two are the same file.

The E51 has no floating-point registers, so there is no image for it.

    ./x build fp_context_embedded_test --hart u54                 # bin-u54/
    ./x test qemu tests fp_context_embedded_test_u54
