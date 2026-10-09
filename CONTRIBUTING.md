# Contributing and conventions

## Branches and commits

- `main` is protected: no direct pushes, pull requests need a green CI.
- **Commit prefix** follows Conventional Commits: `feat(hal):`, `fix(rts):`, `docs:`, `build:`, `ci:` ...
- Every commit carries `Signed-off-by`; commits on `main` are signed (basis for CM under ALC_CMC).

## Package names

| Area | Pattern |
|-------------------|----------------------------------------------------|
| HAL and drivers   | `MPFS.*`                                           |
| PAC               | `MPFS_Registers.*`                                 |
| Generator outputs | `MPFS_Config`, `MPFS_System_Map`, `MPFS_Partition` |
| Runtime           | `System.BB.*`                                      |

## File names

GNAT standard: `mpfs-spi.ads`, `mpfs-spi.adb`.

## Headers

Every non-trivial file carries an SPDX header and a one-line purpose. Trivial files (short READMEs,
templates, plain configuration) have no creative threshold and carry no header; `REUSE.toml` marks
them CC0-1.0. Documentation (Markdown) is licensed CC-BY-4.0, code Apache-2.0:

```ada
--  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  SPDX-License-Identifier: Apache-2.0
--
--  <one sentence on the purpose>
```

Imported files additionally carry a provenance and modification note and an entry in
[PROVENANCE.md](PROVENANCE.md):

```ada
--  Derived from rowsail/ada_esp32s3 <path> @ d75142d (Apache-2.0); modified for PolarFire SoC.
```

Files that cannot carry a header are annotated in `REUSE.toml`. Checks: `reuse lint` and
`tools/headers.py check` (`fix` adds missing default headers).

Licenses: project code Apache-2.0; documentation CC-BY-4.0; copied files keep their original license; runtime `crates/mpfs_rts` GPL-3.0-or-later WITH GCC-exception-3.1;
SVD and the PAC generated from it CC-BY-4.0; SPARKNaCl BSD-3-Clause.

## Generated files

They live in dedicated `generated/` subdirectories and are **never** edited by hand. CI checks that
regeneration reproduces them: `./x svd check` for the SVD hash, `./x pac check` for the register
package in `libs/mpfs_pac/src/generated` (`./x pac generate` rewrites it).

## Language

All repository content (code, comments, documentation, commit messages) is written in English.
