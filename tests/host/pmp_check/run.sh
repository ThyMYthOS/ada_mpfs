#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Tests for tools/pmp_check, the independent checker of the PMP in SPARK, and for its input
# (`mpfs_gen derive --check-json`, config/gen/mpfs_gen/system_json.py):
#
#   - the checker builds natively (tools/pmp_check/pmp_check.gpr, warnings are errors);
#   - test_pmp_check.py: the reference systems with their XMLs and with the XML of the PMP demo, as dev and
#     as prod, with 16 and 8 entries, give the same findings in the generator and in the checker (the same
#     severity, code and path, so the same verdict); one case per rule the checker evaluates; 1000 random
#     configurations (seeded: PMP_CHECK_SEED, PMP_CHECK_CASES) in which both agree, prod systems on both
#     sides of the verdict among them; a malformed check input refused with status 2; the command line.
#
# The SPARK proof of the checker runs with `./x prove` (tools/prove.list). Needs the native GNAT toolchain
# and gprbuild (./x toolchain install), the merged SVD (tools/svd.py ensure rebuilds it if it is missing or
# stale, which needs svdtools), PyYAML and jsonschema. Exits non-zero on any failure.
#
# @verifies GEN-015, GEN-016

set -u
export LC_ALL=C
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HERE="$ROOT/tests/host/pmp_check"

. "$ROOT/tools/mpfs-env.sh"
mpfs_find_python
mpfs_toolchain_on_path >/dev/null 2>&1 || true

echo "-- build tools/pmp_check"
log="$(mktemp)"
if ! gprbuild -q -p -P "$ROOT/tools/pmp_check/pmp_check.gpr" >"$log" 2>&1; then
  cat "$log" >&2
  rm -f "$log"
  echo "FAIL: tools/pmp_check does not build (needs the native GNAT toolchain: ./x toolchain install)" >&2
  exit 1
fi
rm -f "$log"

echo "-- test_pmp_check.py"
PMP_CHECK="$ROOT/build/pmp_check/pmp_check" "$MPFS_PYTHON" -I "$HERE/test_pmp_check.py" \
  || { echo "FAIL: test_pmp_check.py" >&2; exit 1; }
echo "all ok"
