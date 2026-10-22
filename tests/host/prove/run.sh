#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Tests for tools/prove.sh. With a stand-in for gnatprove, every way the script
# could report success without a proof (a different version, a summary with
# unproved checks, no summary, a failing exit status, a message graded medium,
# no project, a missing project file) must make it exit non-zero. With the
# pinned gnatprove, if it is installed, the committed projects must prove and a
# project with an overflow that cannot be proved must fail. Exits non-zero on any
# failure; the cases that need the real gnatprove are reported as skipped, and
# counted, when it is not installed.
# @verifies BLD-001

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PROVE="$ROOT/tools/prove.sh"
fails=0; skipped=0

pass () { echo "ok:   $1"; }
fail () { echo "FAIL: $1" >&2; fails=$((fails + 1)); }

expect_rc () {
  local desc="$1" want="$2"; shift 2
  "$@" >/dev/null 2>&1
  local rc=$?
  if { [ "$want" = 0 ] && [ $rc -eq 0 ]; } || { [ "$want" = nonzero ] && [ $rc -ne 0 ]; }; then
    pass "$desc"
  else
    fail "$desc (exit $rc, wanted $want)"
  fi
}

expect_out () {
  local desc="$1" needle="$2"; shift 2
  local out
  out="$("$@" 2>&1)"
  case "$out" in *"$needle"*) pass "$desc" ;; *) fail "$desc (no '$needle' in: $out)" ;; esac
}

tmp="$(mktemp -d)"
trap 'rm -r "$tmp"' EXIT
tab="$(printf '\t')"
. "$ROOT/tools/toolchain.env"

# A stand-in for gnatprove. FAKE_MODE: ok, unproved, nosummary, exit1, medium.
mkdir -p "$tmp/bin" "$tmp/p"
cat > "$tmp/bin/gnatprove" <<'EOF2'
#!/bin/bash
if [ "$1" = --version ]; then echo "FSF ${FAKE_VERSION:-16.1.0}"; exit 0; fi
report="$FAKE_DIR/gnatprove.out"
unproved="."; [ "${FAKE_MODE:-ok}" = unproved ] && unproved="2 (18%)"
cat > "$report" <<EOF3
SPARK Analysis results        Total       Flow    Provers   Justified   Unproved
Run-time Checks                   5          .     3 (Z3)           .          .
Total                            15    3 (20%)    12 (80%)           .  $unproved
EOF3
echo "Phase 3 of 3: flow analysis and proof ..."
[ "${FAKE_MODE:-ok}" = medium ] && echo "x.adb:1:1: medium: overflow check might fail"
[ "${FAKE_MODE:-ok}" = nosummary ] || echo "Summary logged in $report"
[ "${FAKE_MODE:-ok}" = exit1 ] && exit 1
exit 0
EOF2
chmod +x "$tmp/bin/gnatprove"
: > "$tmp/p/a.gpr"
printf 'project\tlabel\tswitches\n%s\tfake a\t-\n' "$tmp/p/a.gpr" > "$tmp/ok.list"

fake () {   # fake <list> [env...] -- [args...]
  local l="$1"; shift
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  env PATH="$tmp/bin:$PATH" PROVE_NO_ENV=1 GNATPROVE_VERSION="$GNATPROVE_VERSION" FAKE_DIR="$tmp" \
      PROVE_LIST="$l" "${envs[@]}" bash "$PROVE" "$@"
}

