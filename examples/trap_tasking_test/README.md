# trap_tasking_test

The `trap_test` of the `light-tasking` profile: the sources are those of `examples/trap_test/src`, linked with the `light-tasking`
runtime variant of `crates/mpfs_rts`. Only the name differs (`src/test_name_*.ads`, mapped to `Test_Name` by the
project file; see "Profile variants" in `examples/STYLE.md`), so the report reads `trap_tasking_test_e51` or `trap_tasking_test_u54` and the rows are
in `tests/qemu/tests.list`. What the test checks is in the README of `examples/trap_test`. `console.expected` is
that of `trap_test`; `tests/host/qemu_tests` checks that the two are the same file.

The trap happens while the units are elaborated, before the runtime of this profile has installed its own trap handler, so the trap stub of the start code reports the record, as in `trap_test`.

    ./x build trap_tasking_test --hart e51                 # bin-e51/
    ./x build trap_tasking_test --hart u54                 # bin-u54/
    ./x test qemu tests trap_tasking_test_e51 trap_tasking_test_u54
