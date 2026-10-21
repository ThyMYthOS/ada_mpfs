#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
# Derived from rowsail/ada_esp32s3 x (cmd_analyze) @ d75142d (Apache-2.0); modified for PolarFire SoC.
#
# analyze.sh -- static analysis with adalang_analyzer (a Libadalang-based analyzer),
# measured against baselines. Driven by `./x analyze`.
#
#   usage: tools/analyze.sh [--style] [--update-baseline] [<name>]
#
#   --style             the readability rule set (against <name>.style.baseline)
#                       instead of the defect rule set (against <name>.baseline)
#   --update-baseline   write the baselines from the current findings
#   <name>              analyse one project of analyze.list
#
#   ANALYZE_LIST       the project list (default analyze.list next to this script)
#   ANALYZE_BASELINES  the baseline directory (default analyzer-baselines)
#
# Every finding present when a baseline was written is filtered out, so the run
# reports only what is NEW. The baselines are not a claim that the code is clean:
# they are a "no new findings" tripwire (see analyzer-baselines/README.md).
#
# Rules that close a way this script could pass without analysing anything:
#
#   - adalang_analyzer is the version pinned in tools/toolchain.env
#     (ADALANG_ANALYZER_VERSION). Missing or different is a FAILURE (exit 127 for
#     missing).
#   - A missing or empty list, a malformed row, a project file that does not
#     exist, or a name that is not in the list is a FAILURE.
#   - A project without a baseline FAILS, even if it has no findings: the
#     baseline is what says the project was analysed (`--update-baseline`).
#   - A run whose output is not the analyzer's own (a tool that exits 0 and
#     prints nothing) is not accepted: a clean run says "Baseline matches".
#
# Exit status: 0 no new findings; 1 new findings or a failed project; 2 usage;
# 127 the analyzer is missing.

set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
list="${ANALYZE_LIST:-$here/analyze.list}"
base_dir="${ANALYZE_BASELINES:-$here/analyzer-baselines}"

# Checks the --recommended preset does not enable, added to the default gate.
#
# They are correctness rules, not conformance ones: the first six are the
# copy-paste and logic-error detectors (they normally find nothing at all, which
# is the point: they cost no baseline entries while they stay empty, and a new
# finding is a real signal); the other four are Global_Contract_Mismatch,
# Volatile_Atomic_Consistency, Library_Level_Initialization and
# Missing_Loop_Variant. `--recommended` and `-checks=` compose, so this is
# additive. Exception_Propagation is deliberately not here: it is a restriction,
# not a defect detector, and fires on every call that can transitively raise.
ANALYZE_EXTRA_CHECKS="\
Constant_Condition,Overlapping_Case_Ranges,Duplicate_Boolean_Operand,\
Unreachable_Case_Alternative,Floating_Equality,Non_Short_Circuit_Condition,\
Global_Contract_Mismatch,Volatile_Atomic_Consistency,\
Library_Level_Initialization,Missing_Loop_Variant"

# Style, comprehensibility and complexity: the "is this code readable" view, as
# opposed to "is it correct" (the default gate). Naming_Convention, Magic_Number,
# No_Multiple_Return and Long_Line are left out on purpose: they report one
# house-style disagreement over and over (one-character names, register and
# protocol constants, early returns, generated sources).
ANALYZE_STYLE_CHECKS="\
Cyclomatic_Complexity,Deep_Nesting,Too_Many_Parameters,Generic_Instantiation_Limit,\
Dependency_Limit,Circular_Package_Dependency,Duplicate_Subprogram,Repeated_Statement,\
Shadowed_Declaration,Unnecessary_Else_After_Return,Null_Statement,\
Redundant_If_Boolean_Return,Redundant_Boolean_Comparison,Redundant_Final_Return,\
Redundant_Abs,Redundant_Unary_Minus,Redundant_Type_Conversion,Ineffective_Operation,\
Constant_Result_Operation,Duplicate_With_Clause,Duplicate_Exception_Choice,\
Duplicate_Condition,Same_Operand,Identical_Case_Alternative,Identical_Branches,\
Unreachable_Code,Unused_Variable,Missing_Overriding_Indicator,\
Reraise_Discards_Occurrence,Inefficient_String_Concatenation,Empty_If_Body,\
Empty_Else_Body,No_Goto,No_Label"

usage () { echo "usage: ./x analyze [--style] [--update-baseline] [<name>]" >&2; exit 2; }

update=0; style=0; only=""
for a in "$@"; do
  case "$a" in
    --update-baseline|--update) update=1 ;;
    --style) style=1 ;;
    -*) echo "x analyze: unknown option: $a" >&2; usage ;;
    *) [ -z "$only" ] || usage; only="$a" ;;
  esac
done

if [ "$style" = 1 ]; then
  checks="-checks=$ANALYZE_STYLE_CHECKS"; suffix=".style"; label="style / comprehensibility / complexity"
else
  checks="--recommended -checks=$ANALYZE_EXTRA_CHECKS"; suffix=""; label="defects"
fi

if [ -z "${ANALYZE_NO_ENV:-}" ]; then
  # shellcheck source=tools/mpfs-env.sh
  . "$here/mpfs-env.sh"
  mpfs_toolchain_on_path >/dev/null 2>&1 || true
fi
pin="${ADALANG_ANALYZER_VERSION:-}"
[ -n "$pin" ] || { echo "FAIL: ADALANG_ANALYZER_VERSION is not pinned in tools/toolchain.env" >&2; exit 1; }

