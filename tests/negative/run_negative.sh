#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# run_negative.sh -- cases that must fail, and the control cases that must not.
# Driven by `./x test negative`.
#
# Each case of cases.list links objects of examples/bare_hello built for two hart
# classes with the linker script of examples/common/ld. The E51 objects are
# lp64 (soft-float ABI), the U54 objects lp64d (double-float ABI), and ld must
# refuse to mix them. A case that is expected to fail passes only if the link
# fails, AND the linker says what the case names (a link that fails for another
# reason, such as a missing object, is not the failure under test), AND no image
# was written. The control cases show that the same objects link when the ABIs
# agree, so a negative cannot pass because the setup is broken.
#
#   CASES     the case list (default cases.list next to this script)
#   BARE_CC   the compiler driver (default riscv64-elf-gcc)
#   OBJROOT   directory that holds bare_hello/obj-<hart>/ (default examples/)

set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
cases="${CASES:-$here/cases.list}"
objroot="${OBJROOT:-$root/examples}"
export BARE_CC="${BARE_CC:-riscv64-elf-gcc}"

fail () { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# shellcheck source=examples/common/bare_build.sh
. "$root/examples/common/bare_build.sh"
command -v "$BARE_CC" >/dev/null 2>&1 || fail "$BARE_CC not found (./x toolchain install, or use ./x test negative). Nothing was linked."
[ -f "$cases" ] || fail "case list '$cases' does not exist"

rows="$(awk -F'\t' '
  /^[ \t]*#/ || /^[ \t]*$/ { next }
  !hdr { hdr = 1; if ($1 != "name") { print "BADHEADER"; bad = 1 } ; next }
  NF != 5 || $1 == "" || $2 == "" || $3 == "" || $4 == "" || $5 == "" || ($4 != "links" && $4 != "fails") ||
  ($4 == "fails" && $5 == "-") { print "BADROW\t" $0; bad = 1; next }
  { print }
  END { exit bad ? 1 : 0 }' "$cases")" || fail "$cases is malformed: header 'name start rest expect pattern', five TAB-separated fields, expect links|fails, a pattern for every fails"
[ -n "$rows" ] || fail "$cases contains no cases; an empty list would make this test pass vacuously"
printf '%s\n' "$rows" | cut -f4 | grep -q '^fails$' || fail "$cases has no case that must fail"
printf '%s\n' "$rows" | cut -f4 | grep -q '^links$' || fail "$cases has no control case that must link"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
bad=0; n=0
while IFS="$(printf '\t')" read -r name start rest expect pattern; do
  n=$((n + 1))
  objs=()
  for spec in "$start:start" "$rest:bare_console" "$rest:bare_hello"; do
    o="$objroot/bare_hello/obj-${spec%%:*}/${spec#*:}.o"
    [ -f "$o" ] || { printf 'FAIL %s: %s is missing (build the images: ./x test negative does)\n' "$name" "$o" >&2; bad=1; continue 2; }
    objs+=("$o")
  done
  out="$tmp/$name"
  log="$(bare_link 1 "$out" "${objs[@]}" 2>&1)"; rc=$?
  case "$expect" in
    links)
      if [ $rc -eq 0 ] && [ -f "$out.elf" ]; then printf 'ok:   %s links\n' "$name"
      else printf 'FAIL %s: the link failed (exit %s)\n%s\n' "$name" "$rc" "$log" >&2; bad=1; fi ;;
    fails)
      if [ $rc -eq 0 ]; then
        printf 'FAIL %s: the link succeeded, it must fail\n' "$name" >&2; bad=1
      elif [ -f "$out.elf" ]; then
        printf 'FAIL %s: the link failed but left an image\n' "$name" >&2; bad=1
      elif ! printf '%s' "$log" | grep -qF -- "$pattern"; then
        printf 'FAIL %s: the link failed, but not with "%s":\n%s\n' "$name" "$pattern" "$log" >&2; bad=1
      else printf 'ok:   %s fails to link ("%s")\n' "$name" "$pattern"; fi ;;
  esac
done <<EOF
$rows
EOF

if [ $bad -ne 0 ]; then
  echo "negative FAILED" >&2
  exit 1
fi
printf 'negative OK: %d case(s)\n' "$n"
