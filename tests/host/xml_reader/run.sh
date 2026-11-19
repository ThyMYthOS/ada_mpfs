#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Tests for the reader of the MSS Configurator XML (config/gen/mpfs_gen/xml_reader.py):
#
#   - test_xml_reader.py: the reference XMLs of config/boards read, each with its format version; each XML
#     of fixtures/broken (an .xml as it is, an .edit applied to the XML of the Icicle Kit) is rejected with
#     exactly the code that its line `expect: GEN-Exxx` names, and every code of the XML has one; the known
#     defect of PLL_PHADJ; lookup by section and name; the values against the layout of the SVD and against
#     the literals of hw/mss_init.py; the messages; the command line.
#
# Needs the merged SVD (tools/svd.py ensure rebuilds it if it is missing or stale, which needs svdtools),
# no toolchain. Exits non-zero on any failure.
#
# @verifies GEN-003, GEN-004

set -u
export LC_ALL=C
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HERE="$ROOT/tests/host/xml_reader"
fails=0

. "$ROOT/tools/mpfs-env.sh"
mpfs_find_python

echo "-- test_xml_reader.py"
"$MPFS_PYTHON" -I "$HERE/test_xml_reader.py" || fails=$((fails + 1))

[ $fails -eq 0 ] || { echo "FAIL: test_xml_reader.py" >&2; exit 1; }
echo "all ok"
