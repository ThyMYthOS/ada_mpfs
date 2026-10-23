# tasking_test

The tasking runtime of `crates/mpfs_rts` runs on the hart of the image: the timer of that hart wakes tasks up. Until
work package P1.4 the runtime had hart 1 hard-wired (its `mtimecmp` at `0x4008`, its PLIC context) and this program
only had to link; since then the timer is `mtimecmp (mhartid)` and the test runs under QEMU on hart 0 (E51), hart 1 and
hart 3 (U54). The program of P1.2 (a periodic task and an environment task that sleeps, no output) is now the test that
reports with `Test_Report`; the full test of work package P1.13 (`delay_accuracy_test`, `protected_test`, ...) adds to
it.

| Check | What it proves |
|---|---|
| two tasks (priority 10 and 5) wait for the same instant (`Order`) | both wake up, none before its time, the higher priority runs first |
| `delay until Clock + 20 ms` | returns at or after the time, and within 500 ms |
| `Clock` | advances |
| `Ticker.Worker` (periodic, 10 ms, priority 10) over 200 ms | runs between 12 and 28 times (20 ideally; QEMU's `mtime` follows the host clock, so the bounds are wide) |

The image reports as `tasking_test_e51`, `tasking_test_u54` (hart 1) or `tasking_test_u54h3` (the U54 image of hart 3,
`./x build tasking_test --hart u54 --harts 3` into `bin-u54-h3/`); the rows are in `tests/qemu/tests.list`. `console.expected`
makes the host assert the `ok:` lines. Test_Report and Bare_Console (the polled MMUART0) are shared with the other tests.

    ./x build tasking_test --hart e51            # bin-e51/
    ./x build tasking_test --hart u54            # bin-u54/ (hart 1)
    ./x build tasking_test --hart u54 --harts 3  # bin-u54-h3/
    ./x test qemu tests tasking_test_e51 tasking_test_u54 tasking_test_u54h3

QEMU needs `-smp 5` to have the harts 2 to 4 at all (the default of the machine has the E51 and one U54): `tests/qemu/run_tests.sh`
passes it. `./x qemu tasking_test --hart 3` builds and runs the hart-3 image. `-P light` does not build: the light runtime
has neither tasking nor `Ada.Real_Time`.
