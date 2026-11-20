#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Tests for the PMP of the MSS Configurator XML in the configuration generator (config/gen/mpfs_gen/pmp.py)
# and for the wiring of the PMP test programs:
#
#   - test_pmp.py: the PMP of each hart of every reference XML (the E51 without an entry, each U54 with entry 0
#     locked NAPOT over the whole address space, RWX); the regions of NAPOT, TOR and NA4 entries; a negative
#     case for every code of the PMP sections (GEN-E100 on), among them the rules of the layout of the
#     entries (locked first, the entries of the target, the open locked entry 0 of the reference XMLs); the
#     Ada table Pmp_Xml (deterministic, the committed examples/pmp_xml_test/src/generated/pmp_xml.ads is
#     current, --check fails on a stale one);
#     the command line; and that tests/qemu/tests.list and tests/renode/smoke.expected run the PMP tests and
#     the APB window test on the E51 and a U54.
#
# Needs the merged SVD (tools/svd.py ensure rebuilds it if it is missing or stale, which needs svdtools),
# PyYAML and jsonschema, no toolchain. Exits non-zero on any failure.
#
# @verifies GEN-010, GEN-011

set -u
export LC_ALL=C
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HERE="$ROOT/tests/host/pmp"

. "$ROOT/tools/mpfs-env.sh"
mpfs_find_python

echo "-- test_pmp.py"
"$MPFS_PYTHON" -I "$HERE/test_pmp.py" || { echo "FAIL: test_pmp.py" >&2; exit 1; }
echo "all ok"
