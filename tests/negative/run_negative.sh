#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# run_negative.sh -- cases that must fail, and the control cases that must not.
# Driven by `./x test negative`.
#
# Two kinds of case (see cases.list):
#
#   link   Objects of examples/bare_hello built for two hart classes are linked
#          with the linker script of examples/common/ld. The E51 objects are lp64
#          (soft-float ABI), the U54 objects lp64d (double-float ABI), and ld must
#          refuse to mix them.
#   build  examples/bare_hello is compiled with gprbuild in a fresh copy of the
#          tree (so no object of an earlier case can mask a check). The scenario
#          variables of the case are passed as -X options, and a fixture
#          directory of tests/negative/fixtures replaces files of src/: a bad
#          value of MPFS_HART, a constant that nothing reads (the project
#          compiles with warnings as errors), a unit that needs elaboration code
#          (the image has no binder).
#
# A case that is expected to fail passes only if the link or the build fails, AND
# the output says what the case names (a failure for another reason, such as a
# missing object, is not the failure under test), AND, for a link, no image was
# written. The control cases show that the same objects and sources work without
# the fault (a link writes the image, a build leaves the object of the main), so
# a negative cannot pass because the setup is broken.
#
#   CASES      the case list (default cases.list next to this script)
#   FIXTURES   the fixture directories (default fixtures next to this script)
#   BARE_CC    the compiler driver for link cases (default riscv64-elf-gcc)
#   GPRBUILD   gprbuild for build cases (default gprbuild)
#   OBJROOT    directory that holds bare_hello/obj-<hart>/ (default examples/)
#   SRCROOT    the examples directory copied for build cases (default examples/)

set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
cases="${CASES:-$here/cases.list}"
fixtures="${FIXTURES:-$here/fixtures}"
objroot="${OBJROOT:-$root/examples}"
srcroot="${SRCROOT:-$root/examples}"
gprbuild_cmd="${GPRBUILD:-gprbuild}"
export BARE_CC="${BARE_CC:-riscv64-elf-gcc}"

fail () { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# shellcheck source=examples/common/bare_build.sh
. "$root/examples/common/bare_build.sh"
[ -f "$cases" ] || fail "case list '$cases' does not exist"

rows="$(awk -F'\t' '
  /^[ \t]*#/ || /^[ \t]*$/ { next }
  !hdr { hdr = 1; if ($1 != "name" || $2 != "kind" || $3 != "arg" || $4 != "expect" || $5 != "pattern" || NF != 5) { print "BADHEADER"; bad = 1 } ; next }
  NF != 5 || $1 == "" || $2 == "" || $3 == "" || $4 == "" || $5 == "" || ($2 != "link" && $2 != "build") ||
  ($2 == "link" && $3 !~ /^(e51|u54):(e51|u54)$/) ||
  ($4 != "links" && $4 != "builds" && $4 != "fails") ||
  ($2 == "link" && $4 == "builds") || ($2 == "build" && $4 == "links") ||
  ($4 == "fails" && $5 == "-") { print "BADROW\t" $0; bad = 1; next }
  { print }
  END { exit bad ? 1 : 0 }' "$cases")" || fail "$cases is malformed: header 'name kind arg expect pattern', five TAB-separated fields, kind link|build, a link arg <e51|u54>:<e51|u54>, expect links (link) | builds (build) | fails, a pattern for every fails"
[ -n "$rows" ] || fail "$cases contains no cases; an empty list would make this test pass vacuously"
for k in link build; do
  printf '%s\n' "$rows" | awk -F'\t' -v k="$k" '$2 == k && $4 == "fails" { f = 1 } END { exit f ? 0 : 1 }' \
    || fail "$cases has no $k case that must fail"
  printf '%s\n' "$rows" | awk -F'\t' -v k="$k" '$2 == k && $4 != "fails" { f = 1 } END { exit f ? 0 : 1 }' \
    || fail "$cases has no $k control case that must succeed"
done
# The tools are needed by the kinds that are listed, which they always are (above).
command -v "$BARE_CC" >/dev/null 2>&1 || fail "$BARE_CC not found (./x toolchain install, or use ./x test negative). Nothing was linked."
command -v "$gprbuild_cmd" >/dev/null 2>&1 || fail "$gprbuild_cmd not found (./x toolchain install, or use ./x test negative). Nothing was built."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
bad=0; n=0

# verdict <name> <expect> <pattern> <rc> <log> <produced: 0|1> <what is produced>
verdict () {
  local name="$1" expect="$2" pattern="$3" rc="$4" log="$5" produced="$6" what="$7"
  case "$expect" in
    links|builds)
      if [ "$rc" -eq 0 ] && [ "$produced" -eq 1 ]; then printf 'ok:   %s %s\n' "$name" "$expect"
      else printf 'FAIL %s: it did not succeed (exit %s, %s %s)\n%s\n' "$name" "$rc" "$what" "$([ "$produced" -eq 1 ] && echo written || echo missing)" "$log" >&2; bad=1; fi ;;
    fails)
      if [ "$rc" -eq 0 ]; then
        printf 'FAIL %s: it succeeded, it must fail\n' "$name" >&2; bad=1
      elif [ "$produced" -eq 1 ]; then
        printf 'FAIL %s: it failed but left %s\n' "$name" "$what" >&2; bad=1
      elif ! printf '%s' "$log" | grep -qF -- "$pattern"; then
        printf 'FAIL %s: it failed, but not with "%s":\n%s\n' "$name" "$pattern" "$log" >&2; bad=1
      else printf 'ok:   %s fails ("%s")\n' "$name" "$pattern"; fi ;;
  esac
}

