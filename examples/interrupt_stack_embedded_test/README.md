# interrupt_stack_embedded_test

The peak use of the interrupt stack of the first exception that is raised in a trap handler, in the `embedded` profile
(issue #91). The program paints the interrupt stack (`Istack.Paint`), executes the illegal instruction of
`examples/trap_test` (`fault.S`, shared) and ends in the last chance handler of the test (`Istack_Handler`), which
reads the high-water mark after it has reported (`interrupt_stack_peak_test`):

- the trap ends as `Program_Error` with the message of the cause (`Unhandled trap: 2`);
- the report says the size of the stack and the peak in bytes (`info:` lines);
- the peak is at most two thirds of the stack, that is the stack has a margin of 50 % over the peak.

The `embedded` runtime makes libgcc sort its frame descriptions at the first exception of a program; that is the deepest
use of the stack, and it happens on the interrupt stack when the exception is the one of a trap. The numbers, and what
they led to, are in `crates/mpfs_rts/README.md`, section "Interrupt stack". To measure the peak, build the image with a
stack that is certainly large enough and read the `info:` line:

    ./x build interrupt_stack_embedded_test --hart u54 --interrupt-stack-size 65536
    qemu-system-riscv64 -M microchip-icicle-kit -smp 5 -m 2G -nographic -serial mon:stdio -bios none \
        -kernel examples/interrupt_stack_embedded_test/bin-u54/interrupt_stack_peak_embedded_test.elf -no-reboot

The report goes to MMUART0 (`Bare_Console`), also on the U54. The images are `bin-e51/` and `bin-u54/`
`interrupt_stack_peak_embedded_test.elf` (the name in the report is that of the image with `_e51` or `_u54`).
`examples/interrupt_stack_tasking_test` is the same test in the `light-tasking` profile.

    ./x build interrupt_stack_embedded_test --hart e51    # bin-e51/
    ./x build interrupt_stack_embedded_test --hart u54    # bin-u54/
