# pmp_isolation_test

The isolation of U mode from M mode by the PMP of the hart that runs it, with locked entries, as an AMP
partition would set it up that runs its application in U mode and its kernel in M mode. The memory is the four
pages of `pmp_pages` and the code pages of `pmp_probe/pmp_try.S` (`pmp_user_page`) and `pmp_isolation.S`
(`pmp_csr_page`):

| Entry | Region | Rights | Locked |
|---|---|---|---|
| 0 | `pmp_user_page`, the code of the U-mode access | R X | yes |
| 1 | `pmp_csr_page`, U-mode code that touches `pmpcfg0` | R X | yes |
| 2 | page 0, the data of the application | R W | yes |
| none | page 1, the data of the kernel | | |

Each case is one load, store or instruction fetch in M or U mode through `pmp_try`, which returns 0 or the
`mcause` of the fault (1 fetch, 5 load, 7 store, 2 illegal instruction).

- U mode reaches its data and nothing else: the kernel's page faults for load, store and fetch (no entry
  matches); the code page cannot be written, the data page cannot be executed.
- U mode cannot read or write `pmpcfg0`: an illegal instruction (`mcause` 2).
- M mode is not subject to what no entry matches (the kernel's page), but the locked entries bind it with the
  rights U mode has: it cannot write the code page and cannot execute the data page.
- M mode cannot change the locked entries (a write to `pmpcfg0` or `pmpaddr2` is ignored); U mode still has
  what it had.
- M mode can open the kernel's page to U mode with an entry that is not locked and close it again.
- A locked entry without rights over the kernel's page locks M mode out as well, until reset.

A locked entry has the same rights in both modes, so what only M mode may reach is a region that no entry
matches (or an entry that is not locked and has no rights); a locked entry cannot give U mode a region and deny
it to M mode.

It needs four entries and a granule of at most 4 KiB. It reports `pmp_isolation_test_e51`,
`pmp_isolation_test_u54` (hart 1) or `pmp_isolation_test_u54h<N>` (harts 2 to 4, board only). The locked entries
hold until reset, so on the board every run starts from a reset.

    ./x build pmp_isolation_test [--hart u54]
    ./x qemu pmp_isolation_test [--hart 1]

It is built like `bare_hello`, with `Pmp_Csr`, `pmp_mask.S` and `pmp_try.S` of `pmp_probe`. See
[`docs/assurance/pmp-tests.md`](../../docs/assurance/pmp-tests.md).
