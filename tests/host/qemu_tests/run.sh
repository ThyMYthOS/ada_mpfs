#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Tests for tests/qemu/run_tests.sh (the Test_Report runner) with a stand-in for
# QEMU, and properties of the committed tests.list. The stand-in "boots" an image
# that is a text file: its lines write to a serial port or to QEMU's trace, so
# every way a test can pass or fail is reproduced without QEMU. Each negative
# case must make the runner exit non-zero, and the positive cases show that the
# fixtures are not what makes them fail. Exits non-zero on any failure.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
RUNNER="$ROOT/tests/qemu/run_tests.sh"
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

# The stand-in. The image lines are "S<TAB>n<TAB>text" (text and CR LF to serial
# port n), "T<TAB>text" (a line in the trace written with -D) and "HANG" (stay
# alive until killed, like a guest that never reaches a verdict).
mkdir -p "$tmp/q"
cat > "$tmp/q/qemu" <<'EOF'
#!/bin/sh
case "$1" in
  --version) echo "QEMU emulator version ${QEMU_FAKE_VERSION:-10.2.1}"; exit 0 ;;
  -M) [ "$2" = help ] && { echo "microchip-icicle-kit  Microchip PolarFire SoC Icicle Kit"; exit 0; } ;;
esac
n=0; kernel=""; log=""
while [ $# -gt 0 ]; do
  case "$1" in
    -serial)
      case "$2" in
        file:*) eval "ser$n=\${2#file:}" ;;
        chardev:*) eval "ser$n=\$con0" ;;
      esac
      n=$((n + 1)); shift 2 ;;
    -chardev) con0=$(printf '%s' "$2" | sed -n 's/.*path=\([^,]*\).*/\1/p'); shift 2 ;;
    -kernel) kernel="$2"; shift 2 ;;
    -D) log="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -f "$kernel" ] || exit 1
tab=$(printf '\t')
while IFS= read -r line; do
  case "$line" in
    S"$tab"*) rest=${line#S"$tab"}; port=${rest%%"$tab"*}; text=${rest#*"$tab"}
              eval "f=\$ser$port"; printf '%s\r\n' "$text" >> "$f" ;;
    T"$tab"*) [ -n "$log" ] && printf '%s\n' "${line#T"$tab"}" >> "$log" ;;
    HANG) sleep 60 ;;
  esac
done < "$kernel"
EOF
chmod +x "$tmp/q/qemu"

# image <dir> <name>: an image file under <dir>/bin/<name>.elf; the lines come from stdin
image () { mkdir -p "$1/bin"; cat > "$1/bin/$2.elf"; }
# list <file> <row>...: a tests.list with the header and the given TAB-separated rows
list () {
  local f="$1"; shift
  { printf '# fixture\nname\tdir\tserial\texpect\tobserve\twhy\n'; for r in "$@"; do printf '%s\n' "$r"; done; } > "$f"
}
run () {   # run <list> [env...] -- [names...]
  local l="$1"; shift
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  env QEMU="$tmp/q/qemu" TEST_LIST="$l" TEST_TIMEOUT=3 "${envs[@]}" bash "$RUNNER" "$@"
}

S="S${tab}0${tab}"
good="$tmp/t/good"
image "$good" good <<EOF
${S}TEST good: START
${S}  ok: a thing
${S}TEST good: PASS
EOF
list "$tmp/ok.list" "good${tab}$good${tab}0${tab}pass${tab}-${tab}-"
expect_rc  "runner: a test that prints START, ok and PASS passes" 0 run "$tmp/ok.list"
expect_out "runner: says tests OK" "tests OK: 1 passed" run "$tmp/ok.list"

failing="$tmp/t/failing"
image "$failing" failing <<EOF
${S}TEST failing: START
${S}  FAIL: the thing
${S}TEST failing: FAIL
EOF
list "$tmp/fail.list" "failing${tab}$failing${tab}0${tab}pass${tab}-${tab}-"
expect_rc  "runner: a test that reports FAIL fails" nonzero run "$tmp/fail.list"
expect_out "runner: names the reason" "the test reported failing checks" run "$tmp/fail.list"

