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
#     clock limit and an overlap of two partition windows whose message names both partitions; the reference
#     systems taken as dev, where the checks of the PMP, which the reference XMLs fail, are notes.
#   - test_protection.py: the PMP evaluated (lowest index, L for M mode, no match, TOR, NA4, the implemented
#     bits of pmpaddr), the AMP contexts and the LO and HI addresses of the peripherals, a system of two
#     contexts whose PMP passes (also with the 8 entries of QEMU) and a negative case for every code of the
#     PMP against the partitions and of the contexts (GEN-E120 on), changed into the XML of the Icicle Kit in
#     the model; the reference systems with the reference XMLs refused for prod and derived with notes for
#     dev.
#
# Needs the merged SVD (tools/svd.py ensure rebuilds it if it is missing or stale, which needs svdtools),
# PyYAML and jsonschema, no toolchain. Exits non-zero on any failure.
#
# @verifies GEN-006, GEN-007, GEN-008, GEN-009, GEN-011, GEN-012

set -u
export LC_ALL=C
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HERE="$ROOT/tests/host/derive"
fails=0

. "$ROOT/tools/mpfs-env.sh"
mpfs_find_python

for t in test_derive.py test_protection.py; do
  echo "-- $t"
  "$MPFS_PYTHON" -I "$HERE/$t" || { echo "FAIL: $t" >&2; fails=$((fails + 1)); }
done

[ $fails -eq 0 ] || exit 1
echo "all ok"
