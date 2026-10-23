# ada_mpfs

Bare-metal Ada for the Microchip PolarFire SoC (MPFS): runtime, PAC, HAL, bootloader and generator.

Status: **P0 (foundation)** is complete: skeleton and licensing, the toolchain pin, `./x`, SVD and PAC,
bare-metal hello, the test harnesses, CI and the hardware lab tools. The runtime (P1) follows.

## Getting started

```sh
./x toolchain install      # the pinned compilers, gprbuild, gnatprove, adalang_analyzer, svdtools, svd2ada
. ./export.sh              # source it, do not run it; once per shell
x toolchain check          # every tool, its pinned version, and whether it is the one on PATH
x help                     # every verb; `x build bare_hello`, `x test qemu`, `x hw ...`
```

`export.sh` puts `tools/bin` (so `x` works from any directory) and the pinned toolchains on `PATH`, sets
`ADA_MPFS_SDK` and `GPR_PROJECT_PATH` (so `gprbuild` and the Ada Language Server find `mpfs_pac.gpr` and the
other projects) and, in an interactive bash or zsh, loads the tab completion for `x`. `./x` itself needs no
`export.sh`: it finds the pinned tools by itself. `./x toolchain check` reports a pinned tool that is
installed but not first on `PATH` as an error, which is the sign that `export.sh` was not sourced.

- Layout: every directory has a `README.md` (purpose, owning phase, license).
- Contributing and conventions: [CONTRIBUTING.md](CONTRIBUTING.md).
- Licensing: [LICENSE](LICENSE), [NOTICE](NOTICE), [PROVENANCE.md](PROVENANCE.md); texts in `LICENSES/`.

## Testing status

Nothing here replaces a test on your own board. What was exercised, and how:

**On an Icicle Kit** (boot mode 0, by the project owner; the other boot modes are not run yet):
the JTAG IDCODE and the harts through OpenOCD, `bare_hello` on the E51 (needs `--uart-standin`, because
nothing in that mode sets the UARTs up), `probe_time.S` (`mtime` does not tick, `mcycle` counts),
MMUART0 to MMUART3, the factory restore, and the register measurements that fed the SVD
(`./x svd probe`, `./x hw`). Each file in `svd/patches/` and `svd/additions/` carries its own `# status:` header (`grep '^# status' svd/*/*.yaml`): three of the 13 (`MMUART0_LO`, `SPI_A_LO`, `SYSREG`) are verified on the MPFS250T, the others stay `unverified` until the board confirms every claim in them.

**Without a board** (QEMU and Renode): the smoke test of `bare_hello`, the `Test_Report` applications
(`./x test qemu`), and the same smoke test under Renode (`./x test renode`, not required for a merge).
QEMU models the PolarFire SoC only in part, so a pass there says nothing about the peripherals.

