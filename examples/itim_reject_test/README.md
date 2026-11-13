# itim_reject_test

An image with code in the ITIM that is started where the ITIM is not enabled is rejected by `start_fast.S` with a clear
record, instead of crashing later (as `hello_mpfs` of the earlier project did). The image shares `Fast` with `examples/itim_test`
but its `ld/app-sections.ld` puts `.fast_text` in the real ITIM of the E51 (`0x0180_0000`, 8 KB) and loads it from
the LIM. QEMU has no ITIM (and on the board nothing enables it yet: that is the boot stage), so the check of
`start_fast.S` ends in the rejection: a store access fault at the first word of the range, or a word that reads back
wrongly. `start_fast.S` writes the 32-byte record at `__mpfs_trap_record` (kind 1 = code, the address, `mcause` or all
ones, the magic `0x4d495449`, `mhartid`) and jumps to the test seam `__mpfs_early_trap_hook` that `Reject.Hook`
implements; it checks the record and reports as `itim_reject_test_e51`. If the main program is reached, the image
was not rejected, which fails.

    ./x build itim_reject_test
    ./x test qemu tests itim_reject_test_e51
