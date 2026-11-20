# pmp_probe

Counts the PMP entries of the hart that runs it. `pmp_mask.S` writes a pattern of ones to each of
`pmpaddr0` to `pmpaddr15`, reads it back and clears it again; `pmpaddr` is WARL, so an entry that does
not exist reads back zero. The image prints

    pmp probe hart <n>
    pmp entries <count>
    pmp mask 0x<one bit per entry that held the pattern>
    pmp pmpaddr0 ones 0x<pmpaddr0 after all ones (64 bits) were written to it>
    pmp pmpaddr width <the number of its highest bit set, plus one>

It is built like `bare_hello` (it shares `start.S` and `Bare_Console` with it) for the E51 and the U54.
The directory also holds what the PMP tests (`pmp_xml_test`, `pmp_access_test`, `apb_window_test`) share:
`Pmp_Csr` (`src/pmp_csr.ads`, the CSRs by number with `pmp_regs.S`, the encodings, the count and the
granularity), and `pmp_try.S` (one load, store or fetch in M or U mode that returns the `mcause` of its
access fault; the pages the access test configures). The image of `pmp_probe` uses only `pmp_mask.S`.
[`docs/assurance/pmp-tests.md`](../../docs/assurance/pmp-tests.md) describes the tests.

| Where | Entries |
|---|---|
| QEMU 10.1.0, `microchip-icicle-kit`, E51 and U54 | 8 (mask `0x00ff`) |
| Renode 1.17.0, `mpfs-icicle-kit.repl` of that release, E51 and U54 | 16 (mask `0xffff`) |

The two models disagree, so the number of entries a test can rely on is the smaller one. The value on
the hardware is not measured here. `tests/qemu/smoke.expected` pins the QEMU value.

    ./x build pmp_probe [--hart u54]
    ./x qemu pmp_probe
