# exceptions_test

Zero-cost exceptions (R8) of the `embedded` runtime of `crates/mpfs_rts`, work package P1.7. The unwinder of libgcc
finds the frame descriptions of `.eh_frame` through a registration that the start code triggers (`crtbegin.o`,
`.init_array`, `start.S`), not through `.eh_frame_hdr`, which the linker of the toolchain cannot make; see
`crates/mpfs_rts/README.md` and `docs/design/exceptions.md`. One project, three images:

| Image | What it shows |
|---|---|
| `exceptions_test` | The positive test, 16 checks. |
| `unhandled_test` | An exception that nobody handles leaves the environment task and ends in the last chance handler. |
| `unhandled_task_test` | An exception that a task does not handle ends in the last chance handler too. |

`exceptions_test` checks

| Check | What it proves |
|---|---|
| the entries of `.preinit_array` and `.init_array` (`ctor.S`, as `__attribute__((constructor))` makes them) ran in this order before `main` | `start.S` calls the constructor arrays; the same mechanism runs `frame_dummy` of `crtbegin.o`, which registers `.eh_frame` |
| raise and handle in one frame; propagation through five frames, the code after the raising call does not run | the unwinder finds the FDEs and the landing pads |
| `Exception_Name`, `Exception_Message`, `Exception_Information` (`raised CASES.OTHER : the message`) | the occurrence |
| `raise;` in a handler and `Reraise_Occurrence` of a saved occurrence | the occurrence stays the same one |
| division by zero and a range check raise `Constraint_Error`; `Program_Error` with a message | the checks of the language end in the same propagation |
| three nested controlled objects are finalized in reverse order while `Other` propagates, and in the same order without an exception | cleanup landing pads (finalization during propagation) |
| an exception raised in a handler replaces the one being handled | |
| a task raises an exception through four frames and handles it itself | propagation on the stack of a task, with the secondary stack of the task |

`unhandled_test` and `unhandled_task_test` replace the last chance handler of the runtime (which prints the
exception on the console and stops the machine) by `Last_Chance.Handler`, which checks what it receives (once, the
identity and the message) and reports. They fail if the exception is handled or lost: after the call that raises, or
after a second of waiting in the environment task, the test reports a failing check.

The images report as `<image>_e51` and `<image>_u54` (hart 1), the rows are in `tests/qemu/tests.list`.
`console.expected` makes the host assert the `ok:` lines of `exceptions_test`; `unhandled_test.expected` and
`unhandled_task_test.expected` those of the two others (an `<image>.expected` replaces `console.expected` for its
image).

    ./x build exceptions_test --hart e51         # bin-e51/{exceptions_test,unhandled_test,unhandled_task_test}.elf
    ./x build exceptions_test --hart u54         # bin-u54/
    ./x test qemu tests exceptions_test_e51 exceptions_test_u54 unhandled_test_e51 unhandled_test_u54

The default stacks of the embedded profile (1 MiB secondary stack, 2 MiB per task) do not fit the 1920 KiB LIM, so
`app.gpr` sets the binder switch `-D8k` and the tasks have `Storage_Size` and `Secondary_Stack_Size` aspects. The
first raise uses `malloc` once (libgcc sorts the frame descriptions; without memory it searches them linearly), so
the heap must exist: the runtime's `s-memory` and newlib's `malloc` over `__heap_start` .. `__heap_end`.
