#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Self-test of Host_Report (tests/host/common): the program whose checks hold exits
# 0, and every way of not passing (a failed check, no check, no Finish, an
# unhandled exception) exits non-zero. The negative cases are real programs run
# natively, so the exit status is the one the shell sees. Exits non-zero on any
# failure.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fails=0

pass () { echo "ok:   $1"; }
fail () { echo "FAIL: $1" >&2; fails=$((fails + 1)); }

. "$ROOT/tools/mpfs-env.sh"
mpfs_toolchain_on_path >/dev/null 2>&1 || true
command -v gprbuild >/dev/null 2>&1 || { echo "FAIL: no gprbuild (./x toolchain install gnat)" >&2; exit 1; }

# Build in a copy: the project writes obj/ and bin/ next to itself.
tmp="$(mktemp -d)"
trap 'rm -r "$tmp"' EXIT
mkdir -p "$tmp/tests/host"
cp -R "$ROOT/tests/host/common" "$ROOT/tests/host/report" "$tmp/tests/host/"
if ! gprbuild -q -p -P "$tmp/tests/host/report/report.gpr" > "$tmp/build.log" 2>&1; then
  cat "$tmp/build.log" >&2
  echo "FAIL: the Host_Report test programs do not build" >&2
  exit 1
fi
bin="$tmp/tests/host/report/bin"

# run <program>: output in $tmp/out, status in $rc
run () { "$bin/$1" > "$tmp/out" 2>&1; rc=$?; }

run report_ok
[ $rc -eq 0 ] && pass "all checks hold: exit 0" || fail "all checks hold: exit 0 (exit $rc)"
grep -q '^TEST report_ok: PASS$' "$tmp/out" \
  && pass "all checks hold: prints PASS" || fail "all checks hold: prints PASS"
grep -q '^TEST report_ok: START$' "$tmp/out" \
  && pass "prints the START line" || fail "prints the START line"
grep -q '^  ok: no failure so far$' "$tmp/out" \
  && pass "prints one ok line per check" || fail "prints one ok line per check"

run report_fail
[ $rc -ne 0 ] && pass "a failed check: exit non-zero" || fail "a failed check: exit non-zero (exit $rc)"
grep -q '^  FAIL: does not hold$' "$tmp/out" \
  && grep -q '^TEST report_fail: FAIL$' "$tmp/out" \
  && pass "a failed check: names it and prints FAIL" || fail "a failed check: names it and prints FAIL"

run report_none
[ $rc -ne 0 ] && pass "no check at all: exit non-zero" || fail "no check at all: exit non-zero (exit $rc)"
grep -q '^TEST report_none: FAIL$' "$tmp/out" \
  && pass "no check at all: prints FAIL" || fail "no check at all: prints FAIL"

run report_unfinished
[ $rc -ne 0 ] && pass "no Finish: exit non-zero" || fail "no Finish: exit non-zero (exit $rc)"

run report_raises
[ $rc -ne 0 ] && pass "an unhandled exception: exit non-zero" || fail "an unhandled exception: exit non-zero (exit $rc)"

# Every host suite is a directory with a run.sh (./x test host runs nothing else).
for d in "$ROOT"/tests/host/*/; do
  n="$(basename "$d")"
  [ "$n" = common ] && continue
  [ -f "$d/run.sh" ] && pass "suite $n has a run.sh" || fail "suite $n has a run.sh"
done

echo "summary: $fails failure(s)"
[ $fails -eq 0 ]
