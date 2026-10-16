#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Tests for tools/trace.py on small fixture trees: the matrix it writes, every way the check
# fails (malformed or duplicate ID, an ID in the wrong file, a missing or unknown field, a
# reference to an unknown ID, a TSF requirement without a test, a stale matrix), the comment
# styles of the markers, and the committed catalogue of the repository. Exits non-zero on any
# failure.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fails=0
. "$ROOT/tools/mpfs-env.sh"
mpfs_find_python
TRACE="$ROOT/tools/trace.py"

pass () { echo "ok:   $1"; }
fail () { echo "FAIL: $1" >&2; fails=$((fails + 1)); }

tmp="$(mktemp -d)"
trap 'rm -r "$tmp"' EXIT

# tree <name>: a fresh fixture tree with one requirement in each of two areas
tree () {
  local t="$tmp/$1"
  rm -rf "$t"; mkdir -p "$t/docs/requirements" "$t/docs/assurance" "$t/src" "$t/tests"
  cat > "$t/docs/requirements/bld.yaml" <<'YAML'
requirements:
  - id: BLD-001
    text: Images are reproducible.
    tsf: false
    source: plan
  - id: BLD-002
    text: The link fails on an ABI mismatch.
    tsf: true
    source: plan
YAML
  cat > "$t/docs/requirements/hal.yaml" <<'YAML'
requirements:
  - id: HAL-SPI-004
    text: A transfer | with a pipe in the text.
    tsf: false
    source: plan
YAML
  printf -- '--  @req BLD-002\npackage X is end X;\n' > "$t/src/x.ads"
  printf '# @verifies BLD-002, BLD-001\n' > "$t/tests/t.sh"
  echo "$t"
}

# run <tree> [args]: output in $tmp/out, status in $rc
run () { local t="$1"; shift; "$MPFS_PYTHON" -I "$TRACE" --root "$t" "$@" > "$tmp/out" 2>&1; rc=$?; }
expect () {   # expect <description> <status> <text in the output>
  if [ $rc -eq "$2" ] && grep -qF -- "$3" "$tmp/out"; then pass "$1"; else fail "$1 (exit $rc, wanted $2 and '$3')"; sed 's/^/    /' "$tmp/out" >&2; fi
}

t="$(tree ok)"
run "$t" --check
expect "a missing matrix fails the check" 1 "trace-matrix.md is missing"
run "$t"
expect "writing the matrix succeeds" 0 "wrote docs/assurance/trace-matrix.md (3 requirement(s))"
run "$t" --check
expect "the written matrix passes the check" 0 "ok: 3 requirement(s)"
grep -qF '| BLD-002 | yes | The link fails on an ABI mismatch. | plan | `src/x.ads:1` | `tests/t.sh:1` |' "$t/docs/assurance/trace-matrix.md" \
  && pass "the matrix row has the TSF flag, the @req and the @verifies" || fail "the matrix row has the TSF flag, the @req and the @verifies"
grep -qF 'A transfer \| with a pipe' "$t/docs/assurance/trace-matrix.md" \
  && pass "a pipe in the text is escaped" || fail "a pipe in the text is escaped"
grep -qF '| HAL-SPI-004 | no |' "$t/docs/assurance/trace-matrix.md" && grep -qF 'warning: HAL-SPI-004 has no @verifies' "$tmp/out" \
  && pass "a non-TSF requirement without a test is listed and warned about" || fail "a non-TSF requirement without a test is listed and warned about"
cp "$t/docs/assurance/trace-matrix.md" "$tmp/first.md"; run "$t"
cmp -s "$tmp/first.md" "$t/docs/assurance/trace-matrix.md" \
  && pass "writing twice gives the same file" || fail "writing twice gives the same file"

printf 'package Y is end Y;\n-- @req BLD-099\n' >> "$t/src/x.ads"
run "$t" --check
expect "a reference to an unknown ID fails" 1 "src/x.ads:4: @req BLD-099 is not in the catalogue"

t="$(tree stale)"; run "$t"; printf '# @verifies BLD-001\n' > "$t/tests/u.sh"; run "$t" --check
expect "a matrix that is out of date fails" 1 "trace-matrix.md is out of date"

t="$(tree notest)"; printf '# nothing\n' > "$t/tests/t.sh"; run "$t"; run "$t" --check
expect "a TSF requirement without @verifies fails" 1 "BLD-002 is in the TSF and has no @verifies"

t="$(tree styles)"
printf '// @verifies BLD-002\n/* @verifies BLD-001 */\n; @req BLD-001\n  ; @verifies HAL-SPI-004\n' > "$t/tests/s.txt"
printf '#!/bin/sh\necho "BLD-002 is not a marker"\n' > "$t/tests/n.sh"
run "$t"; run "$t" --check
expect "all the comment styles are accepted" 0 "ok: 3 requirement(s)"
grep -qF "tests/s.txt:4" "$t/docs/assurance/trace-matrix.md" && ! grep -qF 'tests/n.sh' "$t/docs/assurance/trace-matrix.md" \
  && pass "text that is not a marker comment is not a reference" || fail "text that is not a marker comment is not a reference"
printf 'See `@req BLD-077` in the docs.\n' > "$t/NOTES.md"; run "$t" --check
expect "Markdown is not scanned" 0 "ok: 3 requirement(s)"

t="$(tree bad_id)"; sed -i 's/id: BLD-002/id: bld-2/' "$t/docs/requirements/bld.yaml"; run "$t" --check
expect "a malformed ID fails" 1 "the id 'bld-2' is not <AREA>-<NNN>"

t="$(tree dup)"; sed -i 's/id: HAL-SPI-004/id: BLD-001/' "$t/docs/requirements/hal.yaml"; run "$t" --check
expect "an ID in the wrong file fails" 1 "BLD-001 belongs in bld.yaml, not in hal.yaml"
expect "a duplicate ID fails" 1 "BLD-001 is defined twice"

t="$(tree field)"; sed -i '/source: plan/{x;s/^/x/;/^x\{2\}$/{x;d};x}' "$t/docs/requirements/bld.yaml"; run "$t" --check
expect "a missing field fails" 1 "missing field(s) source"
t="$(tree extra)"; sed -i 's/    tsf: true/    tsf: true\n    owner: nobody/' "$t/docs/requirements/bld.yaml"; run "$t" --check
expect "an unknown field fails" 1 "unknown field(s) owner"
t="$(tree tsfval)"; sed -i 's/tsf: true/tsf: maybe/' "$t/docs/requirements/bld.yaml"; run "$t" --check
expect "a TSF flag that is not a boolean fails" 1 "tsf must be true or false"
t="$(tree notyaml)"; printf 'requirements: [\n' > "$t/docs/requirements/bld.yaml"; run "$t" --check
expect "a catalogue that is not YAML is a usage error" 2 "not valid YAML"
t="$(tree nolist)"; printf 'foo: 1\n' > "$t/docs/requirements/bld.yaml"; run "$t" --check
expect "a catalogue without the list is a usage error" 2 "list \`requirements\`"
run "$tmp/ok" --bogus
expect "an unknown option is a usage error" 2 "usage: trace.py"

t="$tmp/empty"; mkdir -p "$t/docs/requirements"; run "$t"; run "$t" --check
expect "no requirements at all is fine" 0 "ok: 0 requirement(s)"

# the repository itself
run "$ROOT" --check
expect "the committed catalogue, references and matrix are consistent" 0 "trace: ok:"

[ "$fails" -eq 0 ] && echo "summary: 0 failure(s)" || { echo "summary: $fails failure(s)" >&2; exit 1; }