# a FAIL: line with a PASS verdict (a test that lies) still fails
liar="$tmp/t/liar"
image "$liar" liar <<EOF
${S}TEST liar: START
${S}  FAIL: the thing
${S}TEST liar: PASS
EOF
list "$tmp/liar.list" "liar${tab}$liar${tab}0${tab}pass${tab}-${tab}-"
expect_rc  "runner: a FAIL: line fails the test even with a PASS verdict" nonzero run "$tmp/liar.list"

nostart="$tmp/t/nostart"
image "$nostart" nostart <<EOF
${S}TEST nostart: PASS
EOF
list "$tmp/nostart.list" "nostart${tab}$nostart${tab}0${tab}pass${tab}-${tab}-"
expect_rc  "runner: a PASS without START fails" nonzero run "$tmp/nostart.list"
expect_out "runner: says START never appeared" "START line never appeared" run "$tmp/nostart.list"

silent="$tmp/t/silent"
image "$silent" silent < /dev/null
list "$tmp/silent.list" "silent${tab}$silent${tab}0${tab}pass${tab}-${tab}-"
expect_rc  "runner: a silent image fails" nonzero run "$tmp/silent.list"

hang="$tmp/t/hang"
image "$hang" hang <<EOF
${S}TEST hang: START
HANG
EOF
list "$tmp/hang.list" "hang${tab}$hang${tab}0${tab}pass${tab}-${tab}-"
expect_rc  "runner: a test without a verdict is killed and fails" nonzero run "$tmp/hang.list"
expect_out "runner: says there was no verdict" "no verdict line" run "$tmp/hang.list"

list "$tmp/missing.list" "nosuch${tab}$tmp/t/nosuch${tab}0${tab}pass${tab}-${tab}-"
expect_rc  "runner: a missing image fails" nonzero run "$tmp/missing.list"
expect_out "runner: says the image was not found" "not found" run "$tmp/missing.list"

# a name with a hart suffix names bin-<hart>/<rest>.elf
mkdir -p "$tmp/t/hart/bin-u54"
cp "$good/bin/good.elf" "$tmp/t/hart/bin-u54/good.elf"
sed -i 's/TEST good:/TEST good_u54:/' "$tmp/t/hart/bin-u54/good.elf"
list "$tmp/hart.list" "good_u54${tab}$tmp/t/hart${tab}0${tab}pass${tab}-${tab}-"
expect_rc  "runner: the _u54 suffix selects bin-u54" 0 run "$tmp/hart.list"

# _u54h<N> names the image of one U54 hart: bin-u54-h<N>/<rest>.elf
mkdir -p "$tmp/t/hart/bin-u54-h3"
cp "$good/bin/good.elf" "$tmp/t/hart/bin-u54-h3/good.elf"
sed -i 's/TEST good:/TEST good_u54h3:/' "$tmp/t/hart/bin-u54-h3/good.elf"
list "$tmp/hart3.list" "good_u54h3${tab}$tmp/t/hart${tab}0${tab}pass${tab}-${tab}-"
expect_rc  "runner: the _u54h3 suffix selects bin-u54-h3" 0 run "$tmp/hart3.list"
list "$tmp/hart4.list" "good_u54h4${tab}$tmp/t/hart${tab}0${tab}pass${tab}-${tab}-"
expect_rc  "runner: _u54h4 without bin-u54-h4 fails (no image)" nonzero run "$tmp/hart4.list"

# the verdict on another port than the row says
list "$tmp/port.list" "good${tab}$good${tab}1${tab}pass${tab}-${tab}-"
expect_rc  "runner: a verdict on another serial port fails" nonzero run "$tmp/port.list"

# output on a port that is not the test's
stray="$tmp/t/stray"
image "$stray" stray <<EOF
${S}TEST stray: START
S${tab}2${tab}noise
${S}  ok: a thing
${S}TEST stray: PASS
EOF
list "$tmp/stray.list" "stray${tab}$stray${tab}0${tab}pass${tab}-${tab}-"
expect_rc  "runner: output on another serial port fails" nonzero run "$tmp/stray.list"
expect_out "runner: names the port" "MMUART2" run "$tmp/stray.list"