if ! command -v adalang_analyzer >/dev/null 2>&1; then
  cat >&2 <<MSG
x analyze: adalang_analyzer is not on PATH.

  It is an Alire community crate, pinned to $pin in tools/toolchain.env:

      ./x toolchain install
MSG
  exit 127
fi
have="$(adalang_analyzer --version 2>&1 | head -n 1)"
case "$have" in
  *"$pin"*) ;;
  *) echo "FAIL: adalang_analyzer is '$have', the pinned version is $pin (./x toolchain install)" >&2; exit 1 ;;
esac

[ -f "$list" ] || { echo "FAIL: project list '$list' does not exist" >&2; exit 1; }
rows="$(awk -F'\t' '
  /^[ \t]*#/ || /^[ \t]*$/ { next }
  !hdr { hdr = 1; if ($1 != "name" || $2 != "project" || $3 != "args" || NF != 3) { print "BADHEADER"; bad = 1 } ; next }
  NF != 3 || $1 == "" || $2 == "" || $3 == "" || $1 !~ /^[A-Za-z0-9_]+$/ { print "BADROW\t" $0; bad = 1; next }
  { print }
  END { exit bad ? 1 : 0 }' "$list")" \
  || { echo "FAIL: $list is malformed: header 'name project args', three TAB-separated fields per row ('-' for no extra arguments), a name of letters, digits and underscores" >&2; exit 1; }
[ -n "$rows" ] || { echo "FAIL: $list lists no project; an empty list would make this pass vacuously" >&2; exit 1; }
if [ -n "$only" ] && ! printf '%s\n' "$rows" | cut -f1 | grep -qx -- "$only"; then
  echo "x analyze: no such project in $list: $only" >&2; exit 2
fi

mkdir -p "$base_dir"
log="$(mktemp -d)"
trap 'rm -rf "$log"' EXIT

if [ "$update" = 1 ]; then
  echo "== static analysis, $label (rewriting baselines) =="
else
  echo "== static analysis, $label (findings not already in the baselines) =="
fi

failures=0; ran=0
while IFS="$(printf '\t')" read -r name project args; do
  [ -z "$only" ] || [ "$only" = "$name" ] || continue
  ran=$((ran + 1))
  case "$project" in /*) gpr="$project" ;; *) gpr="$root/$project" ;; esac
  if [ ! -f "$gpr" ]; then
    printf '  FAIL  %-14s project file %s does not exist\n' "$name" "$project"
    failures=$((failures + 1)); continue
  fi
  [ "$args" = - ] && args=""
  base="$base_dir/$name$suffix.baseline"

  if [ "$update" = 1 ]; then
    # Written next to the old one and moved into place only if the analyzer wrote it: a
    # stale baseline must not stand in for one that was not written.
    rm -f "$base.new"
    # shellcheck disable=SC2086
    adalang_analyzer -P"$gpr" $args $checks --write-baseline="$base.new" > "$log/out" 2>&1 || true
    if [ -f "$base.new" ]; then
      mv "$base.new" "$base"
      printf '  ok    %-14s baseline: %s finding(s)\n' "$name" "$({ grep -cv '^#' "$base" 2>/dev/null || true; })"
    else
      printf '  FAIL  %-14s the analyzer wrote no baseline:\n' "$name"
      tail -n 5 "$log/out" | sed 's/^/        | /'
      failures=$((failures + 1))
    fi
    continue
  fi

  if [ ! -f "$base" ]; then
    printf '  FAIL  %-14s no baseline %s; run ./x analyze%s --update-baseline %s\n' \
      "$name" "${base#"$root"/}" "$([ "$style" = 1 ] && echo ' --style')" "$name"
    failures=$((failures + 1)); continue
  fi
  # shellcheck disable=SC2086
  adalang_analyzer -P"$gpr" $args $checks --baseline="$base" > "$log/out" 2>&1 && rc=0 || rc=$?
  if [ "$rc" = 0 ] && grep -q 'Baseline matches:' "$log/out"; then
    printf '  ok    %-14s %s\n' "$name" "$(grep -m1 'Baseline matches:' "$log/out")"
  elif [ "$rc" = 0 ]; then
    printf '  FAIL  %-14s exit 0 without a "Baseline matches:" line: the analyzer did not run as expected\n' "$name"
    tail -n 5 "$log/out" | sed 's/^/        | /'
    failures=$((failures + 1))
  else
    printf '  NEW   %-14s exit %s\n' "$name" "$rc"
    # The findings themselves, not the trailing summary block.
    { grep -E '^/.*: (warning|error):' "$log/out" || tail -n 5 "$log/out"; } \
      | sed 's|^'"$root"'/||;s|^|        |' | head -n 40
    failures=$((failures + 1))
  fi
done <<EOF2
$rows
EOF2

[ $ran -gt 0 ] || { echo "x analyze: nothing was analysed" >&2; exit 2; }
echo
if [ "$update" = 1 ]; then
  [ $failures -eq 0 ] || { printf 'analyze FAILED: %d of %d project(s) have no baseline\n' "$failures" "$ran" >&2; exit 1; }
  printf 'analyze: %d baseline(s) written\n' "$ran"
  exit 0
fi
if [ $failures -ne 0 ]; then
  printf 'analyze FAILED: %d of %d project(s) have new findings or no baseline\n' "$failures" "$ran" >&2
  echo "      Triage new findings; if they are noise, re-baseline with --update-baseline." >&2
  exit 1
fi
printf 'analyze OK: %d project(s), no new findings\n' "$ran"
