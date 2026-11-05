# console_none_test

The console `none` of the runtime `crates/mpfs_rts`: `__mpfs_console_base` is 0 and `System.Text_IO.Put` has no effect.
Linked with the `light` runtime. The report cannot use the console of the runtime, so it goes out on the polled MMUART0
of `examples/bare_hello` (`Bare_Console`), like the other tests.

| Check | What it proves |
|---|---|
| `Initialize` sets `Initialized` and writes no register, not even of MMUART0 (a value in its DFR stays) | `__mpfs_console_init = 1` does nothing for a console that is none |
| `Is_Tx_Ready` is true, `Is_Rx_Ready` is false, `Get` returns NUL | the status of a console that is not there |
| `Put` of a text that looks like a failure of this test writes nothing | `tests/qemu/run_tests.sh` fails a test on a `  FAIL:` line of its port, so a driver that fell back to MMUART0 fails the test |

The image reports as `console_none_test_e51` or `console_none_test_u54`.

    ./x build console_none_test --hart e51
    ./x test qemu tests console_none_test_e51 console_none_test_u54

On the board the report needs MMUART0 set up (`./x hw run console_none_test --uart-standin`).
