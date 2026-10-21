#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Tests for tools/stack_report and ./x stack. The analyser is built natively and
# run on small .su/.ci fixtures with known frames and call chains (the figures
# are checked, so a report that no longer adds the chain fails), including a
# recursion and a dynamic frame; it must exit non-zero for a missing directory,
# a directory without .su files and a missing argument. ./x stack is run on a
# copy of the tree: with the real compiler on an example, and on an example
# that ignores STACK_ANALYSIS, which must fail. Exits non-zero on any failure.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fails=0

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

. "$ROOT/tools/mpfs-env.sh"
mpfs_toolchain_on_path >/dev/null 2>&1 || true
command -v gprbuild >/dev/null 2>&1 || { echo "FAIL: no gprbuild (./x toolchain install gnat)" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -r "$tmp"' EXIT
tab="$(printf '\t')"

# --- the analyser on fixtures -------------------------------------------------
mkdir -p "$tmp/tool"
cp "$ROOT"/tools/stack_report/stack_report.adb "$ROOT"/tools/stack_report/stack_report.gpr "$tmp/tool/"
if ! gprbuild -q -p -P "$tmp/tool/stack_report.gpr" > "$tmp/build.log" 2>&1; then
  cat "$tmp/build.log" >&2
  echo "FAIL: tools/stack_report does not build" >&2
  exit 1
fi
SR="$tmp/tool/stack_report"

# ok: Main (48) calls Leaf (16) and Mid (32), Mid calls Leaf: the deepest chain is
# Main -> Mid -> Leaf = 96 bytes.
mkdir -p "$tmp/ok"
printf '/x/a.adb:3:1:Main\t48\tstatic\n/x/a.adb:10:1:Leaf\t16\tstatic\n/x/a.adb:20:1:Mid\t32\tstatic\n' > "$tmp/ok/a.su"
cat > "$tmp/ok/a.ci" <<'EOF'
graph: { title: "/x/a.adb"
node: { title: "main" label: "Main\n/x/a.adb:3:1\n48 bytes (static)\n0 dynamic objects" }
node: { title: "leaf" label: "Leaf\n/x/a.adb:10:1\n16 bytes (static)\n0 dynamic objects" }
node: { title: "mid" label: "Mid\n/x/a.adb:20:1\n32 bytes (static)\n0 dynamic objects" }
edge: { sourcename: "main" targetname: "leaf" label: "/x/a.adb:4:4" }
edge: { sourcename: "main" targetname: "mid" label: "/x/a.adb:5:4" }
edge: { sourcename: "mid" targetname: "leaf" label: "/x/a.adb:21:4" }
}
EOF
expect_rc  "analyser: a directory with .su and .ci files is reported" 0 "$SR" "$tmp/ok"
expect_out "analyser: the biggest frame comes first" "48  static           a.adb:3  Main" "$SR" "$tmp/ok"
expect_out "analyser: the deepest chain is summed (48 + 32 + 16)" "96 B              Main" "$SR" "$tmp/ok"
expect_out "analyser: the chain is named" "Main -> Mid -> Leaf" "$SR" "$tmp/ok"
expect_out "analyser: static frames are said to be a real bound" "All frames are STATIC" "$SR" "$tmp/ok"
out="$("$SR" "$tmp/ok" --top 1)"
case "$out" in *"Leaf"*"Leaf"*) fail "analyser: --top 1 limits the per-frame list" ;; *) pass "analyser: --top 1 limits the per-frame list" ;; esac

# dyn: a frame whose size is not constant
mkdir -p "$tmp/dyn"
printf '/x/d.adb:3:1:Main\t48\tstatic\n/x/d.adb:10:1:Vla\t64\tdynamic,bounded\n' > "$tmp/dyn/d.su"
cat > "$tmp/dyn/d.ci" <<'EOF'
node: { title: "main" label: "Main\n/x/d.adb:3:1\n48 bytes (static)" }
node: { title: "vla" label: "Vla\n/x/d.adb:10:1\n64 bytes (dynamic,bounded)" }
edge: { sourcename: "main" targetname: "vla" label: "/x/d.adb:4:4" }
EOF
expect_out "analyser: a dynamic frame is called out" "DYNAMIC/BOUNDED frame(s)" "$SR" "$tmp/dyn"

