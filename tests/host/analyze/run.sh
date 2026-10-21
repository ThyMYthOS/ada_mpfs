#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Tests for tools/analyze.sh with a stand-in for adalang_analyzer (the real one is
# a Libadalang-based crate that is not installed everywhere). Every way the script
# could pass without analysing (no analyzer, another version, no baseline, an
# analyzer that prints nothing, an empty or malformed list, a missing project,
# an unknown name) must make it exit non-zero, a new finding must fail, and the
# rule sets and baselines must be the right ones. Exits non-zero on any failure.
#
# What this does not show: that the real adalang_analyzer accepts these arguments
# and prints "Baseline matches:" (the invocation is that of ada_esp32s3).

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
ANALYZE="$ROOT/tools/analyze.sh"
fails=0

pass () { echo "ok:   $1"; }
fail () { echo "FAIL: $1" >&2; fails=$((fails + 1)); }

expect_rc () {
  local desc="$1" want="$2"; shift 2
  "$@" >/dev/null 2>&1
  local rc=$?
  if { [ "$want" = 0 ] && [ $rc -eq 0 ]; } || { [ "$want" = nonzero ] && [ $rc -ne 0 ]; } \
     || { [ "$want" -eq "$want" ] 2>/dev/null && [ "$rc" = "$want" ]; }; then
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
export FAKE_PIN="$ADALANG_ANALYZER_VERSION"   # what the stand-in reports unless a test sets FAKE_VERSION

# The stand-in. FAKE_MODE: clean (exit 0, "Baseline matches"), new (a finding, exit 1),
# silent (exit 0 and no output), nowrite (--write-baseline writes nothing).
mkdir -p "$tmp/bin" "$tmp/p" "$tmp/base"
cat > "$tmp/bin/adalang_analyzer" <<'EOF2'
#!/bin/bash
if [ "$1" = --version ]; then echo "adalang_analyzer ${FAKE_VERSION:-$FAKE_PIN}"; exit 0; fi
echo "$*" >> "$FAKE_DIR/args.log"
mode="${FAKE_MODE:-clean}"
for a in "$@"; do
  case "$a" in
    --write-baseline=*)
      [ "$mode" = nowrite ] || printf '# AdaLang Analyzer finding fingerprints, version 2\nabc\ndef\n' > "${a#--write-baseline=}"
      exit 0 ;;
  esac
done
case "$mode" in
  silent) exit 0 ;;
  new) echo "/work/libs/x/src/x.adb:3:4: warning: a new finding"; echo "1 new finding"; exit 1 ;;
  *) echo "Baseline matches: 2 finding(s)"; exit 0 ;;
esac
EOF2
chmod +x "$tmp/bin/adalang_analyzer"
: > "$tmp/p/a.gpr"; : > "$tmp/p/b.gpr"
printf 'name\tproject\targs\n' > "$tmp/ok.list"
printf 'alpha\t%s\t-\nbeta\t%s\t-Xmode=fast\n' "$tmp/p/a.gpr" "$tmp/p/b.gpr" >> "$tmp/ok.list"
printf '# baseline\nabc\n' > "$tmp/base/alpha.baseline"
printf '# baseline\nabc\n' > "$tmp/base/beta.baseline"
printf '# baseline\nabc\n' > "$tmp/base/alpha.style.baseline"
printf '# baseline\nabc\n' > "$tmp/base/beta.style.baseline"

an () {   # an [env...] -- [args...]
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  : > "$tmp/args.log"
  env PATH="$tmp/bin:$PATH" ANALYZE_NO_ENV=1 ADALANG_ANALYZER_VERSION="$ADALANG_ANALYZER_VERSION" FAKE_DIR="$tmp" \
      ANALYZE_LIST="$tmp/ok.list" ANALYZE_BASELINES="$tmp/base" "${envs[@]}" bash "$ANALYZE" "$@"
}

expect_rc  "stand-in: no new findings passes" 0 an
expect_out "stand-in: says analyze OK" "analyze OK: 2 project(s)" an
expect_out "stand-in: shows the analyzer's own line" "Baseline matches: 2 finding(s)" an
expect_rc  "stand-in: a new finding fails" nonzero an FAKE_MODE=new
expect_out "stand-in: shows the finding" "x.adb:3:4: warning: a new finding" an FAKE_MODE=new
expect_rc  "stand-in: an analyzer that exits 0 and prints nothing fails" nonzero an FAKE_MODE=silent
expect_out "stand-in: says it did not run as expected" "did not run as expected" an FAKE_MODE=silent
expect_rc  "stand-in: another analyzer version fails" nonzero an FAKE_VERSION=0.9
expect_out "stand-in: names the pinned version" "the pinned version is $ADALANG_ANALYZER_VERSION" an FAKE_VERSION=0.9
expect_rc  "stand-in: an unpinned version fails" nonzero an ADALANG_ANALYZER_VERSION=

# the analyzer is missing: exit 127
env PATH=/usr/bin:/bin ANALYZE_NO_ENV=1 ADALANG_ANALYZER_VERSION="$ADALANG_ANALYZER_VERSION" \
    ANALYZE_LIST="$tmp/ok.list" ANALYZE_BASELINES="$tmp/base" bash "$ANALYZE" >/dev/null 2>&1
