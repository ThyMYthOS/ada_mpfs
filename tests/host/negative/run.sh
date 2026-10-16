#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Tests for tests/negative/run_negative.sh with stand-ins for the compiler driver
# (link cases) and for gprbuild (build cases), and properties of the committed
# cases.list and fixtures. Each negative case must make the runner exit
# non-zero, for the reason it names, and the positive cases show that the
# stand-ins are not what makes it fail. Exits non-zero on any failure.
# @verifies BLD-002

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

# expect_out <description> <fixed string> <command...>: the combined output contains the string
expect_out () {
  local desc="$1" needle="$2"; shift 2
  local out
  out="$("$@" 2>&1)"
  case "$out" in *"$needle"*) pass "$desc" ;; *) fail "$desc (no '$needle' in: $out)" ;; esac
}

tmp="$(mktemp -d)"
trap 'rm -r "$tmp"' EXIT
tab="$(printf '\t')"

# The objects are empty files; "mixed" means objects from obj-e51 and obj-u54.
mkdir -p "$tmp/n/obj/bare_hello/obj-e51" "$tmp/n/obj/bare_hello/obj-u54"
for h in e51 u54; do
  for o in start bare_console bare_hello; do : > "$tmp/n/obj/bare_hello/obj-$h/$o.o"; done
done