**Not done yet:** eNVM placement and boot modes 1 to 3, the runtime, the HAL, anything beyond the E51 and U54 start code
that the examples carry. The plan is in [issue #7](https://github.com/ThyMYthOS/ada_mpfs/issues/7) and the
detail plan of the current phase in [issue #8](https://github.com/ThyMYthOS/ada_mpfs/issues/8).

### What CI checks on every push

Nothing in CI needs a board. The workflows (see `.github/workflows/README.md`) build every example, compare the
section sizes with `metrics.golden`, run the negative ABI builds, the QEMU and Renode smoke tests and the host
suites of every tool, build every image twice and require the same SHA-256 (`./x repro`), check the SVD, the PAC
(regenerated and compared), the licence headers (`reuse lint`, `tools/headers.py`), the requirement trace
(`tools/trace.py --check`), the Markdown links (`./x docs`), SPARK proof and the static analysis baselines.
Hardware validation stays on the bench.

## Proof and static analysis

Both gates are tripwires: they report only what a change introduces, and neither claims the code is clean.

- **SPARK proof.** `./x prove` runs GNATprove over the projects in `tools/prove.list`, each with zero unproved
  checks. Only `tests/prove/sample` is in the list so far; the units that parse data or carry integrity-critical
  logic join it as they are written. `tests/host/prove` checks that an unprovable project fails the gate.
- **Static analysis.** `./x analyze` runs [adalang_analyzer](https://github.com/mmartign/AdaLang_Analyzer) over each
  library and hides every finding fingerprinted in [`tools/analyzer-baselines/`](tools/analyzer-baselines), so it
  prints only what is new; `./x analyze --style` is the second rule set against its own baseline.
  Only the PAC has a baseline so far.
- **Footprint.** `./x stack <example>` reports per-frame and worst-case call-chain stack use, `./x mem <example>`
  the section sizes against the linker bounds, and `./x metrics verify` compares the sizes of every image with
  `metrics.golden`.
- **Requirements.** `docs/requirements/` holds the catalogue; `./x trace` ties the `@req` and `@verifies`
  markers of sources and tests to it and writes `docs/assurance/trace-matrix.md`.

## Tooling

- **`./x`**: the in-repo dispatcher. `x help` lists every verb, `x list` the examples; tab completion comes with
  `export.sh`.
- **`./x test`**: `host` (the suites of the tools), `lib` (every library for E51 and U54, warnings fail),
  `examples`, `negative`, `metrics`, `qemu` and `renode`. This is what CI runs.
- **`./x hw`**: `bootmode`, `openocd`, `run`, `probe`, `monitor` and `reset` against an Icicle Kit; setup and the
  OpenOCD facts are in [`hw/README.md`](hw/README.md) and [`docs/lab/`](docs/lab).
- **`./x svd` and `./x pac`**: merge and check the SVD; generate the register package with the pinned svd2ada.
- **`./x repro`, `./x docs`, `./x tools-doc`**: reproducible builds, link check, the table of tool pins.

## Repository layout

Directories marked (later) hold only a `README.md` that names the phase that fills them.

```
crates/    mpfs_rts (the runtime), bb-runtimes fork, sparknacl (all later)
libs/      mpfs_pac (generated registers), mpfs_hal and mpfs_storage (later)
svd/       the SVD: base/, patches/, additions/ merged by ./x svd merge
examples/  bare_hello, pmp_probe, report_test, common/ (linker scripts, start code); see examples/README.md
tests/     host suites, qemu, renode, negative builds, prove, hw
hw/        host tools for the Icicle Kit (OpenOCD supervisor, run, probe, monitor, reset, bootmode)
boot/      two-stage bootloader (later)
config/, systems/   system description and generator, reference systems (later)
book/, ide/         handbook and editor support (later)
docs/      coding standard, requirements, assurance, lab notes
tools/     toolchain pin, ./x helpers, headers, trace, proof, analyzer baselines
x, export.sh        the dispatcher and the environment
```

## Prerequisites

- A Linux host (Windows and macOS are being added; see the open toolchain issue). `./x toolchain install` fetches
  everything else: the pinned Alire, the compilers (`gnat_riscv64_elf`, `gnat_native`), gprbuild, gnatprove,
  adalang_analyzer, svdtools in a virtual environment, svd2ada built from source and Renode.
- Python 3.13 or later, `xmllint` (`libxml2-utils`) and QEMU 10.1 or later (`qemu-system-riscv64`) for the host
  suites and the QEMU tests.
- For the board: a PolarFire SoC Icicle Kit on USB (FlashPro6 JTAG and four serial ports) and Microchip
  SoftConsole. Its OpenOCD, its udev rules and `mpfsBootmodeProgrammer.jar` are used as installed; the repository
  carries none of them. `hw/lab.conf` (from `hw/lab.conf.example`) names the paths.

The examples run in M mode with PMP open and no MMU; there is no operating system and no vendor HAL.

## License

Code is Apache-2.0, documentation CC-BY-4.0, and the SVD and the PAC generated from it CC-BY-4.0. The runtime
`crates/mpfs_rts` (later, from AdaCore's bb-runtimes) will be GPL-3.0-or-later with the GCC Runtime Library
Exception, which applies to code linked against it. Files taken from other projects keep their licence; see [LICENSE](LICENSE),
[NOTICE](NOTICE) and [PROVENANCE.md](PROVENANCE.md).
