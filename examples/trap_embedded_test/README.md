# trap_embedded_test

An illegal instruction in a program of the `embedded` profile. The instruction is the one of `trap_test`
(`examples/trap_test/src/fault.S`, shared). The `embedded` runtime installs its own trap handler before the first
unit of the application is elaborated, so the early trap of `trap_test` (the trap stub of the start code, which
reports `mcause`, `mepc` and `mtval` of a record) is not what happens here: the handler raises `Program_Error`
("Unhandled trap: 2"), the exception finds no handler and ends in the last chance handler of the test
(`src/trap_last_chance.adb`), which checks

- it is called once, for `Program_Error` with the message of the cause;
- `mcause` is 2 (illegal instruction), `mepc` is the address of the instruction (`trap_test_fault_insn`) and
  `mtval` is the instruction (`0xC0001073`) or 0

and reports with `Test_Report` as `trap_embedded_test_e51` or `trap_embedded_test_u54`.

The program raises and handles one exception before the trap (`Warm_Up_Unwinder`). The first exception of a
program makes libgcc sort its frame descriptions, which takes memory from the heap (its first use) and, on the U54,
more than the 8 KiB of the interrupt stack of the runtime (`Interrupt_Stack_Size` of `s-bbpara__polarfiresoc.ads`)
when it happens in a trap handler: the stack is used up to its last 16 bytes (measured under QEMU with the register
dump of every block) and the next frame overwrites the `.bss` behind it, libgcc's register size table first, so that
the unwinder stops at an assertion (`ebreak`) and the program hangs without a verdict. Without the warm-up the
E51 image passes and the U54 image hangs. The stack is the runtime's (`crates/bb-runtimes` is the unmodified fork); this
is recorded for the runtime work, and not hidden by the test, which says so here and in its source.

    ./x build trap_embedded_test --hart e51    # bin-e51/
    ./x build trap_embedded_test --hart u54    # bin-u54/
    ./x test qemu tests trap_embedded_test_e51 trap_embedded_test_u54
