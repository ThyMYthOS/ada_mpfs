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

One more variable is read from the environment of the project only: `STACK_ANALYSIS` (`0`, the default, or `1`).
`./x stack` sets it to `1`; the project then adds `-fstack-usage -fcallgraph-info=su,da` to the Ada switches, so that
the compiler writes the frame sizes (`.su`) and the call graph (`.ci`) next to the objects (`tools/stack_report`
reads them). The code does not change.

`./x build` validates all values before calling `gprbuild`; an SMP set with `--hart e51` is rejected.
`MPFS_HARTS` is not passed when it is empty, because `gprbuild` treats an empty value as undefined.

An example that must not bind or link the runtime (a bare image) has a `build.sh` in its directory. `./x
build` runs it instead of `gprbuild -p -P app.gpr`, in the example directory, with the four variables
above in the environment, and it must still produce `bin-<hart>/*.elf`. `app.gpr` then compiles the
sources (`gprbuild -c`); see `examples/common/bare_build.sh`.

The project must

- write objects to `obj-<hart>/` and the executable to `bin-<hart>/`, with the suffix `.elf`
  (`./x clean`, `./x qemu` and `./x mem` rely on this);
- compile with `-gnatwa -gnatwe`: warnings are errors (generated code is exempt);
- not record the build directory in the image: `./x repro` builds every image twice, in two directories,
  and compares the ELFs. `./x` exports `ADA_MPFS_SDK` (the repository root), and the project adds
  `-ffile-prefix-map=$ADA_MPFS_SDK=.` and `-gno-record-gcc-switches` (the recorded switches name a
  temporary file of gprbuild) to the compiler switches (Ada, and Asm_Cpp where used); `./x new` writes the same into
  its template. A build script that links adds no path of its own to the image (`bare_link` passes none).

## Files

| File | Purpose |
|---|---|
| `app.gpr` | project file |
| `src/` | sources |
| `example.conf` | `KEY=value` lines; `HART=` is the default hart of the example (`e51` if absent); `BUILD_HARTS=` (e.g. `e51 u54`) the harts that `./x test qemu` and `./x metrics` build, and whose images the smoke test and `metrics.golden` cover |
| `build.sh` | optional, builds instead of `gprbuild` (see above) |
| `README.md` | what the example shows, how to build and run it |
