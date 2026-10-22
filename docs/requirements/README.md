<!--
SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
SPDX-License-Identifier: CC-BY-4.0
-->
# `docs/requirements/`

- **Purpose:** The requirements catalogue as YAML, one file per area (`<area>.yaml`).
- **License:** CC-BY-4.0

Each file has the list `requirements:` with the fields `id` (`<AREA>-<NNN>`), `text`, `tsf` (true or
false) and `source`. The sources refer to a requirement with `@req ID`, the tests with `@verifies ID`.
The format and the rules are in [docs/coding-standard.md](../coding-standard.md#requirement-ids);
`./x trace` writes the matrix [docs/assurance/trace-matrix.md](../assurance/trace-matrix.md) and
`./x trace --check` checks it.

| File | Area |
|---|---|
| `bld.yaml` | The build and the toolchain. |
| `svd.yaml` | The register description. |
| `pac.yaml` | The register package. |
| `hw.yaml` | The board tools. |
