# interrupt_stack_tasking_test

The `interrupt_stack_embedded_test` of the `light-tasking` profile: the sources are those of
`examples/interrupt_stack_embedded_test/src`, linked with the `light-tasking` runtime variant of `crates/mpfs_rts`. The
profile has no exception propagation: the trap handler raises `Program_Error`, which is a direct call of the last chance
handler with the message as a C string (prefixed with the place of the raise), so the unit `Istack_Handler` of this
example (`src/istack_handler_tasking.ad[sb]`) differs, and so does the name of the test (`src/test_name_tasking.ads`, see
"Profile variants" in `examples/STYLE.md`): the images are `istack_peak_tasking_test`, `istack_overflow_tasking_test` and
`istack_halt_tasking_test`, and what they check is in the README of `examples/interrupt_stack_embedded_test`. The programs use
`Ada.Real_Time`, which links the tasking part of the runtime and with it the trap handler and the interrupt stack (a
`light-tasking` program that uses none has no interrupt stack and no guard).

One image more: `istack_tiny_tasking_test` has an interrupt stack of 512 bytes (the `IMAGE_` line of `example.conf`) and
executes the illegal instruction. The trap frame alone is 256 bytes on the E51 and all of the stack on the U54, so the
handler, the raise and the print of the last chance handler run below the lower end of the stack, over a few hundred bytes of
the `.bss` of the runtime, and the last chance handler of the runtime finds the guard word overwritten and prints `interrupt
stack overflow`. It is a real overrun, not a simulated one; it is a `light-tasking` test because there the damage is a few
hundred bytes. In the `embedded` profile the unwinder needs 8 KiB, which on a stack that small treads on the heap and on
libgcc's tables before anything can check the word (the software guard finds an overrun after the fact), so the message is
not guaranteed there; `istack_overflow_embedded_test` and `istack_halt_embedded_test` do not depend on what lies below the stack.

    ./x build interrupt_stack_tasking_test --hart e51    # bin-e51/
    ./x build interrupt_stack_tasking_test --hart u54    # bin-u54/
    ./x test qemu tests istack_peak_tasking_test_e51 istack_peak_tasking_test_u54 \
        istack_overflow_tasking_test_e51 istack_overflow_tasking_test_u54 \
        istack_halt_tasking_test_e51 istack_halt_tasking_test_u54 \
        istack_tiny_tasking_test_e51 istack_tiny_tasking_test_u54
