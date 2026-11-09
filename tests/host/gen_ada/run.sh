#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Tests for the shared library of the code generators (tools/gen_ada/): one test_<module>.py per module,
# each run under `python -I`, and the shell functions of tools/mpfs-env.sh that the generators of the
# runtime share (shell.sh, once they exist). Exits non-zero on any failure.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HERE="$ROOT/tests/host/gen_ada"
fails=0
. "$ROOT/tools/mpfs-env.sh"
mpfs_find_python

for t in "$HERE"/test_*.py; do
  [ -f "$t" ] || continue
  echo "-- $(basename "$t")"
  "$MPFS_PYTHON" -I "$t" || { echo "FAIL: $(basename "$t")" >&2; fails=$((fails + 1)); }
done
if [ -f "$HERE/shell.sh" ]; then
  echo "-- shell.sh"
  bash "$HERE/shell.sh" || { echo "FAIL: shell.sh" >&2; fails=$((fails + 1)); }
fi

echo "summary: $fails failing test file(s)"
[ $fails -eq 0 ]
