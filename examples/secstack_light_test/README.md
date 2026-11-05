# secstack_light_test

The secondary stack of the `light` runtime of `crates/mpfs_rts` (default 16 KiB, an overflow ends in the last chance
handler). The description of the three secondary stack tests, the checks and how to build them is in
[`../secstack_test/README.md`](../secstack_test/README.md); the sources are in `../secstack_test/src` and `src`.

    ./x build secstack_light_test --hart e51
    ./x test qemu tests secstack_light_test_e51 secstack_light_test_u54
