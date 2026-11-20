# apb_window_test

The LO and HI windows of the APB peripherals under `SYSREG.APBBUS_CR`, and whether one PMP entry per AMP
context of the MSS Configurator separates the peripherals of the two contexts. `APBBUS_CR` maps a peripheral
into the LO window (`0x2000_0000`, AXI bus 5) or the HI window (`0x2800_0000`, AXI bus 6). After the MSS TRM a
peripheral accessed in the wrong window answers with an AXI response error; on the Icicle Kit no such access
faulted, a read there answered 0 and a write there had no effect. The test checks that measured behaviour,
with a non-zero pattern written through the right window first, on the scratch register `SR` of MMUART3 and
MMUART2, `TIM1LOADVAL` of the timer and `COMPARE_LOWER` of the RTC:

0. whether `APBBUS_CR` holds the bit of MMUART3; the Bus Error Unit of the hart as found, then set to record a
   TileLink bus error and raise its PLIC source;
1. all in LO: each register holds a write at LO; at HI a read does not return it and a write does not change it;
2. MMUART3 in HI, where `APBBUS_CR` holds the bit: the same with LO and HI swapped, the LO write with the posted
   mode of the AHB-APB bridges (`AHBAPB_CR`) off and on; MMUART2, left in LO, at its HI address;
3. RTC and timer in HI (`0x2812_4000`, `0x2812_5000`): they hold a write at HI; at LO a read does not return it
   and a write does not change it;
4. in U mode with one NAPOT entry RW over the 256 KiB at `0x2010_0000` (context A, LO) or `0x2810_0000`
   (context B, HI): the own peripheral answers, the other window faults (5, 7) (checked); the other context's
   peripheral at the address in the own window (measured);
5. `APBBUS_CR`, `AHBAPB_CR`, the Bus Error Unit and the PMP back as they were.

Each access is an `info:` line, "answers" with the value read or "access fault" with the `mcause`, announced by
a `next:` line so that a hang shows where it stopped. After each access in the wrong window, a line says
whether it faulted (`wrong window, fault yes|no`, not a check) and one reports `mip`, the PLIC pending bits of
the bus error sources 182 to 186 and the `cause`, `value` and `accrued` of the Bus Error Unit
(`errors after ...`). Neither QEMU nor Renode models `APBBUS_CR`, the HI window or the Bus Error Unit: there
steps 2 and 3 are left out and the test says so; QEMU does not model RTC and timer either. It reports
`apb_window_test_e51`, `apb_window_test_u54` (hart 1) or `apb_window_test_u54h<N>` (harts 2 to 4).

    ./x build apb_window_test [--hart u54]
    ./x qemu apb_window_test [--hart 1|2|3|4]

It is built like `bare_hello`, with `Pmp_Csr`, `pmp_mask.S` and `pmp_try.S` of `pmp_probe`. See
[`docs/assurance/pmp-tests.md`](../../docs/assurance/pmp-tests.md), "AMP contexts and `APBBUS_CR`".
