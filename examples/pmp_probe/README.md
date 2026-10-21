# pmp_probe

Counts the PMP entries of the hart that runs it. `pmp_mask.S` writes a pattern of ones to each of
`pmpaddr0` to `pmpaddr15`, reads it back and clears it again; `pmpaddr` is WARL, so an entry that does
not exist reads back zero. The image prints

    pmp probe hart <n>
    pmp entries <count>
    pmp mask 0x<one bit per entry that held the pattern>

It is built like `bare_hello` (it shares `start.S` and `Bare_Console` with it) for the E51 and the U54.

| Where | Entries |
|---|---|
| QEMU 10.1.0, `microchip-icicle-kit`, E51 and U54 | 8 (mask `0x00ff`) |
| Renode 1.17.0, `mpfs-icicle-kit.repl` of that release, E51 and U54 | 16 (mask `0xffff`) |

The two models disagree, so the number of entries a test can rely on is the smaller one. The value on
the hardware is not measured here. `tests/qemu/smoke.expected` pins the QEMU value.

    ./x build pmp_probe [--hart u54]
    ./x qemu pmp_probe
