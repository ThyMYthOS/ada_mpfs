#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Tests for the derivations of the configuration generator (config/gen/mpfs_gen/derive):
#
#   - test_derive.py: the clocks of every reference XML recomputed from the MSS PLL equal those of the XML
#     (at most 1 ppm), also in the fractional mode; the four reference systems derive with the XMLs of the
#     Icicle Kit (the video kit configures too few MMUARTs for them); the L2 (the scratchpad ways are the
#     upper enabled ways); the placement (a chain of channels, a shared block); CPU_To_Hart; the PLIC
#     sources and contexts; the peripheral bits from the SVD, RAM_SHUTDOWN_CR, the direct GPIO lines; the
#     command line; and a negative case for every code of the derivations (GEN-E060 on), among them each
#     clock limit and an overlap of two partition windows whose message names both partitions.
#
# Needs the merged SVD (tools/svd.py ensure rebuilds it if it is missing or stale, which needs svdtools),
# PyYAML and jsonschema, no toolchain. Exits non-zero on any failure.
#
# @verifies GEN-006, GEN-007, GEN-008, GEN-009

set -u
export LC_ALL=C
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HERE="$ROOT/tests/host/derive"
fails=0

. "$ROOT/tools/mpfs-env.sh"
mpfs_find_python

echo "-- test_derive.py"
"$MPFS_PYTHON" -I "$HERE/test_derive.py" || fails=$((fails + 1))

[ $fails -eq 0 ] || { echo "FAIL: test_derive.py" >&2; exit 1; }
echo "all ok"
