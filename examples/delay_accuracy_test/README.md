# delay_accuracy_test

The tickless timer and the idle of the runtime `crates/mpfs_rts`. The accuracy of `delay until` is a
hardware measurement (`delay_accuracy_test` on the Icicle Kit, results in `docs/lab/results/p1.md`); under QEMU the test builds, runs, reports the
numbers and asserts what QEMU can decide (only the accuracy bound is loose there, the rest of the test is the same). It links with the `light-tasking` runtime and the PAC (`mpfs_pac.gpr`).

| Check | QEMU | Board | What it proves |
|---|---|---|---|
| `mtimecmp` of this hart is the maximum and `mip.MTIP` is clear at the start | yes | yes | the timer is disarmed before it is first used (no stale `mtimecmp`, no spurious tick) |
| while the main program sleeps (a task of lower priority looks), `mtimecmp` of this hart is its alarm, exactly | yes | yes | tickless: `mtimecmp` is the next alarm of the own hart |
| after the wake-up `mtimecmp` is the maximum and `MTIP` is clear | yes | yes | the interrupt is acknowledged by writing the maximum, nothing else is armed |
| `delay until` is never early (`mtime` read through the PAC, not `Clock`, against the requested instant) | yes | yes | no early wake-up |
| the deviation of `delay until` (1, 2, 5, 10 and 50 ms, 10 or 50 rounds each) is at most `Max_Late_Ticks` | 20 ms | 2 ticks + latency (20 ticks) | the accuracy of `delay until` |
| `delay until` in the past returns at once and arms nothing; a timing event in the past runs at once | yes | yes | an alarm in the past is pending immediately and handled, no hang, no extra tick |
| the alarm interrupt while every task sleeps finds the hart in `wfi` (the instruction in front of the interrupted pc, `mepc`, is `wfi`) | yes | yes | `Power_Down` is `wfi`: with a `null` `Power_Down` it fails (checked by building the runtime that way) |
| `minstret` over a 100 ms delay with every task asleep is at most 20 000 | reported only | yes | the hart does not execute instructions while idle |
| `Standalone_Clocks`: `Ada.Real_Time.Time_Unit * Clocks.Rtc_Toggle_Hz = 1.0` | compile time | compile time | `Clock_Frequency` of the runtime is the RTC clock of the partition (see below) |

The `info:` lines carry the numbers (`late min/avg/max` in ticks of 1 us, `mcycle` and `minstret` over the idle delay and
the cycles per `mtime` tick). QEMU's `mcycle` and `minstret` are the host's time stamp counter, not counters of the guest:
they run in `wfi` as well, so QEMU cannot show idle by counting, which is why the `mepc` check exists. The limits are the file
`accuracy_limits.ads` of `src/qemu/` (default) or `src/hardware/`:

    ./x build delay_accuracy_test --hart e51                            # QEMU limits
    DELAY_ACCURACY=hardware ./x build delay_accuracy_test --hart u54    # the limits of the board

`Interrupt_Latency_Ticks` (18) was calibrated on the Icicle Kit: the largest deviation of a `delay until` on the E51 and on U54 harts 1 to 4 was 15 ticks, see `docs/lab/results/p1.md`.

The image reports as `delay_accuracy_test_e51`, `delay_accuracy_test_u54` (hart 1) or `delay_accuracy_test_u54h3` (the image
of hart 3, `bin-u54-h3/`); the rows are in `tests/qemu/tests.list`, `console.expected` makes the host assert the `ok:` lines.

    ./x test qemu tests delay_accuracy_test_e51 delay_accuracy_test_u54 delay_accuracy_test_u54h3

## `Clock_Frequency` and `Clocks.Rtc_Toggle_Hz`

The runtime fixes `Clock_Frequency` to 1 MHz (`System.BB.Board_Parameters`), and `Ada.Real_Time.Time_Unit` is `1.0 / Clock_Frequency`.
The partition package that `config/gen/standalone.py` writes has no clock yet; `src/standalone_clocks.ads` is the stand-in and has the check that
the generated package is to have, in the form that needs nothing but the public `Ada.Real_Time`:

    pragma Compile_Time_Error
      (Ada.Real_Time.Time_Unit * Clocks.Rtc_Toggle_Hz /= 1.0, "...");

`tests/host/rts_tick` compiles it with 1 MHz (must compile) and with 2 MHz and 999 999 Hz (must fail with the message). What
is missing: the generated package must carry `Clocks.Rtc_Toggle_Hz` (the standalone default, 1 MHz) and the same pragma. The runs on the Icicle Kit measured `mtime` against the host clock and `mcycle`: it counts at 1 MHz (997,252 ticks per second over 20 s, 79 `mcycle` per tick
at 80 MHz) with `RTC_CLOCK_CR.PERIOD` 125 that `./x hw initialize` writes, so the reference clock is 125 MHz, not 100 MHz (see `docs/lab/icicle.md`).
