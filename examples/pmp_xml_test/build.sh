#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Build hook of ./x build: see examples/common/bare_build.sh.
#
# The table of the XML is the committed src/generated/pmp_xml.ads (made from the XML of the Icicle Kit,
# config/boards/icicle). PMP_XML=<file> takes another MSS Configurator XML instead: the table is then
# generated into obj-<hart>/pmp_xml (python3 config/gen/mpfs_gen pmp, which needs the merged SVD) and
# the committed one is left alone.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=examples/common/bare_build.sh
. ../common/bare_build.sh
if [ -n "${PMP_XML:-}" ]; then
  xml="$(cd "$(dirname "$PMP_XML")" && pwd)/$(basename "$PMP_XML")"
  table="obj-${MPFS_HART:-e51}/pmp_xml"
  python3 ../../config/gen/mpfs_gen pmp --ada "$table/pmp_xml.ads" "$xml"
  export PMP_TABLE_DIR="$table"
fi
bare_build pmp_xml_test start pmp_mask pmp_regs bare_console pmp_csr pmp_xml test_report pmp_xml_test
