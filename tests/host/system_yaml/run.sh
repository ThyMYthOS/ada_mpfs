#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Tests for the schema of system.yaml and its reader (config/gen/mpfs_gen, config/gen/schema):
#
#   - test_system_yaml.py: the four reference systems of systems/ validate and are the ones described;
#     each description of fixtures/broken is rejected with exactly the code that its line
#     `# expect: GEN-Exxx` names, and every code of the table has one; the messages; the table of the
#     codes in config/README.md; every failing keyword of the schema has a code and every object of it
#     refuses unknown fields; the defaults and the normalisation; the standalone presets of the 30
#     runtime variants give standalone.py the parameters that write the bytes of ./x build without
#     options; the command line.
#
# Needs PyYAML and jsonschema (tools/requirements.txt), no toolchain. Exits non-zero on any failure.
#
# @verifies GEN-001, GEN-002

set -u
export LC_ALL=C
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HERE="$ROOT/tests/host/system_yaml"
fails=0

. "$ROOT/tools/mpfs-env.sh"
mpfs_find_python

echo "-- test_system_yaml.py"
"$MPFS_PYTHON" -I "$HERE/test_system_yaml.py" || fails=$((fails + 1))

[ $fails -eq 0 ] || { echo "FAIL: test_system_yaml.py" >&2; exit 1; }
echo "all ok"
