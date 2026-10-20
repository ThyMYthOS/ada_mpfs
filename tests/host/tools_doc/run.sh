#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Tests for tools/tools_table.py on small fixture trees: the table it writes from the pins, every
# way the check fails (a version that changed in tools/toolchain.env or tools/requirements.txt, an
# edit inside the table, a tool without a row of its own), every way the inputs can be wrong (a
# missing or empty pin, a missing checksum, a malformed line, missing or misplaced markers, a
# missing file), that text outside the markers is not touched, and the committed document of the
# repository. Each failure has a control case that passes on the same tree. Exits non-zero on
# any failure.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fails=0
. "$ROOT/tools/mpfs-env.sh"
mpfs_find_python
TABLE="$ROOT/tools/tools_table.py"

pass () { echo "ok:   $1"; }
fail () { echo "FAIL: $1" >&2; fails=$((fails + 1)); }

tmp="$(mktemp -d)"
trap 'rm -r "$tmp"' EXIT

NAMES="alr gnat_riscv64_elf gnat_native gprbuild gnatprove adalang_analyzer svd2ada svdtools rustc Renode QEMU Python PyYAML typing_extensions"

# tree <name>: a fresh fixture tree with pins, requirements and a document that has a row for every tool
tree () {
  local t="$tmp/$1" n
  rm -rf "$t"; mkdir -p "$t/tools" "$t/docs/assurance"
  cat > "$t/tools/toolchain.env" <<'ENV'
# a comment
ALR_VERSION=2.1.1
ALR_SHA256_X86_64_LINUX=09c66bcd8c35dd4b97b72c3d9b76e44caa6964a2db35aba069f396f00f1f64c7
ALR_SHA256_UNIVERSAL_MACOS=66fc5fb11ac10e3ebf5840e201cf284948475aa9d50a7db5dff045d112c91e02

GNAT_RISCV64_VERSION=15.3.1
GNAT_NATIVE_VERSION=15.3.1
GPRBUILD_VERSION=26.0.1
GNATPROVE_VERSION=16.1.0
ADALANG_ANALYZER_VERSION=1.6.0
SVD2ADA_COMMIT=314265ec980ed9498b421279b2a26f9062fb07b8
SVDTOOLS_VERSION=0.5.0
SVDTOOLS_SHA256_X86_64_LINUX=4d5a911d2adcf917bd98f6b1520c53299d509b0820fad0ff7189501133c44810
SVDTOOLS_RUSTC_MIN=1.83
RENODE_VERSION=1.17.0
RENODE_SHA256_X86_64_LINUX=4ba7c68b59e2447f188ef4b4b112fcccd2802582c460beedceb63b84e5605a5f
QEMU_MIN=10.1
PYTHON_MIN=3.13
ENV
  printf '# pinned\nPyYAML==6.0.3\n\ntyping_extensions==4.16.0\n' > "$t/tools/requirements.txt"
  {
    printf 'Intro text.\n\n<!-- tools-table:begin -->\n<!-- tools-table:end -->\n\n| Tool | Used for |\n|---|---|\n'
    for n in $NAMES; do printf '| %s | something |\n' "$n"; done
    printf 'Closing text.\n'
  } > "$t/docs/assurance/tools.md"
  echo "$t"
}

# run <tree> [args]: output in $tmp/out, status in $rc
run () { local t="$1"; shift; "$MPFS_PYTHON" -I "$TABLE" --root "$t" "$@" > "$tmp/out" 2>&1; rc=$?; }
expect () {   # expect <description> <status> <text in the output>
  if [ $rc -eq "$2" ] && grep -qF -- "$3" "$tmp/out"; then pass "$1"; else fail "$1 (exit $rc, wanted $2 and '$3')"; sed 's/^/    /' "$tmp/out" >&2; fi
}
has () { grep -qF -- "$2" "$1/docs/assurance/tools.md"; }
DOC () { echo "$1/docs/assurance/tools.md"; }

