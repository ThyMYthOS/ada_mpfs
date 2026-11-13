# interrupt_stack_tasking_test

The `interrupt_stack_embedded_test` of the `light-tasking` profile: the sources are those of
`examples/interrupt_stack_embedded_test/src`, linked with the `light-tasking` runtime variant of `crates/mpfs_rts`. The
profile has no exception propagation: the trap handler raises `Program_Error`, which is a direct call of the last chance
handler with the message as a C string, so the unit `Istack_Handler` of this example (`src/istack_handler_tasking.ad[sb]`)
differs, and so does the name of the test (`src/test_name_tasking.ads`, see "Profile variants" in `examples/STYLE.md`):
the report reads `interrupt_stack_peak_tasking_test_e51` or `_u54`. What the test checks is in the README of
`examples/interrupt_stack_embedded_test`. The program uses `Ada.Real_Time`, which links the tasking part of the runtime
and with it the trap handler and the interrupt stack (a `light-tasking` program that uses none has no interrupt stack).

    ./x build interrupt_stack_tasking_test --hart e51    # bin-e51/
    ./x build interrupt_stack_tasking_test --hart u54    # bin-u54/