# console.expected is asserted by the host
exp="$tmp/t/exp"
image "$exp" exp <<EOF
${S}TEST exp: START
${S}  ok: a thing
${S}hello from the guest
${S}TEST exp: PASS
EOF
printf 'hello from the guest\n' > "$exp/console.expected"
list "$tmp/exp.list" "exp${tab}$exp${tab}0${tab}pass${tab}-${tab}-"
expect_rc  "runner: console.expected is satisfied" 0 run "$tmp/exp.list"
printf 'hello from the guest\nsomething else\n' > "$exp/console.expected"
expect_rc  "runner: a line of console.expected that never appears fails" nonzero run "$tmp/exp.list"
expect_out "runner: names the missing line" 'MISSING from the console: "something else"' run "$tmp/exp.list"

# <image>.expected replaces console.expected for that image (a directory with several images)
printf 'hello from the guest\n' > "$exp/console.expected"
printf 'something else\n' > "$exp/exp.expected"
expect_rc  "runner: <image>.expected is used instead of console.expected" nonzero run "$tmp/exp.list"
expect_out "runner: names the file of the image" 'exp/exp.expected never appeared' run "$tmp/exp.list"
printf 'a thing\nhello from the guest\n' > "$exp/exp.expected"
printf 'something else\n' > "$exp/console.expected"
expect_rc  "runner: <image>.expected that is satisfied wins over a console.expected that is not" 0 run "$tmp/exp.list"
rm "$exp/exp.expected" "$exp/console.expected"

# expected failures: the signature must match, and a pass is a failure
xf="$tmp/t/xf"
image "$xf" xf <<EOF
${S}TEST xf: START
T${tab}riscv_cpu_do_interrupt: epc:0x80000000, tval:0xc002080, desc=fault_store
EOF
list "$tmp/xf.list" "xf${tab}$xf${tab}0${tab}xfail${tab}desc=fault_store${tab}the PLIC faults"
expect_rc  "runner: a failure with the documented signature is an xfail" 0 run "$tmp/xf.list"
expect_out "runner: reports XFAIL" "XFAIL xf" run "$tmp/xf.list"
list "$tmp/xf2.list" "xf${tab}$xf${tab}0${tab}xfail${tab}desc=something_else${tab}the PLIC faults"
expect_rc  "runner: a failure with another signature is a failure" nonzero run "$tmp/xf2.list"
expect_out "runner: says it failed in another way" "NOT in the documented way" run "$tmp/xf2.list"
list "$tmp/xf3.list" "good${tab}$good${tab}0${tab}xfail${tab}desc=fault_store${tab}fixed"
expect_rc  "runner: an unexpected pass of an xfail row fails" nonzero run "$tmp/xf3.list"
expect_out "runner: says unexpected pass" "UNEXPECTED PASS" run "$tmp/xf3.list"

# one failing test among passing ones fails the run, and the others still run
list "$tmp/mix.list" "good${tab}$good${tab}0${tab}pass${tab}-${tab}-" "failing${tab}$failing${tab}0${tab}pass${tab}-${tab}-"
expect_rc  "runner: one failing test fails the run" nonzero run "$tmp/mix.list"
expect_out "runner: the other test still ran" "PASS good" run "$tmp/mix.list"
expect_rc  "runner: a named test can be run alone" 0 run "$tmp/mix.list" -- good
expect_rc  "runner: an unlisted name fails" nonzero run "$tmp/mix.list" -- nosuch

