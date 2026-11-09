#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Tests for the standalone partition data (config/gen/standalone.py, issue #53):
# test_standalone.py runs the generator on fixtures (the package and the list of link symbols byte for
# byte), the defaults, the harts, the console table, the memory profiles and local memories, the
# contract with the linker scripts, --check, determinism, every input it refuses and every rule
# violation it must not refuse (the Ada checks of the package do that). It needs no toolchain.
# Exits non-zero on any failure.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HERE="$ROOT/tests/host/standalone"
fails=0

fail () { echo "FAIL: $1" >&2; fails=$((fails + 1)); }

. "$ROOT/tools/mpfs-env.sh"
mpfs_find_python

echo "-- test_standalone.py"
"$MPFS_PYTHON" -I "$HERE/test_standalone.py" || fail "test_standalone.py"

[ $fails -eq 0 ] || { echo "$fails failure(s)" >&2; exit 1; }
echo "all ok"
