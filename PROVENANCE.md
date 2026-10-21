# Provenance

Every imported file or directory is listed here. `tools/headers.py check` fails if a file with a
`Derived from` header is not covered by an entry. "Kind": `unchanged`, `adapted` or `new`.

| File / directory | Source (repo, commit, path) | License | Kind | Date |
|---|---|---|---|---|
| `x` | rowsail/ada_esp32s3 `x` @ d75142d | Apache-2.0 | adapted | 2026-10-09 |
| `export.sh` | rowsail/ada_esp32s3 `export.sh` @ d75142d | Apache-2.0 | adapted | 2026-10-09 |
| `LICENSES/GPL-3.0-or-later.txt`, `LICENSES/GCC-exception-3.1.txt` | SPDX license list, fetched with `reuse download` | GPL-3.0-or-later, GCC-exception-3.1 | unchanged | 2026-10-21 |
| `LICENSES/LicenseRef-Ada-RM-permissive.txt` | the Ada Reference Manual notice paragraph of the specifications in alire-project/bb-runtimes `gnat_rts_sources/` @ 09e7cd6, copied word for word | LicenseRef-Ada-RM-permissive | new | 2026-10-22 |
| `crates/bb-runtimes/COPYING3`, `crates/bb-runtimes/COPYING.RUNTIME` | alire-project/bb-runtimes `COPYING3`, `COPYING.RUNTIME` @ 09e7cd6 | GPL-3.0-or-later, GCC-exception-3.1 | unchanged | 2026-10-21 |
| `crates/bb-runtimes/gnat_rts_sources/` | alire-project/bb-runtimes `gnat_rts_sources/` @ 09e7cd6 (tag v15.1.0-1, branch gnat-fsf-15; GNAT 15.1) | GPL-3.0-or-later WITH GCC-exception-3.1; 73 specifications derived from the Ada Reference Manual: LicenseRef-Ada-RM-permissive (see `REUSE.toml`) | unchanged | 2026-10-21 |
| `crates/bb-runtimes/riscv/link-zcx.spec` | alire-project/bb-runtimes `riscv/link-zcx.spec` @ 09e7cd6 | GPL-3.0-or-later WITH GCC-exception-3.1 | unchanged | 2026-10-21 |
| `crates/bb-runtimes/riscv/mpfs/a-intnam.ads`, `s-bbripl.adb`, `start-ram.S` | alire-project/bb-runtimes `riscv/microchip/polarfiresoc/` @ 09e7cd6, same names (the two linker scripts `common-RAM.ld` and `memory-map.ld` not imported) | GPL-3.0-or-later WITH GCC-exception-3.1 | unchanged (moved) | 2026-10-21 |
| `crates/bb-runtimes/riscv/sifive/fe310/` | alire-project/bb-runtimes `riscv/sifive/fe310/` @ 09e7cd6: `s-macres.adb`, `svd/i-fe310.ads`, `svd/i-fe310-plic.ads` | GPL-3.0-or-later WITH GCC-exception-3.1 | unchanged (the rest of `riscv/sifive/` not imported) | 2026-10-21 |
| `crates/bb-runtimes/riscv/src/` | alire-project/bb-runtimes `riscv/src/` @ 09e7cd6: `context_switch.S`, `riscv_def.h`, `s-bbripl.ads`, `trap_handler.S` | GPL-3.0-or-later WITH GCC-exception-3.1 | unchanged (the host target interface of Spike not imported) | 2026-10-21 |
| `crates/bb-runtimes/src/` | alire-project/bb-runtimes `src/` @ 09e7cd6: the ten board units of the PolarFire SoC board and its three `system/system-xi-riscv*.ads` | GPL-3.0-or-later WITH GCC-exception-3.1 | unchanged (every other file of `src/` not imported) | 2026-10-21 |
| `crates/bb-runtimes/support/` | alire-project/bb-runtimes `support/` @ 09e7cd6 | GPL-3.0-or-later (no license notice upstream: the license is taken from the COPYING3 at the top of the upstream repository; no exception, the generator is not compiled into a program) | unchanged (`docgen.py` and `data/doc/` not imported) | 2026-10-21 |
| `tools/analyze.sh` | rowsail/ada_esp32s3 `x` (`cmd_analyze` and its rule sets) @ d75142d | Apache-2.0 | adapted | 2026-10-12 |
| `tools/mpfs-env.sh` | rowsail/ada_esp32s3 `tools/sdk-env.sh` @ d75142d | Apache-2.0 | adapted | 2026-10-09 |
| `tools/prove.sh` | rowsail/ada_esp32s3 `book/prove/prove.sh` @ d75142d | Apache-2.0 | adapted | 2026-10-12 |
| `tools/stack_report/` | rowsail/ada_esp32s3 `tools/stack_report/` @ d75142d | Apache-2.0 | unchanged (SPDX header added) | 2026-10-12 |
| `tools/test_lib.sh` | rowsail/ada_esp32s3 `x` (`cmd_test` lib, `build_lib_clean`) @ d75142d | Apache-2.0 | adapted | 2026-10-22 |
| `svd/schema/CMSIS-SVD.xsd` | ARM-software/CMSIS_5 `CMSIS/Utilities/CMSIS-SVD.xsd` @ 55b1983 (schema revision 1.3.9) | Apache-2.0 | unchanged | 2026-10-09 |
