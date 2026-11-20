# pmp_access_test

The access semantics of the PMP of the hart that runs it, after the Privileged Spec v1.10, with a
configuration of its own over four pages of 4 KiB (`pmp_pages` of `pmp_probe/pmp_try.S`). Each case is one
load, store or instruction fetch in M or U mode through `pmp_try`, which returns 0 or the `mcause` of the
access fault (1 fetch, 5 load, 7 store); `mtval` is checked for one fault of each kind.

- U mode with NAPOT entries R, RW and X, and where no entry matches (denied); M mode is not subject to
  entries without L.
- TOR over two pages, NA4 on one word; the matching entry with the lowest index decides, also against a NAPOT
  entry RWX in the last entry of the hart.
- L (last, it holds until reset): locked entries apply to M mode; a locked `pmpaddr`, a locked configuration
  byte and `pmpaddr(i-1)` of a locked TOR entry i ignore writes; unlocked entries still take them.

It needs six entries and a granule of at most 4 KiB, and adapts to the number it counts (QEMU 8, Renode 16).
With G > 0 the NA4 cases are left out. It reports `pmp_access_test_e51` or `pmp_access_test_u54`.

    ./x build pmp_access_test [--hart u54]
    ./x qemu pmp_access_test [--hart 1]

It is built like `bare_hello`, with `Pmp_Csr`, `pmp_mask.S` and `pmp_try.S` of `pmp_probe`. See
[`docs/assurance/pmp-tests.md`](../../docs/assurance/pmp-tests.md).
