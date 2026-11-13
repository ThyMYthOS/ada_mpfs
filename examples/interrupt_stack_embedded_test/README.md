# interrupt_stack_embedded_test

The interrupt stack of the runtime in the `embedded` profile, and the guard word at its lower end (issue #91). The
interrupt stack is where a trap or an interrupt runs; the `embedded` runtime makes libgcc sort its frame descriptions at the
first exception of a program, and when that exception is the one of a trap, the unwinder runs on it. The example has three
images, one project (the images are `bin-e51/` and `bin-u54/` `<image>.elf`):

| Image | What it shows |
|---|---|
| `istack_peak_embedded_test` | The first exception in a trap: the program paints the interrupt stack (`Istack.Paint`), executes the illegal instruction of `examples/trap_test` (`fault.S`, shared) and ends in the last chance handler of the test (`Istack_Handler`), which reads the high-water mark after it has reported. It checks that the trap ends as `Program_Error` with the message of the cause, reports the size of the stack and the peak in bytes (`info:` lines) and checks that the peak is at most two thirds of the stack: the margin of 50 % that the default size is derived from. |
| `istack_overflow_embedded_test` | An overrun is found at the exit of a trap and ends in a message. Built with a stack of 2048 bytes (the `IMAGE_` line of `example.conf`). The handler of a timing event runs in the interrupt context, on the interrupt stack; `Istack.Overrun` takes a frame as large as the whole stack, which reaches below its lower end, and overwrites the guard word, nothing else. The trap handler finds the word when the handler returns, and the last chance handler of the test receives `Program_Error` with the message `interrupt stack overflow`. The main program busy-waits for the event instead of `delay until`: an alarm that finds the idle task running would raise the exception in a thread that has no secondary stack, which `Exception_Message` needs. |
| `istack_halt_embedded_test` | The runtime's own last chance handler (this image has none) prints `interrupt stack overflow` and stops when the guard word has been overwritten (`Istack.Clobber_Guard`), then the illegal instruction: the trap handler raises, nothing returns through the exit of the trap, and the handler of the runtime is where it is found. It cannot report with `Test_Report` (a handler of its own would not be the runtime's): the row of `tests/qemu/tests.list` is a `console` row, which reads the line from the serial port. |

The sizes and the peak are in `crates/mpfs_rts/README.md`, section "Interrupt stack". To measure the peak, build the image with
a stack that is certainly large enough and read the `info:` line:

    ./x build interrupt_stack_embedded_test --hart u54 --interrupt-stack-size 65536
    qemu-system-riscv64 -M microchip-icicle-kit -smp 5 -m 2G -nographic -serial mon:stdio -bios none \
        -kernel examples/interrupt_stack_embedded_test/bin-u54/istack_peak_embedded_test.elf -no-reboot

The report goes to MMUART0 (`Bare_Console`), also on the U54; the console of the runtime is the MMUART of the hart (MMUART1
on U54 hart 1), where the `halt` image writes. The name of a test in the report is the one of the image with `_e51` or
`_u54`. `examples/interrupt_stack_tasking_test` is the same set in the `light-tasking` profile, with one more image.

    ./x build interrupt_stack_embedded_test --hart e51    # bin-e51/
    ./x build interrupt_stack_embedded_test --hart u54    # bin-u54/
    ./x test qemu tests istack_peak_embedded_test_e51 istack_peak_embedded_test_u54 \
        istack_overflow_embedded_test_e51 istack_overflow_embedded_test_u54 \
        istack_halt_embedded_test_e51 istack_halt_embedded_test_u54
