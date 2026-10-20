#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Tests for tools/check_docs.py on fixture trees: a good tree passes; a missing file, a
# missing anchor (in another file and in the same file), a reference without a
# definition and a link in a directory that is not skipped fail and are reported with
# file, line and link; links in code blocks, inline code and HTML comments, external
# links and the skipped directories are ignored; a root without Markdown files, a
# missing root and an unknown option fail; the committed documentation passes.
# Exits non-zero on any failure.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CHECK="$ROOT/tools/check_docs.py"
fails=0

pass () { echo "ok:   $1"; }
fail () { echo "FAIL: $1" >&2; fails=$((fails + 1)); }

run () { python3 -I "$CHECK" "$@"; }

expect_rc () {
  local desc="$1" want="$2"; shift 2
  "$@" >/dev/null 2>&1
  local rc=$?
  [ "$rc" = "$want" ] && pass "$desc" || fail "$desc (exit $rc, wanted $want)"
}

# expect_out <description> <fixed string> <command...>: the combined output contains the string
expect_out () {
  local desc="$1" needle="$2"; shift 2
  local out
  out="$("$@" 2>&1)"
  case "$out" in *"$needle"*) pass "$desc" ;; *) fail "$desc (no '$needle' in: $out)" ;; esac
}

expect_no_out () {
  local desc="$1" needle="$2"; shift 2
  local out
  out="$("$@" 2>&1)"
  case "$out" in *"$needle"*) fail "$desc ('$needle' in: $out)" ;; *) pass "$desc" ;; esac
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# A tree in which every kind of link that is checked resolves, and every kind of link
# that must be ignored is broken.
good="$tmp/good"
mkdir -p "$good/docs/sub" "$good/svd" "$good/LICENSES" "$good/libs/pac/generated" "$good/build"
cat > "$good/README.md" <<'MD'
# Project

