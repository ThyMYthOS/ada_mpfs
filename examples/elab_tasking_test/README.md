# elab_tasking_test

The checks of `elab_test` (sources of `examples/elab_test/src`: the order of elaboration and the values of three
dependent units) and a library-level task, with the `light-tasking` runtime. The task (`Elab_Tasks.Worker`) has the highest
priority and notes itself in the log in the declarative part of its body, which is elaborated when it is activated.
The main program checks that this happened before it started, after the units of the chain (log position 4), and
that the statements of the task have run. A task of a lower priority than the main program starts when the main
program waits, not before.

The `embedded` profile has the same program in `elab_embedded_test`. Reported with `Test_Report` as
`elab_tasking_test_e51` or `elab_tasking_test_u54`; `console.expected` makes the host assert the `ok:` lines.

    ./x build elab_tasking_test --hart e51    # bin-e51/
    ./x build elab_tasking_test --hart u54    # bin-u54/
    ./x test qemu tests elab_tasking_test_e51 elab_tasking_test_u54