# the table
t="$(tree ok)"
run "$t" --check
expect "a document whose table was never written fails the check" 1 "is out of date"
run "$t"
expect "writing the table succeeds" 0 "wrote the table of docs/assurance/tools.md"
run "$t" --check
expect "the written table passes the check" 0 "tools-doc: ok"
has "$t" '| gprbuild | `26.0.1` | `GPRBUILD_VERSION` |' && pass "an exact version is a row with its pin" || fail "an exact version is a row with its pin"
has "$t" '| QEMU | >= 10.1 | `QEMU_MIN` |' && pass "a minimum version is shown as a floor" || fail "a minimum version is shown as a floor"
has "$t" '| svd2ada | commit `314265ec980ed9498b421279b2a26f9062fb07b8` |' && pass "svd2ada is shown with its full commit" || fail "svd2ada is shown with its full commit"
has "$t" 'x86-64-linux: `09c66bcd8c35`' && has "$t" 'universal-macos: `66fc5fb11ac1`' \
  && pass "the checksums are listed per platform (first 12 digits)" || fail "the checksums are listed per platform (first 12 digits)"
has "$t" '| typing_extensions | `4.16.0` | `tools/requirements.txt` |' && pass "a Python package is a row" || fail "a Python package is a row"
has "$t" 'RENODE_SHA256' && fail "the name of a checksum variable is not copied" || pass "the name of a checksum variable is not copied"
cp "$(DOC "$t")" "$tmp/first.md"; run "$t"
cmp -s "$tmp/first.md" "$(DOC "$t")" && pass "writing twice gives the same file" || fail "writing twice gives the same file"
head -n 2 "$(DOC "$t")" | grep -qx 'Intro text.' && tail -n 1 "$(DOC "$t")" | grep -qx 'Closing text.' \
  && pass "the text outside the markers is not touched" || fail "the text outside the markers is not touched"

# a pin that changes
t="$(tree version)"; run "$t"; run "$t" --check
expect "control: the table of the unchanged pins passes" 0 "tools-doc: ok"
sed -i 's/^GNATPROVE_VERSION=.*/GNATPROVE_VERSION=17.0.0/' "$t/tools/toolchain.env"; run "$t" --check
expect "a changed version in toolchain.env fails the check" 1 "is out of date"
run "$t"; run "$t" --check
expect "writing the table brings it up to date" 0 "tools-doc: ok"
has "$t" '`17.0.0`' && pass "the new version is in the table" || fail "the new version is in the table"

t="$(tree pkg)"; run "$t"
sed -i 's/PyYAML==6.0.3/PyYAML==6.0.4/' "$t/tools/requirements.txt"; run "$t" --check
expect "a changed package version fails the check" 1 "is out of date"
printf 'newpkg==1.0\n' >> "$t/tools/requirements.txt"; run "$t"; run "$t" --check
expect "a package without a row of its own fails the check" 1 "has no row for newpkg"

t="$(tree sha)"; run "$t"
sed -i 's/^RENODE_SHA256_X86_64_LINUX=4ba7/RENODE_SHA256_X86_64_LINUX=0000/' "$t/tools/toolchain.env"; run "$t" --check
expect "a changed checksum fails the check" 1 "is out of date"

t="$(tree edit)"; run "$t"; run "$t" --check
expect "control: the table before the edit passes" 0 "tools-doc: ok"
sed -i 's/| `15.3.1` | `GNAT_NATIVE_VERSION`/| `15.3.2` | `GNAT_NATIVE_VERSION`/' "$(DOC "$t")"; run "$t" --check
expect "an edit inside the table fails the check" 1 "is out of date"

# a tool without a row of its own
t="$(tree norow)"; run "$t"; run "$t" --check
expect "control: every tool has a row" 0 "tools-doc: ok"
sed -i '/^| gprbuild | something |$/d' "$(DOC "$t")"; run "$t" --check
expect "a tool without a row outside the table fails the check" 1 "has no row for gprbuild"
t="$(tree prefix)"; run "$t"; sed -i 's/^| QEMU | something |$/| QEMU-user | something |/' "$(DOC "$t")"; run "$t" --check
expect "a row of another tool with a similar name is not a row" 1 "has no row for QEMU"