See [the guide](docs/guide.md), [its section](docs/guide.md#second-part), the
[same-name section](docs/guide.md#install-1), [a directory](docs/sub), the
[top](#project) and [a title](docs/guide.md "The guide"). An image ![logo](docs/logo.svg),
a [link with a parenthesis](docs/a_(b).md), an [escaped space](docs/with%20space.md),
a [root link](/docs/guide.md#setext-heading) and a [reference][guide] and [another] [ref].

[guide]: docs/guide.md
[ref]: <docs/guide.md#html-anchor>
<a href="docs/guide.md">html</a> and [snake case](docs/guide.md#snake_case_name)
and [with punctuation](docs/guide.md#what-is-this-and-why).
[external](https://example.com/nothing) [mail](mailto:a@example.com) [protocol relative](//example.com/x)

```
[in a code block](docs/no-such-file.md)
```

~~~sh
[in a tilde block](docs/no-such-file.md#nothing)
~~~

Inline code `[x](docs/no-such-file.md)` and ``[y](docs/none.md)`` are not links.
<!-- [in a comment](docs/no-such-file.md) -->
MD
cat > "$good/docs/guide.md" <<'MD'
# Guide

## Install

## Install

## Second part

Setext heading
--------------

## What is `this`, and why?

## snake_case_name

<a id="html-anchor"></a>

Back to the [readme](../README.md#project).
MD
printf 'a\n' > "$good/docs/a_(b).md"
printf 'a\n' > "$good/docs/with space.md"
printf '<svg/>\n' > "$good/docs/logo.svg"
printf '# S\n' > "$good/docs/sub/README.md"
# Skipped: the SVD, the licences, generated files and build output.
for d in svd LICENSES libs/pac/generated build; do
  printf '# X\n\n[broken](does-not-exist.md) [broken anchor](../README.md#nothing)\n' > "$good/$d/README.md"
done

expect_rc  "a good tree passes" 0 run "$good"
expect_out "it counts the files" "resolve" run "$good"
expect_no_out "the skipped directories are not read" "svd/README.md" run "$good"

# One broken link at a time, copied from the good tree.
broken () {   # broken <name> <file> <text appended to the file>
  rm -rf "${tmp:?}/$1"; cp -r "$good" "$tmp/$1"
  printf '%s\n' "$3" >> "$tmp/$1/$2"
}
broken file README.md '
A [missing file](docs/missing.md) here.'
expect_rc  "a missing file fails" 1 run "$tmp/file"
expect_out "it names file, line and link" "README.md:26: docs/missing.md (no such file)" run "$tmp/file"

broken anchor README.md '
A [missing anchor](docs/guide.md#no-such-heading) here.'
expect_rc  "a missing anchor fails" 1 run "$tmp/anchor"
expect_out "it names file, line and link of the anchor" "README.md:26: docs/guide.md#no-such-heading (no such anchor)" run "$tmp/anchor"

broken self README.md '
A [missing own anchor](#nothing-here) here.'
expect_rc  "a missing anchor in the same file fails" 1 run "$tmp/self"
expect_out "it is reported" "#nothing-here (no such anchor)" run "$tmp/self"

broken dir docs/sub/README.md '
A [missing directory](../nowhere/) here.'
expect_out "a link in a subdirectory is resolved against that directory" "docs/sub/README.md:3: ../nowhere/ (no such file)" run "$tmp/dir"

broken ref README.md '
A [reference without definition][nowhere] here.'
expect_rc  "a reference without a definition fails" 1 run "$tmp/ref"
expect_out "it is reported" "[nowhere] (reference without a definition)" run "$tmp/ref"

broken root README.md '
A [root link](/docs/missing.md) here.'
expect_out "a link relative to the root is resolved there" "/docs/missing.md (no such file)" run "$tmp/root"

broken multi README.md '
A [link text that
continues](docs/missing.md) here.'
expect_out "a link over two lines is found" "docs/missing.md (no such file)" run "$tmp/multi"

broken html README.md '
<img src="docs/missing.png">'
expect_out "an HTML src is checked" "docs/missing.png (no such file)" run "$tmp/html"

rm -rf "$tmp/two"; cp -r "$good" "$tmp/two"
printf '\n[a](one.md) [b](docs/guide.md#nope)\n' >> "$tmp/two/README.md"
out="$(run "$tmp/two" 2>&1)"
n="$(printf '%s\n' "$out" | grep -c 'README.md:[0-9]*:')"
[ "$n" = 2 ] && pass "every broken link is reported, not only the first" \
  || fail "every broken link is reported, not only the first ($n in: $out)"
expect_out "the summary counts them" "2 broken link(s)" run "$tmp/two"

# A tree whose only broken links are in code: passes (shown above, repeated alone).
mkdir -p "$tmp/code"
printf '# Code\n\n```sh\n[x](nowhere.md)\n```\n\n`[y](nowhere.md#z)`\n' > "$tmp/code/README.md"
expect_rc  "links in code are ignored" 0 run "$tmp/code"
printf '# Code\n\n````\n```\n[x](nowhere.md)\n````\n' > "$tmp/code/README.md"
expect_rc  "a longer fence is not closed by a shorter one" 0 run "$tmp/code"

# Fail closed.
mkdir -p "$tmp/empty/svd"
printf '# S\n' > "$tmp/empty/svd/README.md"
expect_rc  "a root without Markdown files fails" 2 run "$tmp/empty"
expect_rc  "a missing root fails" 2 run "$tmp/none"
expect_rc  "too many arguments fail" 2 run "$good" "$good"
expect_rc  "--help is a usage error" 2 run --help

# The documentation of the repository.
expect_rc  "the committed documentation has no broken link" 0 run "$ROOT"
grep -q 'docs)  *delegate tools/check_docs.py' "$ROOT/x" \
  && pass "./x docs delegates to tools/check_docs.py" || fail "./x docs delegates to tools/check_docs.py"

echo "summary: $fails failure(s)"
[ $fails -eq 0 ]
