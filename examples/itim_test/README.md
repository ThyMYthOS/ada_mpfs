# itim_test

The copy step of `start_fast.S` for code and data that an application runs from the local memories of its hart (ITIM,
and on the E51 DTIM). The application owns the sections: `ld/app-sections.ld` is its hook (`MPFS_APP_LD` of
`crates/mpfs_rts/mpfs_link.gpr` is not needed, the project puts `-L ld` ahead of the runtime's and appends `Mpfs_Link.Fast_Switches`, which links `start_fast.S`); the runtime declares
none and only copies what the symbols `__fast_text_start`, `__fast_text_end`, `__fast_text_load` and the same for
`__fast_data` name. See "ITIM and DTIM" in `crates/mpfs_rts/README.md`.

QEMU does not model the ITIM, so here the code and the data run from the L2 LIM, 1 MB above its start, and are loaded
behind `.sdata2`: the copy step and the check are the same, the addresses are not those of the ITIM.
`examples/itim_reject_test` has the real ITIM.

| Check | What it proves |
|---|---|
| both ranges are not empty; `Fast.Add` (`Linker_Section => ".fast_text"`) and `Fast.Table` (`".fast_data"`) lie in them | the sections of the hook receive the objects |
| the run addresses differ from the load addresses | a copy was needed |
| the bytes of the code at the run address equal those at the load address | the copy |
| `Add (40, 2) = 42`, `Table` has its initial values and is writable | the hart runs the copied code (`fence.i`) and uses the copied data |

Reported as `itim_test_e51`.

    ./x build itim_test
    ./x test qemu tests itim_test_e51