# the inputs
t="$(tree nopin)"; sed -i '/^GPRBUILD_VERSION=/d' "$t/tools/toolchain.env"; run "$t" --check
expect "a missing pin is an input error" 2 "GPRBUILD_VERSION is missing or empty"
t="$(tree emptypin)"; sed -i 's/^QEMU_MIN=.*/QEMU_MIN=/' "$t/tools/toolchain.env"; run "$t" --check
expect "an empty pin is an input error" 2 "QEMU_MIN is missing or empty"
t="$(tree nosha)"; sed -i '/^SVDTOOLS_SHA256_/d' "$t/tools/toolchain.env"; run "$t" --check
expect "a download without a checksum is an input error" 2 "no SVDTOOLS_SHA256_* checksum"
t="$(tree badenv)"; printf 'not a pin\n' >> "$t/tools/toolchain.env"; run "$t" --check
expect "a malformed line of toolchain.env is an input error" 2 "not a NAME=VALUE line"
t="$(tree badreq)"; printf 'PyYAML>=6\n' >> "$t/tools/requirements.txt"; run "$t" --check
expect "a package that is not pinned exactly is an input error" 2 "not a pinned requirement"
t="$(tree noenv)"; rm "$t/tools/toolchain.env"; run "$t" --check
expect "a missing toolchain.env is an input error" 2 "cannot read tools/toolchain.env"
t="$(tree noreq)"; rm "$t/tools/requirements.txt"; run "$t" --check
expect "a missing requirements.txt is an input error" 2 "cannot read tools/requirements.txt"
t="$(tree nodoc)"; rm "$(DOC "$t")"; run "$t" --check
expect "a missing document is an input error" 2 "cannot read docs/assurance/tools.md"
t="$(tree nobegin)"; sed -i '/tools-table:begin/d' "$(DOC "$t")"; run "$t" --check
expect "a missing begin marker is an input error" 2 "needs exactly one"
t="$(tree twice)"; printf '<!-- tools-table:end -->\n' >> "$(DOC "$t")"; run "$t" --check
expect "a second end marker is an input error" 2 "needs exactly one"
t="$(tree swapped)"; sed -i -e 's/tools-table:begin/tools-table:TMP/' -e 's/tools-table:end/tools-table:begin/' -e 's/tools-table:TMP/tools-table:end/' "$(DOC "$t")"; run "$t" --check
expect "markers in the wrong order are an input error" 2 "end marker comes before"
t="$(tree nowrite)"; sed -i '/tools-table:begin/d' "$(DOC "$t")"; cp "$(DOC "$t")" "$tmp/before.md"; run "$t"
cmp -s "$tmp/before.md" "$(DOC "$t")" && pass "writing with a bad document changes nothing" || fail "writing with a bad document changes nothing"
t="$(tree ok2)"; run "$t"; run "$t" --check
expect "control: the same tree with intact inputs passes" 0 "tools-doc: ok"
run "$t" --bogus
expect "an unknown option is a usage error" 2 "usage: tools_table.py"

# the repository itself, and the verb
run "$ROOT" --check
expect "the committed table is current and every tool has a row" 0 "tools-doc: ok"
if "$ROOT/x" tools-doc --check > "$tmp/out" 2>&1; then pass "./x tools-doc --check passes on the repository"; else fail "./x tools-doc --check passes on the repository"; cat "$tmp/out" >&2; fi
if "$ROOT/x" tools-doc --bogus > "$tmp/out" 2>&1; then fail "./x tools-doc rejects an unknown option"; else pass "./x tools-doc rejects an unknown option"; fi

[ "$fails" -eq 0 ] && echo "summary: 0 failure(s)" || { echo "summary: $fails failure(s)" >&2; exit 1; }
