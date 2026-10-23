# trap_test

An early trap is reported correctly (defect no. 5 of the master plan: `mtvec` was not set before the first trap).
It is linked with the `light` runtime of `crates/mpfs_rts` (work package P1.3): the start code `start.S`
points `mtvec` at the trap stub as its first action. While the package `Early_Trap` is elaborated, before the
main program, it executes an illegal instruction (`fault.S`). The stub records `mcause`, `mepc`, `mtval` and
`mhartid` at `__mpfs_trap_record` and jumps to `Early_Trap.Hook` (the test seam `__mpfs_early_trap_hook`, see
`crates/mpfs_rts/mpfs/gnat/start.S`), which checks

- the magic of the record and `mhartid`;
- `mcause` is 2 (illegal instruction);
- `mepc` is the address of the illegal instruction (`trap_test_fault_insn`);
- `mtval` is the instruction (`0xC0001073`) or 0;

and reports with `Test_Report` as `trap_test_e51` or `trap_test_u54`. `console.expected` makes the host assert
the `ok:` lines. If the trap never happens, or returns, there is no verdict line and the test fails.

    ./x build trap_test [--hart u54]
    ./x qemu trap_test
    ./x test qemu tests trap_test_e51 trap_test_u54

The scenario variables `MPFS_PLACEMENT` (`lim`, `scratchpad`, `envm`) and `MPFS_BOOT_ROLE` (`primary`,
`secondary`) of `crates/mpfs_rts/mpfs_link.gpr` select the boot scenario; `tests/host/rts_boot` links the four
(primary and secondary, in the LIM and in the scratchpad). QEMU has no scratchpad, so the scratchpad images are
only built, never run.