# the list itself
: > "$tmp/empty.list"
expect_rc  "runner: an empty list fails" nonzero run "$tmp/empty.list"
printf 'name\tdir\tserial\texpect\tobserve\twhy\n' > "$tmp/header.list"
expect_rc  "runner: a list without a row fails" nonzero run "$tmp/header.list"
printf 'name\tdir\tserial\n%s\t%s\t0\n' good "$good" > "$tmp/badhdr.list"
expect_rc  "runner: a wrong header fails" nonzero run "$tmp/badhdr.list"
list "$tmp/badserial.list" "good${tab}$good${tab}5${tab}pass${tab}-${tab}-"
expect_rc  "runner: a serial port above 4 fails" nonzero run "$tmp/badserial.list"
list "$tmp/badexp.list" "good${tab}$good${tab}0${tab}maybe${tab}-${tab}-"
expect_rc  "runner: an expect that is neither pass nor xfail fails" nonzero run "$tmp/badexp.list"
list "$tmp/xfbare.list" "good${tab}$good${tab}0${tab}xfail${tab}-${tab}-"
expect_rc  "runner: an xfail row without signature and reason fails" nonzero run "$tmp/xfbare.list"
expect_rc  "runner: a missing list fails" nonzero run "$tmp/none.list"
expect_rc  "runner: a bad timeout fails" nonzero run "$tmp/ok.list" TEST_TIMEOUT=x

# QEMU
expect_rc  "runner: a QEMU older than the floor fails" nonzero run "$tmp/ok.list" QEMU_FAKE_VERSION=9.2.0
expect_out "runner: reports the floor" "older than" run "$tmp/ok.list" QEMU_FAKE_VERSION=9.2.0
expect_rc  "runner: without QEMU it fails" nonzero run "$tmp/ok.list" QEMU="$tmp/q/none"

# The committed list: the rows name the images that report_test builds.
list_c="$ROOT/tests/qemu/tests.list"
for hart in e51 u54; do
  grep -q "^report_test_${hart}${tab}examples/report_test${tab}0${tab}pass${tab}-${tab}-\$" "$list_c" \
    && pass "tests.list: report_test_$hart" || fail "tests.list: report_test_$hart"
done
grep -q '^BUILD_HARTS=e51 u54$' "$ROOT/examples/report_test/example.conf" \
  && pass "report_test is built for both harts" || fail "report_test is built for both harts"

# tasking_test and interrupt_test (P1.4) run on hart 0, hart 1 and on U54 hart 3 (-smp 5 in the runner)
for ex in tasking_test interrupt_test; do
  for hart in e51 u54 u54h3; do
    grep -q "^${ex}_${hart}${tab}examples/${ex}${tab}0${tab}pass${tab}-${tab}-\$" "$list_c" \
      && pass "tests.list: ${ex}_$hart" || fail "tests.list: ${ex}_$hart"
  done
  grep -q '^BUILD_HARTS=e51 u54 u54-h3$' "$ROOT/examples/$ex/example.conf" \
    && pass "$ex is built for e51, u54 and u54-h3" || fail "$ex is built for e51, u54 and u54-h3"
done
# exceptions_test, unhandled_test and unhandled_task_test (P1.7) are three images of one example
# with the embedded runtime, for the E51 and hart 1 of the U54
for t in exceptions_test unhandled_test unhandled_task_test; do
  for hart in e51 u54; do
    grep -q "^${t}_${hart}${tab}examples/exceptions_test${tab}0${tab}pass${tab}-${tab}-\$" "$list_c" \
      && pass "tests.list: ${t}_$hart" || fail "tests.list: ${t}_$hart"
  done
done
grep -q '^BUILD_HARTS=e51 u54$' "$ROOT/examples/exceptions_test/example.conf" \
  && grep -q '^PROFILE=embedded$' "$ROOT/examples/exceptions_test/example.conf" \
  && pass "exceptions_test is built for e51 and u54 with the embedded runtime" \
  || fail "exceptions_test is built for e51 and u54 with the embedded runtime"
for t in unhandled_test unhandled_task_test; do
  [ -f "$ROOT/examples/exceptions_test/$t.expected" ] && pass "$t has its own .expected file" || fail "$t has its own .expected file"
done
grep -q -- '-smp 5' "$ROOT/tests/qemu/run_tests.sh" \
  && pass "the runner starts all five harts (-smp 5)" || fail "the runner starts all five harts (-smp 5)"

echo "summary: $fails failure(s)"
[ $fails -eq 0 ]