# rec: a call cycle
mkdir -p "$tmp/rec"
printf '/x/r.adb:3:1:Main\t16\tstatic\n/x/r.adb:10:1:Ping\t16\tstatic\n/x/r.adb:20:1:Pong\t16\tstatic\n' > "$tmp/rec/r.su"
cat > "$tmp/rec/r.ci" <<'EOF'
node: { title: "main" label: "Main\n/x/r.adb:3:1\n16 bytes (static)" }
node: { title: "ping" label: "Ping\n/x/r.adb:10:1\n16 bytes (static)" }
node: { title: "pong" label: "Pong\n/x/r.adb:20:1\n16 bytes (static)" }
edge: { sourcename: "main" targetname: "ping" label: "/x/r.adb:4:4" }
edge: { sourcename: "ping" targetname: "pong" label: "/x/r.adb:11:4" }
edge: { sourcename: "pong" targetname: "ping" label: "/x/r.adb:21:4" }
EOF
expect_out "analyser: a recursion is flagged" "!!RECURSIVE" "$SR" "$tmp/rec"

# ext: a call into a unit that has no frame (the runtime)
mkdir -p "$tmp/ext"
printf '/x/e.adb:3:1:Main\t16\tstatic\n' > "$tmp/ext/e.su"
cat > "$tmp/ext/e.ci" <<'EOF'
node: { title: "main" label: "Main\n/x/e.adb:3:1\n16 bytes (static)" }
node: { title: "memcpy" label: "memcpy" shape : ellipse }
edge: { sourcename: "main" targetname: "memcpy" label: "/x/e.adb:4:4" }
EOF
expect_out "analyser: a chain that calls code without a frame is marked +ext" "+ext" "$SR" "$tmp/ext"

# the negative cases
expect_rc  "analyser: a missing directory fails" nonzero "$SR" "$tmp/nope"
expect_out "analyser: says the directory is missing" "no such dir" "$SR" "$tmp/nope"
mkdir -p "$tmp/empty"
expect_rc  "analyser: a directory without .su files fails" nonzero "$SR" "$tmp/empty"
expect_out "analyser: says there are no .su files" "no *.su files" "$SR" "$tmp/empty"
: > "$tmp/empty/x.ci"
expect_rc  "analyser: a .ci file alone fails" nonzero "$SR" "$tmp/empty"
expect_rc  "analyser: no argument fails" nonzero "$SR"

# --- ./x stack, in a copy of the tree ------------------------------------------
mkdir -p "$tmp/tree/tools" "$tmp/tree/tests"
cp "$ROOT/x" "$tmp/tree/x"
cp "$ROOT/tools/mpfs-env.sh" "$ROOT/tools/toolchain.env" "$tmp/tree/tools/"
cp -R "$ROOT/tools/stack_report" "$tmp/tree/tools/"
rm -rf "$tmp/tree/tools/stack_report/obj" "$tmp/tree/tools/stack_report/stack_report"
cp -R "$ROOT/examples" "$tmp/tree/"
cp -R "$ROOT/tests/common" "$tmp/tree/tests/"
find "$tmp/tree/examples" \( -name 'obj-*' -o -name 'bin-*' \) -prune -exec rm -r {} +
TX="$tmp/tree/x"

expect_rc  "x stack: an example is built with the analysis and reported" 0 bash "$TX" stack report_test
expect_out "x stack: the frames of Test_Report are in the report" "test_report.adb" bash "$TX" stack report_test
expect_out "x stack: the chain through Info is summed (48 + 48)" "96 B              Main" bash "$TX" stack report_test --hart u54
expect_out "x stack: --hart selects the image" "Per-frame stack usage" bash "$TX" stack report_test --hart u54 --top 2
if find "$tmp/tree/examples/report_test" -name '*.su' | grep -q .; then
  fail "x stack: leaves no analysis objects behind"
else
  pass "x stack: leaves no analysis objects behind"
fi
expect_rc  "x stack: an unknown example fails" nonzero bash "$TX" stack nosuch
expect_rc  "x stack: an invalid hart fails" nonzero bash "$TX" stack report_test --hart r5
expect_rc  "x stack: an invalid --top fails" nonzero bash "$TX" stack report_test --top 0
expect_rc  "x stack: an unknown option fails" nonzero bash "$TX" stack report_test --bogus

# An example that ignores STACK_ANALYSIS writes no .su files: the analyser fails,
# and so must x.
cp -R "$tmp/tree/examples/report_test" "$tmp/tree/examples/no_analysis"
sed -i 's/ & Analysis;/;/' "$tmp/tree/examples/no_analysis/app.gpr"
expect_rc  "x stack: an example that writes no .su files fails" nonzero bash "$TX" stack no_analysis

echo "summary: $fails failure(s)"
[ $fails -eq 0 ]
