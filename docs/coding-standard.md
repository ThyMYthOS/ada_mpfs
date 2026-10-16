<!--
SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
SPDX-License-Identifier: CC-BY-4.0
-->
# Coding standard

The rules for the Ada, assembler and script sources of this repository. Each rule says how it is
enforced; a rule marked *review* has no tool behind it yet and is checked in code review.

Naming, file names, headers and licences are in [CONTRIBUTING.md](../CONTRIBUTING.md); the build
contract of an example is in [examples/STYLE.md](../examples/STYLE.md).

## All Ada code

| Rule | Enforced by |
|---|---|
| Ada 2022 (`-gnat2022`). | The project files. |
| Warnings are errors: `-gnatwa -gnatwe`. Generated code is exempt. | The project files of the examples, libraries and tests. |
| Style checks `-gnaty` (the standard style set of GNAT). | The project files, together with `-gnatwe`. |
| The defect checks of `./x analyze` (the `--recommended` set of adalang_analyzer plus ten correctness checks) report nothing new. | `./x analyze`, against the baselines in `tools/analyzer-baselines/`. |
| The readability checks of `./x analyze --style` (complexity, nesting, parameter count, duplicates, dead code) report nothing new. | `./x analyze --style`. |
| A baselined finding is not a licence: a new finding is fixed unless it is noise, and only then is the baseline rewritten, in a commit of its own. | Review. |
| A subprogram is documented where it is declared (the spec), not where it is implemented. | Review. |
| No `pragma Suppress`, no `-gnatp`, except in a unit whose absence of run-time errors is proved with SPARK (see below). | Review; `./x prove` for the proof. |
| Generated files are not edited by hand. | `./x svd check`, `./x pac check`. |

## Registers

| Rule | Enforced by |
|---|---|
| Registers are accessed through the register package `MPFS_Registers` (`libs/mpfs_pac`) and nowhere else. No hand-written address clauses for peripherals. | Review. |
| Every access is a 32-bit access; the register types are `Volatile_Full_Access` and `Object_Size 32`. | The generator (`tools/pac_gen.py`) and `./x pac check`. |
| A whole register is written with one aggregate or one object assignment. An assignment to a component of a register object is a read-modify-write, so it is used only for registers that tolerate one. | Review. |
| A register that the SVD marks write-only is never read, and never modified with a read-modify-write (a read of its address can return another register). | `hw/svd_probe.py` for the probe; for the HAL: review. |
| A register with a `readAction` (a read has a side effect) is read only where the side effect is intended, and the read is commented. | Review. |
| No peripheral access through an aggregate or a slice that the compiler may split into narrower accesses. | Review of the disassembly of the access. |

## The security-critical set (TSF)

The units that make up the boot chain, the machine-mode cores, the cryptography and the generated
configuration. They follow all rules above and also:

| Rule | Enforced by |
|---|---|
| No dynamic allocation. | `pragma Restrictions` (`No_Allocators`, `No_Unchecked_Deallocation`) in the project of each unit of the set. |
| No exception propagation: an exception does not leave a subprogram, and no exception handler is the only thing between an error and an unsafe state. | `pragma Restrictions` (`No_Exception_Propagation` where the runtime supports it), the analyzer, SPARK. |
| No recursion. | `./x stack` (the call graph reports recursion); the analyzer. |
| No tasking. | `pragma Restrictions` (`No_Tasking`). |
| `-gnatp` or `pragma Suppress` only where `./x prove` proves the absence of run-time errors for the unit. | `./x prove`. |
| Secrets, MACs and hashes are compared in constant time. | Review, and a test per comparison. |
| A decision that grants access or accepts an image is made twice, by independent code, and the two results are compared. Default deny. | Review. |
| No binary blobs. | `tools/headers.py check` and `PROVENANCE.md`. |
| Every requirement of the unit is referenced in the spec with `@req` and in a test with `@verifies` (see below). | `./x trace --check`. |

## Assembler

- Only where Ada cannot express it: the start code, the trap entry, CSR sequences, and fences.
- Every file has a header that says what it does, which registers it may clobber, and what it
  expects on entry.
- Every instruction sequence that is not obvious has a comment that says why, not what.
- One entry per `.S` file or one clearly named group; no macros that hide control flow.
- Assembler is built with the same `-march`/`-mabi` as the Ada code of the image (see
  `examples/common/bare_build.sh`); `./x test negative` checks that mismatched objects do not link.

## Shell and Python tools

- Shell: `bash` with `set -u`; `sh` + `awk` only where the script must run on macOS (as
  `tools/metrics.sh`). Quote every expansion.
- Python: 3.13, the packages of `tools/requirements.txt`, run through `./x` so that the virtual
  environment is the same everywhere.
- A tool that checks something fails closed: no input, a missing tool or an unexpected output is a
  failure, never a pass. Each such rule has a test that makes the tool fail.
- A host test lives in `tests/host/<suite>/run.sh`, exits non-zero on any failure and has a control
  case for every negative case (so that a negative cannot pass because the set-up is broken).

## Requirement IDs

A requirement has an ID of the form `<AREA>-<NNN>`, or `<AREA>-<SUB>-<NNN>` for a sub-area: capital
letters and digits, a three-digit number, for example `BLD-002`, `BOOT-012`, `HAL-SPI-004`. The
requirements of an area are in `docs/requirements/<area>.yaml` (the file name is the first part of
the ID, in lower case), one entry each:

```yaml
requirements:
  - id: BLD-002
    text: What shall hold, as one testable statement.
    tsf: false        # true for the security-critical set
    source: where it comes from (a document of this repository, a standard, a datasheet)
```

An ID is never reused or renumbered. A requirement that no longer applies stays in the file with its
text prefixed `Withdrawn:`.

In the sources a comment names the requirement:

```ada
--  @req BLD-002
```

where it is specified (a spec declaration) or implemented, and, in a test:

```sh
# @verifies BLD-002
```

Several IDs are separated by commas. Any comment style works (`--`, `#`, `//`, `/*`, `;`);
Markdown is not scanned.

`./x trace` writes the matrix `docs/assurance/trace-matrix.md`. `./x trace --check` fails on a
malformed or duplicate ID, an unknown reference, a TSF requirement without a test, and a matrix that
is out of date; it runs in CI.
