# elab_test

The elaboration of the units of a program before its main procedure runs, with the `light` runtime (the constructors
of the runtime and the order of elaboration that the binder computes). Three units depend on each other: `Elab_A`,
`Elab_B` (which `with`s `Elab_A`) and `Elab_C` (which `with`s `Elab_B`). Each has `pragma Elaborate_Body`, notes itself in
`Elab_Log` when its body is elaborated, and a value that is computed from the one of the unit before when its specification is
elaborated (42, 43, 86). The main program checks

- every unit has been elaborated, in the order of the dependences (log positions and the log count at each body);
- the three values, which are only right if each unit was elaborated after the one it uses;
- nothing else noted itself.

The same sources, plus a library-level task, are `elab_tasking_test` (`light-tasking`) and `elab_embedded_test`
(`embedded`). Reported with `Test_Report` as `elab_test_e51` or `elab_test_u54`; `console.expected` makes the host
assert the `ok:` lines.

    ./x build elab_test --hart e51    # bin-e51/
    ./x build elab_test --hart u54    # bin-u54/
    ./x test qemu tests elab_test_e51 elab_test_u54
