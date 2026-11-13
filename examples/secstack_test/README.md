# secstack_test, secstack_light_test and secstack_tasking_test

The secondary stack of the three runtime profiles of `crates/mpfs_rts`: the stack on which Ada returns a result of a
size that the caller does not know (a `String` of a computed length). See "Secondary stack" in
`crates/mpfs_rts/README.md`. One test per profile, because the default size and the way an overflow ends differ:

| Example | Profile | Default size | An overflow ends |
|---|---|---|---|
| `secstack_light_test` | `light` | 16 KiB | in the last chance handler of the test |
| `secstack_tasking_test` | `light-tasking` | 8 KiB | in the last chance handler of the test (the profile does not propagate exceptions) |
| `secstack_test` | `embedded` | 16 KiB | in `Storage_Error`, which the test handles; a task has the size of its `Secondary_Stack_Size` aspect (4096) |

The sources are shared: `secstack_test/src` has `Secstack_Cases` (the functions with a result of unknown size and
`Exhaust`), `Secstack_Worker` (the task, whose body for `light-tasking` is in `secstack_tasking_test/src`) and
`Secstack_Last_Chance`; the other two projects name that directory.

| Check | In | What it proves |
|---|---|---|
| a `String` of 1000 characters, two joined, one computed from its length, an empty one | all | the results are right |
| 20 levels of functions with a result of unknown size that call such a function: right, and the stack is where it was after the statement; the high-water mark covers the deepest point | all | the stack is balanced, `SS_Get_Max` |
| `Exhaust` takes 256 bytes at a time until the stack is exhausted: the bytes taken are the default of the profile (to 512 bytes) | all | the default size per profile, set by `gen_runtime.sh` |
| the exhausted stack raises `Storage_Error` (handled here); the stack is usable again after `SS_Release`, and balanced | `embedded` | the bounds check of `SS_Allocate` |
| the last chance handler is called once, with the place of the raise | `light`, `light-tasking` | the same check where there is no propagation |
| a task with a stack of its own works while the environment task works too, with results that stay right; its stack has the size of its aspect (4096 bytes), overflows without touching the stack of the environment task, and is usable again | `embedded` | per-task stacks |
| the same, without the overflow | `light-tasking` | per-task stacks |

The images report as `<example>_e51` and `<example>_u54` (hart 1); the rows are in `tests/qemu/tests.list` and
`console.expected` of each example makes the host assert the `ok:` lines. The projects set no binder switch `-D`: the
default size is what is tested.

    ./x build secstack_test --hart e51 ; ./x build secstack_test --hart u54
    ./x build secstack_light_test --hart e51 ; ./x build secstack_tasking_test --hart u54
    ./x test qemu tests secstack_test_e51 secstack_light_test_e51 secstack_tasking_test_e51
