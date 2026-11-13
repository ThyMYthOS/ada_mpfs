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

The trap is the first exception of the program. libgcc sorts its frame descriptions at the first unwind, and here that
happens on the interrupt stack of the trap handler. It needed more than the 8 KiB that the interrupt stack of the `embedded`
profile used to have (8 256 bytes on the E51 and 8 608 on the U54 were measured), so the U54 image hung without a verdict:
the next frame overwrote the `.bss` behind the stack, libgcc's register size table first, and the unwinder stopped at an
assertion. The test raised and handled one exception before the trap (`Warm_Up_Unwinder`) as a workaround; that is gone
(issue #91). The interrupt stack of the `embedded` profile is now 12 912 bytes (the measured peak plus 50 %) and a guard word
at its lower end turns an overrun into the message `interrupt stack overflow` instead of a hang; see `crates/mpfs_rts/README.md`,
section "Interrupt stack", and `examples/interrupt_stack_embedded_test`, which measures the peak and tests the guard.

The warm-up exception is not needed any more because the runtime does that work itself: `mpfs/embedded/gnat/unwind_warmup.S`
makes libgcc sort its frame descriptions before `main`, so that the first unwind in a trap does no `malloc` and no sorting
(unbounded latency with interrupts off, on the interrupt stack). Measured with stack painting and `minstret` under QEMU
(`crates/mpfs_rts/README.md`, "Interrupt stack"):

| This test, `embedded` | peak E51 / U54 | instructions, trap to the handler E51 / U54 | text of the image E51 / U54 |
|---|---|---|---|
| sorted in the trap (before the runtime warm-up) | 8 256 / 8 608 bytes | 105 355 / 106 354 | 48139 / 49435 |
| sorted before `main` (now) | 7 144 / 7 496 bytes | 50 564 / 51 564 | 48189 / 49485 |
| with its own warm-up exception (the original form) | 7 144 / 7 496 bytes | not measured | 48413 / 49709 |

The 12 912 bytes of the stack keep the margin of 50 % in all forms. A test with its own warm-up exception next to this one
would now only repeat the second row (the tables are sorted before it runs); it is not worth an image.

    ./x build trap_embedded_test --hart e51    # bin-e51/
    ./x build trap_embedded_test --hart u54    # bin-u54/
    ./x test qemu tests trap_embedded_test_e51 trap_embedded_test_u54
