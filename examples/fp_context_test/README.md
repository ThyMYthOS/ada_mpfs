# fp_context_test

Regression test for defect no. 1 of the master plan (work package P1.5 of #41): the callee-saved floating-point registers
`fs0` - `fs11` belong to the task. The upstream `context_switch.S` saved them to the context of the outgoing task and
then loaded them from the same context (`t0`) instead of the one of the incoming task (`a1`): every task that was
switched in got the registers of the task that was switched out. U54 only: the E51 has no FPU, its context and its trap
frame have no f registers (`float_test` covers its floating point).

| Task | Priority | What it does | Path through the runtime |
|---|---|---|---|
| `Holder_A`, `Holder_B` | 10 | load a different value into each of `fs0` - `fs11`, `delay until` 2 ms later, check them, again with new values (about 145 rounds each in 300 ms) | `delay` calls `Context_Switch`; the other task runs, and loads its own values, in between |
| `Spinner` | 5 | loads the registers and checks them in a loop that never waits (6000 or more checks) | the timer interrupt that wakes A or B takes it away through the trap handler (trap frame, then the context switch from the trap) and gives it back the same way |

The environment task lets them run for 300 ms, stops them and reports. A check is `Fp_Regs.Mismatch`: bit *i* is set if
`fs`*i* is not `Seed + i * Step`. The values are bit patterns moved with `fmv.d.x` and `fmv.x.d` (no arithmetic, no
canonical NaN); the seeds differ per task and per round.

`Fp_Regs.Load` is deliberately not ABI-clean: it changes registers that are the caller's and does not tell the compiler
(a clobber list would make GCC save and restore `fs0` - `fs11` around it and undo it). That is safe because no unit of the
program computes with a `Float` or `Long_Float`; `tests/host/rts_context` checks on the disassembly of the image that the
f registers are used only by `Fp_Regs`, the context switch and the trap handler.

| Check | What it proves |
|---|---|
| all three tasks ended | the program ran to its end |
| A and B each checked 20 times or more, the spinner 2000 times or more | the switches happened (the test is not vacuous) |
| A, B and the spinner lost no register | `fs0` - `fs11` are restored from the context of the incoming task, also through the trap |

Result with the fixed `context_switch.S`: all three masks 0. Result with the upstream restore (`FLREG ... (t0)`): all three
masks `4095` (all twelve registers lost) and the test reports `FAIL`; the host suite `tests/host/rts_context` keeps that
control as a disassembly check.

    ./x build fp_context_test              # bin-u54/ (hart 1)
    ./x test qemu tests fp_context_test_u54

The image reports as `fp_context_test_u54`; `console.expected` makes the host assert the `ok:` lines.
