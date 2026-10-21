#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
# Derived from rowsail/ada_esp32s3 book/prove/prove.sh @ d75142d (Apache-2.0); modified for PolarFire SoC.
#
# prove.sh -- formally prove, with SPARK / GNATprove, the projects of prove.list.
# Driven by `./x prove`.
#
#   usage: tools/prove.sh [filter ...]    (default: every project; a filter is a
#                                          substring of the project file or label)
#
#   PROVE_LIST   the project list (default prove.list next to this script)
#
# The projects are native (no cross target, no runtime): units of pure logic whose
# run-time-error freedom does not depend on the target. A unit joins the proof
# surface by carrying `with SPARK_Mode => On`; GNATprove then analyses that subset.
#
# Every rule below closes a way this script could pass without proving anything:
#
#   - gnatprove is the version pinned in tools/toolchain.env (GNATPROVE_VERSION),
#     not "whatever is first on PATH". A missing or different one is a FAILURE.
#   - A missing or empty list, a malformed row or a missing project is a FAILURE:
#     zero projects must not mean zero failures.
#   - gnatprove's exit status is not enough (it is 0 with unproved checks). The
#     authority is the Unproved column of the Total row of its summary: anything
#     but "." fails. A run without a summary fails. Any message graded low,
#     medium or high, or an error, fails too.
#   - Default switches are --level=1 --prover=z3 --timeout=10; a project that
#     needs more says so in its row.

set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
list="${PROVE_LIST:-$here/prove.list}"
default_switches="--level=1 --prover=z3 --timeout=10"

fail () { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# The pinned toolchain on PATH. PROVE_NO_ENV leaves PATH alone (the tests of this
# script put a stand-in for gnatprove on it) and takes the pin from the environment.
if [ -z "${PROVE_NO_ENV:-}" ]; then
  # shellcheck source=tools/mpfs-env.sh
  . "$here/mpfs-env.sh"
  mpfs_toolchain_on_path >/dev/null 2>&1 || true
fi
pin="${GNATPROVE_VERSION:-}"
[ -n "$pin" ] || fail "GNATPROVE_VERSION is not pinned in tools/toolchain.env"

command -v gnatprove >/dev/null 2>&1 \
  || fail "gnatprove not found. Install the pinned version $pin: ./x toolchain install"
have="$(gnatprove --version 2>&1 | head -n 1)"
case "$have" in
  *"$pin"*) ;;
  *) fail "gnatprove is '$have', the pinned version is $pin (./x toolchain install)" ;;
esac
printf 'gnatprove %s\n' "$have"

[ -f "$list" ] || fail "project list '$list' does not exist"
rows="$(awk -F'\t' '
  /^[ \t]*#/ || /^[ \t]*$/ { next }
  !hdr { hdr = 1; if ($1 != "project" || $2 != "label" || $3 != "switches" || NF != 3) { print "BADHEADER"; bad = 1 } ; next }
  NF != 3 || $1 == "" || $2 == "" || $3 == "" { print "BADROW\t" $0; bad = 1; next }
  { print }
  END { exit bad ? 1 : 0 }' "$list")" \
  || fail "$list is malformed: header 'project label switches', three TAB-separated fields per row ('-' for the default switches)"
[ -n "$rows" ] || fail "$list lists no project; an empty list would make this pass vacuously"

filters=("$@")
failed=0; proved=0; ran=0
while IFS="$(printf '\t')" read -r project label switches; do
  if [ ${#filters[@]} -gt 0 ]; then
    match=0
    for f in "${filters[@]}"; do case "$project $label" in *"$f"*) match=1 ;; esac; done
    [ $match -eq 1 ] || continue
  fi
  ran=$((ran + 1))
  echo "=== prove: $label ($project) ==="
  case "$project" in /*) gpr="$project" ;; *) gpr="$root/$project" ;; esac
  if [ ! -f "$gpr" ]; then
    echo "  FAIL: project file $project does not exist"
    failed=$((failed + 1)); continue
  fi
  [ "$switches" = - ] && switches="$default_switches"
  # shellcheck disable=SC2086
  out="$(gnatprove -P "$gpr" $switches -j0 --report=fail --output=oneline 2>&1)"; rc=$?
  bad=0
  # Show what failed. GNATprove grades a check message low:, medium: or high:.
  if printf '%s\n' "$out" | grep -qiE "low:|medium:|high:|: *error:"; then
    printf '%s\n' "$out" | grep -iE "low:|medium:|high:|: *error:" | sed 's/^/  /'
    bad=1
  fi
  if [ $rc -ne 0 ]; then
    echo "  gnatprove exited with status $rc"
    printf '%s\n' "$out" | tail -n 5 | sed 's/^/  | /'
    bad=1
  fi
  # The report path comes from gnatprove itself ("Summary logged in ..."), not from a
  # glob of the project directory.
  report="$(printf '%s\n' "$out" | sed -n 's/^Summary logged in //p' | tail -n 1)"
  if [ -n "$report" ] && [ -f "$report" ]; then
    sed -n '/SPARK Analysis results/,/^Total/p' "$report" \
      | grep -iE "Run-time Checks|Assertions|Functional Contracts|^Total" | sed 's/^/  /'
    # The Total row's last column is the number of unproved checks ("1 (25%)"), or "."
    # for none. Columns are separated by runs of blanks, so the last one is what
    # follows the last run of two or more.
    unproved="$(sed -n '/SPARK Analysis results/,/^Total/p' "$report" | awk '/^Total/ { n = split($0, c, /  +/); print c[n] }' | tail -n 1)"
    case "$unproved" in
      "") echo "  FAIL: no Total row in the summary"; bad=1 ;;
      ".") echo "  no unproved checks" ;;
      *) echo "  FAIL: unproved checks reported: $unproved"; bad=1 ;;
    esac
  else
    echo "  FAIL: no summary report found"
    bad=1
  fi
  if [ $bad -eq 0 ]; then proved=$((proved + 1)); else failed=$((failed + 1)); fi
  echo
done <<EOF2
$rows
EOF2

[ $ran -gt 0 ] || fail "no project matched ${filters[*]:-the list}; nothing was proved"
if [ $failed -ne 0 ]; then
  printf 'prove FAILED: %d of %d project(s) are not proved\n' "$failed" "$ran" >&2
  exit 1
fi
printf 'prove OK: %d project(s), no unproved checks\n' "$proved"
