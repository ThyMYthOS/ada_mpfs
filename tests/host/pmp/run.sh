#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Tests for the PMP of the MSS Configurator XML in the configuration generator (config/gen/mpfs_gen/pmp.py):
#
#   - test_pmp.py: the PMP of each hart of every reference XML (the E51 without an entry, each U54 with entry 0
#     locked NAPOT over the whole address space, RWX); the regions of NAPOT, TOR and NA4 entries; a negative
#     case for every code of the PMP sections (GEN-E100 on); the Ada table Pmp_Xml (deterministic, --check
#     fails on a stale one); the command line.
#
# Needs the merged SVD (tools/svd.py ensure rebuilds it if it is missing or stale, which needs svdtools),
# PyYAML and jsonschema, no toolchain. Exits non-zero on any failure.
#
# @verifies GEN-010

set -u
export LC_ALL=C
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HERE="$ROOT/tests/host/pmp"

. "$ROOT/tools/mpfs-env.sh"
mpfs_find_python

echo "-- test_pmp.py"
"$MPFS_PYTHON" -I "$HERE/test_pmp.py" || { echo "FAIL: test_pmp.py" >&2; exit 1; }
echo "all ok"
