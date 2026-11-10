# protected_test

Protected objects and timing events of the tasking runtime, on the hart of the image (E51 hart 0, U54 hart 1),
linked with the `light-tasking` runtime variant. The `embedded` profile has the same program in
`protected_embedded_test`.

| Check | What it proves |
|---|---|
| `Gate.Wait` (barrier `Opened`) called by `Waiter` | the caller waits while the barrier is false, is let through after `Open` and not before |
| `Stock.Take` called by `Consumer`, `Stock.Put` | one item per `Put` is taken, the consumer waits again at an empty stock, two items put are two items taken |
| `Timing_Events.Set_Handler` 40 ms ahead | the handler (a protected procedure of ceiling `Interrupt_Priority'Last`) has not run after 20 ms, has run once after 100 ms and not before its time; the event has no handler afterwards |
| `Cancel_Handler` | a pending event is cancelled and does not run |

The objects and the tasks are at library level in `Gates` (Ravenscar: one entry per object, a barrier that is one Boolean
variable). The bounds are wide: QEMU's `mtime` follows the host clock. Reported with `Test_Report` as
`protected_test_e51` or `protected_test_u54`; `console.expected` makes the host assert the `ok:` lines.

    ./x build protected_test --hart e51    # bin-e51/
    ./x build protected_test --hart u54    # bin-u54/
    ./x test qemu tests protected_test_e51 protected_test_u54
