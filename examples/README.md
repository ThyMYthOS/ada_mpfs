# `examples/`

- **Purpose:** Example programs (template: `examples/STYLE.md`).
- **Owning phase:** P0.7 onwards
- **License:** Apache-2.0

`./x list` prints the examples with their default hart; `./x new <name>` scaffolds a new one. The
conventions (project layout, scenario variables, `example.conf`) are in `STYLE.md`.

| Example | Harts | What it does | Checked by |
|---|---|---|---|
| `bare_hello` | E51, U54 | The smallest image there is, without runtime: prints `bare hello E51 hart 0` or `bare hello U54 hart 1` on MMUART0. | `./x test qemu` (smoke), `./x test renode`, `./x test negative`, `metrics.golden` |
| `pmp_probe` | E51, U54 | Counts the PMP entries of the hart that runs it and prints the count and a mask. | `./x test qemu` (smoke), `./x test renode` |
| `report_test` | E51, U54 | The first application of the `Test_Report` protocol: checks the hart id, the compressed extension and the F and D extensions of the hart class. | `./x test qemu` (`tests/qemu/tests.list`) |
| `common/` | | Not an example: the linker scripts and the build script that the examples share (see its `README.md`). | |

Run an example under QEMU with `./x qemu <name> [--hart N]`, or on the Icicle Kit with
`./x hw run <name> --uart-standin --expect REGEX` (`--uart-standin` because nothing sets the UARTs up in
boot mode 0; see `hw/README.md`). The bare images are linked into the L2 LIM and are loaded by
OpenOCD; none of them is placed in the eNVM yet.
