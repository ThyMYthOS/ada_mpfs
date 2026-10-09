<!--
SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
SPDX-License-Identifier: CC-BY-4.0
-->
# Example conventions

An example is a directory `examples/<name>/` that `./x list` finds by its `app.gpr`.
Create one with `./x new <name>`.

## Build contract

`./x build` runs `gprbuild -p -P app.gpr` inside the example directory and passes the scenario
variables

| Variable | Values | Meaning |
|---|---|---|
| `MPFS_HART` | `e51`, `u54` | hart class of the image |
| `MPFS_HARTS` | empty, or a U54 hart set (`2`, `1-4`, `1,3`) | harts of an SMP partition |
| `MPFS_PRIV` | `m`, `u` | privilege model |
| `MPFS_PROFILE` | `auto`, `light`, `light-tasking`, `embedded` | runtime profile |

`./x build` validates all values before calling `gprbuild`; an SMP set with `--hart e51` is rejected.

The project must

- write objects to `obj-<hart>/` and the executable to `bin-<hart>/`, with the suffix `.elf`
  (`./x clean`, `./x qemu` and `./x mem` rely on this);
- compile with `-gnatwa -gnatwe`: warnings are errors (generated code is exempt).

## Files

| File | Purpose |
|---|---|
| `app.gpr` | project file |
| `src/` | sources |
| `example.conf` | `KEY=value` lines; `HART=` is the default hart of the example (`e51` if absent) |
| `README.md` | what the example shows, how to build and run it |