# FAKE_CC_MODE: abi = what a real ld does (refuse mixed ABIs); accept = link
# anything, as a broken setup would; other = always fail for another reason;
# leave = refuse mixed ABIs but leave an image behind.
cat > "$tmp/n/cc" <<'EOF2'
#!/bin/bash
out=""; mixed=0; e=0; u=0
while [ $# -gt 0 ]; do
  case "$1" in -o) out="$2"; shift ;; *obj-e51/*) e=1 ;; *obj-u54/*) u=1 ;; esac
  shift
done
[ $e = 1 ] && [ $u = 1 ] && mixed=1
case "${FAKE_CC_MODE:-abi}" in
  accept) : > "$out" ;;
  other)  echo "ld: cannot find something else" >&2; exit 1 ;;
  leave)  : > "$out"; [ $mixed = 1 ] && { echo "ld: x.o: can't link double-float modules with soft-float modules" >&2; exit 1; } ;;
  *)      if [ $mixed = 1 ]; then echo "ld: x.o: can't link double-float modules with soft-float modules" >&2; exit 1; fi; : > "$out" ;;
esac
EOF2
chmod +x "$tmp/n/cc"

# FAKE_GPR_MODE: real = what gprbuild and GNAT do with the project and the
# fixtures (a bad value of a typed variable, an unreferenced constant under
# -gnatwe, a unit that needs elaboration code); accept = build anything;
# other = always fail for another reason; nocopy = succeed without an object.
cat > "$tmp/n/gprbuild" <<'EOF2'
#!/bin/bash
hart=""
for a in "$@"; do case "$a" in -XMPFS_HART=*) hart="${a#-XMPFS_HART=}" ;; esac; done
mode="${FAKE_GPR_MODE:-real}"
[ -f app.gpr ] || { echo "gprbuild: project file \"app.gpr\" not found in ." >&2; exit 4; }
if [ "$mode" = other ]; then echo "gprbuild: something else went wrong" >&2; exit 4; fi
if [ "$mode" = real ]; then
  case "$hart" in
    e51|u54) ;;
    *) echo "app.gpr:13:04: value \"$hart\" is illegal for typed string \"hart\"" >&2
       echo "gprbuild: \"app.gpr\" processing failed" >&2; exit 4 ;;
  esac
  if grep -q 'Left_Over' src/bare_hello.adb; then
    echo "bare_hello.adb:7:04: warning: constant \"Left_Over\" is not referenced [-gnatwu]" >&2
    echo "gprbuild: *** compilation phase failed" >&2; exit 4
  fi
  if [ -f src/early.ads ]; then
    echo "early.ads:6:04: error: violation of restriction \"No_Elaboration_Code\" at line 1" >&2
    echo "gprbuild: *** compilation phase failed" >&2; exit 4
  fi
fi
h="${hart:-e51}"
[ "$mode" = nocopy ] || { mkdir -p "obj-$h"; : > "obj-$h/bare_hello.o"; }
exit 0
EOF2
chmod +x "$tmp/n/gprbuild"

negative () {   # negative [env...]
  env BARE_CC="$tmp/n/cc" GPRBUILD="$tmp/n/gprbuild" OBJROOT="$tmp/n/obj" "$@" bash "$ROOT/tests/negative/run_negative.sh"
}
expect_rc  "negative: the committed cases pass against a linker that refuses mixed ABIs and a gprbuild that rejects the faults" 0 negative
expect_out "negative: counts the cases" "negative OK: 9 case(s)" negative

# link cases
expect_rc  "negative: fails when the mixed-ABI link unexpectedly succeeds" nonzero negative FAKE_CC_MODE=accept
expect_out "negative: says it succeeded" "it succeeded, it must fail" negative FAKE_CC_MODE=accept
expect_rc  "negative: fails when every link fails for another reason" nonzero negative FAKE_CC_MODE=other
expect_out "negative: a failure for another reason is not the failure under test" "but not with" negative FAKE_CC_MODE=other
expect_out "negative: the control case reports a failed link" "control_e51: it did not succeed" negative FAKE_CC_MODE=other
expect_rc  "negative: fails when a failed link leaves an image" nonzero negative FAKE_CC_MODE=leave
rm "$tmp/n/obj/bare_hello/obj-u54/start.o"
expect_rc  "negative: fails when an object is missing" nonzero negative
: > "$tmp/n/obj/bare_hello/obj-u54/start.o"
expect_rc  "negative: fails without the compiler driver" nonzero negative BARE_CC="$tmp/n/none"

# build cases
expect_rc  "negative: fails when gprbuild accepts the faults" nonzero negative FAKE_GPR_MODE=accept
expect_out "negative: names the build case that succeeded" "FAIL bad_hart_value: it succeeded, it must fail" negative FAKE_GPR_MODE=accept
expect_out "negative: the fixture case succeeded, too" "FAIL elaboration_code: it succeeded, it must fail" negative FAKE_GPR_MODE=accept
expect_rc  "negative: fails when every build fails for another reason" nonzero negative FAKE_GPR_MODE=other
expect_out "negative: the build control reports its failure" "control_build_e51: it did not succeed" negative FAKE_GPR_MODE=other
expect_rc  "negative: a control build without the object of the main fails" nonzero negative FAKE_GPR_MODE=nocopy
expect_rc  "negative: fails without gprbuild" nonzero negative GPRBUILD="$tmp/n/none"

# a fixture that is missing
cp -R "$ROOT/tests/negative/fixtures" "$tmp/n/fx"
rm -r "$tmp/n/fx/elaboration_code"
expect_rc  "negative: a missing fixture fails" nonzero negative FIXTURES="$tmp/n/fx"
expect_out "negative: names the missing fixture" "fixture" negative FIXTURES="$tmp/n/fx"
# a fixture that does not do what its case says: the unreferenced constant is gone
cp -R "$ROOT/tests/negative/fixtures" "$tmp/n/fx2"
sed -i 's/Left_Over/Used/; s/Put_Line ("bare hello")/Put_Dec (Used)/' "$tmp/n/fx2/unreferenced_constant/bare_hello.adb"
expect_rc  "negative: a fixture that no longer has the fault fails the case" nonzero negative FIXTURES="$tmp/n/fx2"

# the list
hdr="name${tab}kind${tab}arg${tab}expect${tab}pattern"
printf '%s\n' "$hdr" > "$tmp/n/empty.list"
expect_rc  "negative: an empty case list fails" nonzero negative CASES="$tmp/n/empty.list"
printf '%s\n%s\n%s\n' "$hdr" "c${tab}link${tab}e51:e51${tab}links${tab}-" "c2${tab}build${tab}MPFS_HART=e51${tab}builds${tab}-" > "$tmp/n/nonegative.list"
expect_rc  "negative: a list without a negative case fails" nonzero negative CASES="$tmp/n/nonegative.list"
printf '%s\n%s\n%s\n' "$hdr" "x${tab}link${tab}e51:u54${tab}fails${tab}float modules with" "y${tab}build${tab}MPFS_HART=r5${tab}fails${tab}illegal" > "$tmp/n/nocontrol.list"
expect_rc  "negative: a list without a control case fails" nonzero negative CASES="$tmp/n/nocontrol.list"
printf '%s\n%s\n' "$hdr" "x${tab}link${tab}e51:u54${tab}fails${tab}-" > "$tmp/n/nopattern.list"
expect_rc  "negative: a fails case without a pattern is malformed" nonzero negative CASES="$tmp/n/nopattern.list"
printf '%s\n%s\n' "$hdr" "x${tab}run${tab}e51${tab}links${tab}-" > "$tmp/n/badkind.list"
expect_rc  "negative: an unknown kind is malformed" nonzero negative CASES="$tmp/n/badkind.list"
printf 'name\tstart\trest\texpect\tpattern\n' > "$tmp/n/oldhdr.list"
expect_rc  "negative: a wrong header is malformed" nonzero negative CASES="$tmp/n/oldhdr.list"
expect_rc  "negative: a missing list fails" nonzero negative CASES="$tmp/n/none.list"

# The committed list: a control and a negative case of each kind, both ABI
# directions, and the fixtures its build cases name.
nl="$ROOT/tests/negative/cases.list"
for kind in link build; do
  grep -q "${tab}${kind}${tab}.*${tab}fails${tab}" "$nl" && grep -Eq "${tab}${kind}${tab}.*${tab}(links|builds)${tab}" "$nl" \
    && pass "cases.list: $kind has a control case and a negative case" \
    || fail "cases.list: $kind has a control case and a negative case"
done
for d in e51:u54 u54:e51; do
  grep -q "${tab}link${tab}$d${tab}fails${tab}" "$nl" && pass "cases.list: ABI mismatch $d" || fail "cases.list: ABI mismatch $d"
done
for f in $(grep -o 'fixture=[a-z_]*' "$nl" | sed 's/fixture=//'); do
  [ -d "$ROOT/tests/negative/fixtures/$f" ] && pass "cases.list: fixture $f exists" || fail "cases.list: fixture $f exists"
done

echo "summary: $fails failure(s)"
[ $fails -eq 0 ]
