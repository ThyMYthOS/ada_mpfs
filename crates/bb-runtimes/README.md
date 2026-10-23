# `crates/bb-runtimes/`

- **Purpose:** Trimmed fork of bb-runtimes, riscv64/mpfs only.
- **Owning phase:** P1
- **License:** the runtime sources (Ada, C and assembler under `gnat_rts_sources/`, `src/`, `riscv/`) GPL-3.0-or-later WITH GCC-exception-3.1 (`COPYING3`, `COPYING.RUNTIME`); the Python generator (`support/`, `build_rts.py`, `riscv/*.py`) GPL-3.0-or-later without the exception; 73 specifications derived from the Ada Reference Manual `LicenseRef-Ada-RM-permissive`

Base: [alire-project/bb-runtimes](https://github.com/alire-project/bb-runtimes) tag `v15.1.0-1`
(branch `gnat-fsf-15`, commit `09e7cd6`, GNAT 15.1), the source of the runtimes that ship with
`gnat_riscv64_elf` 15.3.1. [PROVENANCE.md](../../PROVENANCE.md) lists every imported file.

| Path | Content |
|---|---|
| `build_rts.py` | Generates the source tree of a runtime. Accepts only the board `mpfs` and needs the hart class: `build_rts.py --hart e51\|u54 [--profiles light,light-tasking,embedded] -o DIR mpfs`. Writes `DIR/<profile>-mpfs/`. `crates/mpfs_rts/make_packs.sh` calls it. |
| `riscv/__init__.py` | `RiscV64`, the common base of the riscv64 boards. |
| `riscv/mpfs/__init__.py` | `MPFS(RiscV64)` with the parameter `hart_class` (table below), the profiles and `system_ads` (as upstream: `system-xi-riscv.ads`, `system-xi-riscv-sifive-sfp.ads`, `system-xi-riscv-sifive-full.ads`), the source lists and no linker scripts. The other files of the directory are upstream board units (`start-ram.S`, `a-intnam.ads`, `s-bbripl.adb`) that the own port units replace later (P1.3, P1.4, P1.10). |
| `riscv/src/`, `riscv/sifive/fe310/`, `src/` | Upstream board units and the `system.ads` variants, only the files the board uses. |
| `gnat_rts_sources/` | The common GNAT and GNARL sources (`include/rts-sources`) and `lib/gnat/rts-sources.json`, which selects the directories of a profile. Must match the toolchain: `crates/mpfs_rts/compare_toolchain.sh`. |
| `support/` | The generator (target classes, installer, scenario variables). |

| Hart class | `-march` | `-mabi` | FPU | Scenarios that follow |
|---|---|---|---|---|
| `e51` | `rv64imac_zicsr_zifencei` | `lp64` | none | `Has_FPU=no`, `Add_Math_Lib=softfloat` |
| `u54` | `rv64imafdc_zicsr_zifencei` | `lp64d` | single and double | `Has_FPU=yes`, `Add_Math_Lib=hardfloat` |

The code model is not set: `-mcmodel=medany` is the default of the toolchain spec. The generated
`runtime.xml` has no `-T`, no `ld/` directory and no `-u __gnat_gdb_cpu_first_id` (upstream puts
both into the `RAM` loader); the linker script and the symbols come from the partition data.
Until the own port units exist (P1.3 and later) the hart-specific parts are the upstream ones,
for example the FP context handling is still upstream's (defect no. 1, P1.5).

Do not edit the imported files for another purpose than this board. A change in
`gnat_rts_sources/` or in the common part of `src/` would break the match with the toolchain
(`compare_toolchain.sh` fails); prefer the source of the toolchain.