[ $? -eq 127 ] && pass "stand-in: without adalang_analyzer it exits 127" || fail "stand-in: without adalang_analyzer it exits 127"
expect_out "stand-in: says how to install it" "./x toolchain install" env PATH=/usr/bin:/bin ANALYZE_NO_ENV=1 ADALANG_ANALYZER_VERSION="$ADALANG_ANALYZER_VERSION" ANALYZE_LIST="$tmp/ok.list" ANALYZE_BASELINES="$tmp/base" bash "$ANALYZE"

# rule sets and baselines
an >/dev/null 2>&1
grep -q -- '--recommended' "$tmp/args.log" && grep -q 'Constant_Condition' "$tmp/args.log" && ! grep -q 'Cyclomatic_Complexity' "$tmp/args.log" \
  && pass "defects: --recommended plus the extra checks, not the style checks" \
  || fail "defects: --recommended plus the extra checks, not the style checks"
grep -q -- "--baseline=$tmp/base/alpha.baseline" "$tmp/args.log" && ! grep -q 'style.baseline' "$tmp/args.log" \
  && pass "defects: measured against <name>.baseline" || fail "defects: measured against <name>.baseline"
grep -q -- '-Xmode=fast' "$tmp/args.log" && pass "the args of a row reach the analyzer" || fail "the args of a row reach the analyzer"
an -- --style >/dev/null 2>&1
grep -q 'Cyclomatic_Complexity' "$tmp/args.log" && ! grep -q -- '--recommended' "$tmp/args.log" \
  && pass "style: the style checks, not --recommended" || fail "style: the style checks, not --recommended"
grep -q -- "--baseline=$tmp/base/beta.style.baseline" "$tmp/args.log" \
  && pass "style: measured against <name>.style.baseline" || fail "style: measured against <name>.style.baseline"
n_extra="$(sed -n '/^ANALYZE_EXTRA_CHECKS=/,/"$/p' "$ANALYZE" | tr -d '\\"\n' | sed 's/ANALYZE_EXTRA_CHECKS=//' | tr ',' '\n' | grep -c .)"
[ "$n_extra" = 10 ] && pass "ten extra defect checks" || fail "ten extra defect checks (found $n_extra)"

# one project
an -- alpha >/dev/null 2>&1
[ "$(wc -l < "$tmp/args.log")" = 1 ] && pass "a name selects one project" || fail "a name selects one project"
expect_rc  "stand-in: an unknown name fails" 2 an -- nosuch
expect_rc  "stand-in: an unknown option fails" 2 an -- --bogus

# baselines
rm "$tmp/base/beta.baseline"
expect_rc  "stand-in: a project without a baseline fails" nonzero an
expect_out "stand-in: says which baseline is missing and how to write it" "no baseline" an
expect_rc  "stand-in: --style needs its own baseline, the other one does not stand in" 0 an -- --style
rm "$tmp/base/alpha.style.baseline"
expect_rc  "stand-in: a missing style baseline fails" nonzero an -- --style
rm "$tmp/base/alpha.baseline" "$tmp/base/beta.style.baseline"
expect_rc  "update: --update-baseline writes the baselines" 0 an -- --update-baseline
[ -f "$tmp/base/alpha.baseline" ] && [ -f "$tmp/base/beta.baseline" ] \
  && pass "update: both defect baselines exist" || fail "update: both defect baselines exist"
expect_rc  "update: the new baselines are accepted" 0 an
expect_rc  "update: --style --update-baseline writes the style baselines" 0 an -- --style --update-baseline
[ -f "$tmp/base/beta.style.baseline" ] && pass "update: the style baselines exist" || fail "update: the style baselines exist"
expect_rc  "update: an analyzer that writes no baseline fails" nonzero an FAKE_MODE=nowrite -- --update-baseline

# the list
: > "$tmp/empty.list"
expect_rc  "list: an empty list fails" nonzero an ANALYZE_LIST="$tmp/empty.list"
printf 'name\tproject\targs\n' > "$tmp/header.list"
expect_rc  "list: a list without a project fails" nonzero an ANALYZE_LIST="$tmp/header.list"
printf 'name\tproject\n' > "$tmp/badhdr.list"
expect_rc  "list: a wrong header fails" nonzero an ANALYZE_LIST="$tmp/badhdr.list"
printf 'name\tproject\targs\nalpha\t%s\n' "$tmp/p/a.gpr" > "$tmp/badrow.list"
expect_rc  "list: a row without args fails" nonzero an ANALYZE_LIST="$tmp/badrow.list"
printf 'name\tproject\targs\nal pha\t%s\t-\n' "$tmp/p/a.gpr" > "$tmp/badname.list"
expect_rc  "list: a name with a blank fails" nonzero an ANALYZE_LIST="$tmp/badname.list"
printf 'name\tproject\targs\nalpha\t%s\t-\n' "$tmp/p/none.gpr" > "$tmp/nogpr.list"
expect_rc  "list: a missing project file fails" nonzero an ANALYZE_LIST="$tmp/nogpr.list"
expect_rc  "list: a missing list fails" nonzero an ANALYZE_LIST="$tmp/none.list"

# the committed list and baseline directory
n=0
while IFS="$tab" read -r name project args; do
  n=$((n + 1))
  [ -f "$ROOT/$project" ] && pass "analyze.list: $project exists" || fail "analyze.list: $project exists"
done < <(grep -v '^#' "$ROOT/tools/analyze.list" | tail -n +2)
[ $n -gt 0 ] && pass "analyze.list: lists projects" || fail "analyze.list: lists projects"
[ -d "$ROOT/tools/analyzer-baselines" ] && pass "the baseline directory exists" || fail "the baseline directory exists"

echo "summary: $fails failure(s)"
[ $fails -eq 0 ]
