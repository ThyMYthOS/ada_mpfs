# tasking_test

The smallest program that needs the tasking runtime, and the example that proves the variant build of
`crates/mpfs_rts` (work package P1.2): a periodic library-level task (`Ticker.Worker`, 10 ms, with its own
4 KiB stack) and an environment task that sleeps. It prints nothing and is not run yet: the runtime has
no PLIC or tick of its own until P1.4 to P1.6. Since P1.3 it boots with the runtime's own `start.S` and
`ld/place-lim.ld` (partition data by `crates/mpfs_rts/mpfs_link.gpr`). The real
`tasking_test` of P1.13 (`delay until`, priority order, `Clock`, `Test_Report`) replaces it.

`example.conf` has `RUNTIME=mpfs_rts`, so `./x build` builds the runtime variant first (only if its inputs
changed) and `app.gpr` links with it through `Mpfs_Rts.Runtime_Path`:

    ./x build tasking_test -P light-tasking --hart e51    # build/rts/light-tasking-e51-cpus1-m/
    ./x build tasking_test -P light-tasking --hart u54    # build/rts/light-tasking-u54-cpus1-m/

`-P light` does not build: the light runtime has neither tasking nor `Ada.Real_Time`.
