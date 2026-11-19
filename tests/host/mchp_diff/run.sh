#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# The differential test of the reader of the MSS Configurator XML against Microchip's configuration generator
# (tools/mchp_diff/mchp_diff.py):
#
#   - test_mchp_diff.py: every reference XML of config/boards agrees with the generator at the pinned commit
#     (tools/mchp_diff/oracle.env), with nothing unmapped or missing, and the committed exception list is
#     empty; a stand-in output of the generator with a changed value, a define that maps to nothing (an
#     unknown name, a missing prefix, an unknown header, a define given twice) and a missing register fail
#     and name the define; an exception entry admits a difference only with a reason and a defect of ours or
#     Microchip's, and an entry that admits nothing is refused; a changed script or another commit of the
#     generator is refused.
#
# Needs the merged SVD (tools/svd.py ensure rebuilds it if it is missing or stale, which needs svdtools), git
# and, on the first run, access to github.com (the generator is fetched into build/mchp_diff); no toolchain.
# Exits non-zero on any failure.
#
# @verifies GEN-005

set -u
export LC_ALL=C
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HERE="$ROOT/tests/host/mchp_diff"
fails=0

. "$ROOT/tools/mpfs-env.sh"
mpfs_find_python

echo "-- test_mchp_diff.py"
"$MPFS_PYTHON" -I "$HERE/test_mchp_diff.py" || fails=$((fails + 1))

[ $fails -eq 0 ] || { echo "FAIL: test_mchp_diff.py" >&2; exit 1; }
echo "all ok"