expect_rc  "stand-in: a proved project passes" 0 fake "$tmp/ok.list"
expect_out "stand-in: says prove OK" "prove OK: 1 project(s)" fake "$tmp/ok.list"
expect_rc  "stand-in: unproved checks fail" nonzero fake "$tmp/ok.list" FAKE_MODE=unproved
expect_out "stand-in: names the unproved count" "unproved checks reported: 2 (18%)" fake "$tmp/ok.list" FAKE_MODE=unproved
expect_rc  "stand-in: a missing summary fails" nonzero fake "$tmp/ok.list" FAKE_MODE=nosummary
expect_out "stand-in: says there is no summary" "no summary report found" fake "$tmp/ok.list" FAKE_MODE=nosummary
expect_rc  "stand-in: a nonzero exit status fails even with a clean summary" nonzero fake "$tmp/ok.list" FAKE_MODE=exit1
expect_rc  "stand-in: a message graded medium fails even with a clean summary" nonzero fake "$tmp/ok.list" FAKE_MODE=medium
expect_rc  "stand-in: another gnatprove version fails" nonzero fake "$tmp/ok.list" FAKE_VERSION=15.0
expect_out "stand-in: names the pinned version" "the pinned version is $GNATPROVE_VERSION" fake "$tmp/ok.list" FAKE_VERSION=15.0
expect_rc  "stand-in: without gnatprove it fails" nonzero env PATH=/usr/bin:/bin PROVE_NO_ENV=1 GNATPROVE_VERSION="$GNATPROVE_VERSION" PROVE_LIST="$tmp/ok.list" bash "$PROVE"
expect_out "stand-in: says gnatprove was not found" "gnatprove not found" env PATH=/usr/bin:/bin PROVE_NO_ENV=1 GNATPROVE_VERSION="$GNATPROVE_VERSION" PROVE_LIST="$tmp/ok.list" bash "$PROVE"
expect_rc  "stand-in: an unpinned version fails" nonzero fake "$tmp/ok.list" GNATPROVE_VERSION=
: > "$tmp/empty.list"
expect_rc  "stand-in: an empty list fails" nonzero fake "$tmp/empty.list"
printf 'project\tlabel\tswitches\n' > "$tmp/header.list"
expect_rc  "stand-in: a list without a project fails" nonzero fake "$tmp/header.list"
printf 'project\tlabel\n%s\tfake\n' "$tmp/p/a.gpr" > "$tmp/badhdr.list"
expect_rc  "stand-in: a wrong header fails" nonzero fake "$tmp/badhdr.list"
printf 'project\tlabel\tswitches\n%s\tfake\n' "$tmp/p/a.gpr" > "$tmp/badrow.list"
expect_rc  "stand-in: a row without switches fails" nonzero fake "$tmp/badrow.list"
printf 'project\tlabel\tswitches\n%s\tfake\t-\n' "$tmp/p/none.gpr" > "$tmp/nogpr.list"
expect_rc  "stand-in: a missing project file fails" nonzero fake "$tmp/nogpr.list"
expect_rc  "stand-in: a missing list fails" nonzero fake "$tmp/none.list"
expect_rc  "stand-in: a filter that matches nothing fails" nonzero fake "$tmp/ok.list" -- nothing-matches-this
expect_rc  "stand-in: a filter that matches runs the project" 0 fake "$tmp/ok.list" -- "fake a"
# A row's own switches reach gnatprove.
printf 'project\tlabel\tswitches\n%s\tfake a\t--level=4 --timeout=60\n' "$tmp/p/a.gpr" > "$tmp/sw.list"
mv "$tmp/bin/gnatprove" "$tmp/bin/gnatprove.real"
cat > "$tmp/bin/gnatprove" <<'EOF2'
#!/bin/bash
echo "$*" >> "$FAKE_DIR/args.log"
exec "$FAKE_DIR/bin/gnatprove.real" "$@"
EOF2
chmod +x "$tmp/bin/gnatprove"
fake "$tmp/sw.list" >/dev/null 2>&1
grep -q -- '--level=4 --timeout=60' "$tmp/args.log" && pass "stand-in: the switches of a row reach gnatprove" \
  || fail "stand-in: the switches of a row reach gnatprove"
fake "$tmp/ok.list" >/dev/null 2>&1
grep -q -- '--level=1 --prover=z3 --timeout=10' "$tmp/args.log" && pass "stand-in: '-' means the default switches" \
  || fail "stand-in: '-' means the default switches"

# The committed list: header, a project that exists, default switches.
list_c="$ROOT/tools/prove.list"
n=0
while IFS="$tab" read -r project label switches; do
  n=$((n + 1))
  [ -f "$ROOT/$project" ] && pass "prove.list: $project exists" || fail "prove.list: $project exists"
done < <(grep -v '^#' "$list_c" | tail -n +2)
[ $n -gt 0 ] && pass "prove.list: lists projects" || fail "prove.list: lists projects"

# The real gnatprove, if the pinned version is installed.
. "$ROOT/tools/mpfs-env.sh"
mpfs_toolchain_on_path >/dev/null 2>&1 || true
if command -v gnatprove >/dev/null 2>&1 && gnatprove --version 2>&1 | head -n 1 | grep -q "$GNATPROVE_VERSION"; then
  expect_rc  "gnatprove: the committed projects prove" 0 bash "$PROVE"
  printf 'project\tlabel\tswitches\n%s\tunprovable\t-\n' "$ROOT/tests/prove/fixtures/unprovable/unprovable.gpr" > "$tmp/unprovable.list"
  expect_rc  "gnatprove: a project with an unprovable overflow fails" nonzero env PROVE_LIST="$tmp/unprovable.list" bash "$PROVE"
  expect_out "gnatprove: the unprovable overflow is reported" "overflow check might fail" env PROVE_LIST="$tmp/unprovable.list" bash "$PROVE"
  expect_out "gnatprove: and the unproved count is" "unproved checks reported: 1" env PROVE_LIST="$tmp/unprovable.list" bash "$PROVE"
else
  echo "SKIP: gnatprove $GNATPROVE_VERSION is not installed; the cases with the real gnatprove did not run (./x toolchain install)"
  skipped=4
fi

echo "summary: $fails failure(s), $skipped skipped"
[ $fails -eq 0 ]
