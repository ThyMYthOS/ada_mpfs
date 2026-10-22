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
