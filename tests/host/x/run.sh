#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Smoke test for ./x: every verb is listed in the help, option validation rejects
# invalid and excluded combinations, and missing tool scripts fail instead of
# passing silently. Exits non-zero on any failure.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
X="$ROOT/x"
fails=0

pass () { echo "ok:   $1"; }
fail () { echo "FAIL: $1" >&2; fails=$((fails + 1)); }

# expect_rc <description> <expected exit code: 0|nonzero> <command...>
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

# Every verb appears in the help text.
help="$("$X" help)"
for verb in help list toolchain build clean new qemu mem test metrics analyze stack \
            svd pac trace prove hw; do
  case "$help" in *"./x $verb"*) pass "help lists $verb" ;; *) fail "help lists $verb" ;; esac
done

expect_rc "help exits 0"            0       "$X" help
expect_rc "list exits 0"            0       "$X" list
expect_rc "list --json exits 0"     0       "$X" list --json
expect_rc "unknown verb fails"      nonzero "$X" no-such-verb
expect_rc "toolchain rejects an unknown install target" nonzero "$X" toolchain install bogus
expect_rc "svd without a mode fails" nonzero "$X" svd
expect_rc "svd rejects an unknown mode" nonzero "$X" svd bogus
expect_rc "svd probe needs a peripheral" nonzero "$X" svd probe

# Option validation happens before the toolchain is touched, so these hold on any host.
# A throwaway example is needed to get past the example lookup.
tmp="$(mktemp -d)"
trap 'rm -r "$tmp"' EXIT
mkdir -p "$tmp/tools"
cp "$X" "$tmp/x"
cp "$ROOT/tools/mpfs-env.sh" "$ROOT/tools/toolchain.env" "$tmp/tools/"
TX="$tmp/x"
expect_rc "new creates an example"      0       "$TX" new smoke
expect_rc "new refuses an existing one" nonzero "$TX" new smoke
expect_rc "new rejects a bad name"      nonzero "$TX" new Bad-Name
expect_rc "list shows the new example"  0       "$TX" list
"$TX" list | grep -q '^smoke ' && pass "list contains smoke" || fail "list contains smoke"

expect_rc "build: invalid hart"           nonzero "$TX" build smoke --hart foo
expect_rc "build: invalid priv"           nonzero "$TX" build smoke --priv x
expect_rc "build: invalid profile"        nonzero "$TX" build smoke -P bad
expect_rc "build: harts without u54"      nonzero "$TX" build smoke --harts 1-4
expect_rc "build: SMP with the E51"       nonzero "$TX" build smoke --hart e51 --harts 1,2
expect_rc "build: hart out of range"      nonzero "$TX" build smoke --hart u54 --harts 5
expect_rc "build: descending range"       nonzero "$TX" build smoke --hart u54 --harts 3-1
expect_rc "build: unknown option"         nonzero "$TX" build smoke --bogus
expect_rc "build: unknown example"        nonzero "$TX" build nope
expect_rc "qemu: invalid hart number"     nonzero "$TX" qemu smoke --hart 9
expect_rc "clean exits 0"                 0       "$TX" clean smoke

# Verbs with a missing implementation script must fail, not succeed silently.
for v in "analyze" "stack smoke" "prove" "svd merge" "pac generate" "hw probe" "metrics verify"; do
  # shellcheck disable=SC2086
  expect_rc "missing script: $v fails" nonzero "$TX" $v
done
expect_rc "bad subcommand: svd"   nonzero "$TX" svd bogus
expect_rc "bad subcommand: pac"   nonzero "$TX" pac bogus
expect_rc "bad subcommand: test"  nonzero "$TX" test bogus

echo "summary: $fails failure(s)"
[ $fails -eq 0 ]