run_link () {   # name arg expect pattern
  local name="$1" arg="$2" expect="$3" pattern="$4" start rest o spec objs=() out log rc produced=0
  start="${arg%%:*}"; rest="${arg#*:}"
  for spec in "$start:start" "$rest:bare_console" "$rest:bare_hello"; do
    o="$objroot/bare_hello/obj-${spec%%:*}/${spec#*:}.o"
    [ -f "$o" ] || { printf 'FAIL %s: %s is missing (build the images: ./x test negative does)\n' "$name" "$o" >&2; bad=1; return; }
    objs+=("$o")
  done
  out="$tmp/$name"
  log="$(bare_link 1 "$out" "${objs[@]}" 2>&1)"; rc=$?
  [ -f "$out.elf" ] && produced=1
  verdict "$name" "$expect" "$pattern" "$rc" "$log" "$produced" "an image"
}

run_build () {   # name arg expect pattern
  local name="$1" arg="$2" expect="$3" pattern="$4" dir tok hart="" fixture="" xs=() log rc produced=0 o
  for tok in $arg; do
    case "$tok" in
      fixture=*) fixture="${tok#fixture=}" ;;
      *=*) xs+=("-X$tok"); [ "${tok%%=*}" = MPFS_HART ] && hart="${tok#MPFS_HART=}" ;;
      *) printf 'FAIL %s: bad argument "%s"\n' "$name" "$tok" >&2; bad=1; return ;;
    esac
  done
  dir="$tmp/$name"
  mkdir -p "$dir"
  cp -R "$srcroot/bare_hello" "$srcroot/common" "$dir/" || { printf 'FAIL %s: cannot copy %s\n' "$name" "$srcroot" >&2; bad=1; return; }
  find "$dir" \( -name 'obj-*' -o -name 'bin-*' \) -prune -exec rm -r {} +
  if [ -n "$fixture" ]; then
    [ -d "$fixtures/$fixture" ] || { printf 'FAIL %s: fixture %s not found\n' "$name" "$fixtures/$fixture" >&2; bad=1; return; }
    cp -R "$fixtures/$fixture/." "$dir/bare_hello/src/" || { bad=1; return; }
  fi
  log="$(cd "$dir/bare_hello" && "$gprbuild_cmd" -c -p -P app.gpr "${xs[@]}" 2>&1)"; rc=$?
  # Only a build that must succeed has to leave the object of the main; gprbuild
  # keeps the objects of the units that compiled before another one failed.
  if [ "$expect" = builds ]; then
    for o in "$dir"/bare_hello/obj-*/bare_hello.o; do [ -f "$o" ] && produced=1; done
  fi
  verdict "$name" "$expect" "$pattern" "$rc" "$log" "$produced" "the object of the main"
}

while IFS="$(printf '\t')" read -r name kind arg expect pattern; do
  n=$((n + 1))
  case "$kind" in
    link)  run_link "$name" "$arg" "$expect" "$pattern" ;;
    build) run_build "$name" "$arg" "$expect" "$pattern" ;;
  esac
done <<EOF
$rows
EOF

if [ $bad -ne 0 ]; then
  echo "negative FAILED" >&2
  exit 1
fi
printf 'negative OK: %d case(s)\n' "$n"
