# secstack_tasking_test

The secondary stack of the `light-tasking` runtime of `crates/mpfs_rts` (default 8 KiB, a task with a stack of its
own, an overflow ends in the last chance handler). The description of the three secondary stack tests, the checks and
how to build them is in [`../secstack_test/README.md`](../secstack_test/README.md); the sources are in
`../secstack_test/src` and `src` (the body of `Secstack_Worker` is this one's).

    ./x build secstack_tasking_test --hart e51
    ./x test qemu tests secstack_tasking_test_e51 secstack_tasking_test_u54
