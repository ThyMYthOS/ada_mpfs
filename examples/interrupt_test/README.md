# interrupt_test

The PLIC and the CLINT of the runtime `crates/mpfs_rts` are those of the hart that runs the image,
not of hart 1. It links with the `light-tasking` runtime and uses the PAC (`mpfs_pac.gpr`).

| Check | What it proves |
|---|---|
| `Context_Of` for harts 0 to 4 is 0, 1, 3, 5, 7 | hart 0 is context 0 (the E51 has no S mode), hart n is 2n-1 |
| `Enable_Address`, `Threshold_Address`, `Claim_Address` of every hart are `ENABLE_H<n>_M`, `THRESHOLD_H<n>_M`, `CLAIM_COMPLETE_H<n>_M` of the PAC | the runtime reaches the registers of the SVD, base plus context (`PLIC_View` is the independent way, a `case` over the five harts) |
| the source 90 (MMUART0) is enabled in the context of this hart and in no other | `Attach_Handler` goes to the own context |
| the priority of the source is the ceiling of its handler | `Set_Priority` |
| the threshold of this hart is 0 outside and the ceiling inside a protected object | `Set_Current_Priority` writes the own context |
| the handler (`UART_Rx.Receiver`, `Attach_Handler => 90`, ceiling `Interrupt_Priority'First + 2`) gets `console.in` byte for byte, and the source is not pending afterwards | an external interrupt reaches the hart through its own PLIC context, claim and complete work |
| the generated names are the PLIC source numbers: `Names.L2_METADATA_CORR` is `Interrupt_ID'First` (1), `Names.U54_4_BUS_ERROR_UNIT` is `Interrupt_ID'Last` (186), `Names.MMUART0` is 90; 0 and 187 are not an `Interrupt_ID`, 1, 90 and 186 are (a run-time membership test, the negative test of the bounds on the target; the compile-time one is in `tests/host/rts_intnam`) | `crates/mpfs_rts/gen_intnam.py`, `Interrupt_Range` of `s-bbpara`; the handler is attached to the generated name `Names.MMUART0` |
| the seven interrupt priorities are the PLIC levels 1 to 7 and a task priority is level 0; the threshold of this hart is the level of the priority set, for each of the seven and for a task priority, read from the register and through `Threshold` | `RISCV_PLIC.Level_Of`, `Set_Priority_Threshold`, `Threshold` |
| `msip` of this hart reads set, then clear after `Clear_MSIP`; `mtime` runs | `System.BB.RISCV_CLINT` |
| the `mtimecmp` of the other harts is untouched | the runtime no longer writes the `mtimecmp` of hart 1 (QEMU: 0 after reset) |

The "no other context" and "other `mtimecmp` untouched" checks rely on QEMU's reset state (all zero); on the board the
enables, thresholds and `mtimecmp` have no defined value at power-up, so the build for the board (`RX_SOURCE=loopback`, `Reset_State_Known = False`) does not rely on them.

The image reports as `interrupt_test_e51`, `interrupt_test_u54` (hart 1) or `interrupt_test_u54h3` (the image of hart 3,
`bin-u54-h3/`). `console.in` feeds the bytes `plic` and a line feed to MMUART0 (the runner starts QEMU with `-chardev
file,input-path=...`); `console.expected` makes the host assert the `ok:` lines.

    ./x build interrupt_test --hart e51
    ./x build interrupt_test --hart u54 --harts 3
    ./x test qemu tests interrupt_test_e51 interrupt_test_u54 interrupt_test_u54h3

Under QEMU the received-data interrupt of the UART comes up as soon as `IER.ERBFI` is set (the byte is waiting in `RBR`),
and a level interrupt: the handler reads `RBR` until `LSR.DR` is clear, which lowers the PLIC source. QEMU's default
machine has only the E51 and one U54, so `tests/qemu/run_tests.sh` starts it with `-smp 5` and the image of hart 3 runs.
