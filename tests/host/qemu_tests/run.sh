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

# console rows: a program without Test_Report (it ends in the last chance handler of the runtime); the
# verdict is that the line of the row is on the port of the row and that no other port is written
halted="$tmp/t/halted"
image "$halted" halted <<EOF
${S}In last chance handler
${S}interrupt stack overflow
EOF
list "$tmp/console.list" "halted${tab}$halted${tab}0${tab}console${tab}^interrupt stack overflow${tab}the guard word is found"
expect_rc  "runner: a console row whose line is on its port passes" 0 run "$tmp/console.list"
expect_out "runner: says the console row passed" "PASS halted: the guard word is found" run "$tmp/console.list"
list "$tmp/console2.list" "halted${tab}$halted${tab}0${tab}console${tab}^Unhandled${tab}the guard word is found"
expect_rc  "runner: a console row whose line never appears fails" nonzero run "$tmp/console2.list"
expect_out "runner: says what did not match" "nothing matched /^Unhandled/" run "$tmp/console2.list"
list "$tmp/console3.list" "halted${tab}$halted${tab}1${tab}console${tab}^interrupt stack overflow${tab}the guard word is found"
expect_rc  "runner: a console row whose line is on another port fails" nonzero run "$tmp/console3.list"
halted_stray="$tmp/t/halted_stray"
image "$halted_stray" halted_stray <<EOF
${S}interrupt stack overflow
S${tab}2${tab}noise
EOF
list "$tmp/console4.list" "halted_stray${tab}$halted_stray${tab}0${tab}console${tab}^interrupt stack overflow${tab}the guard word is found"
expect_rc  "runner: a console row that writes to another port fails" nonzero run "$tmp/console4.list"
expect_out "runner: names the port of a console row" "MMUART2" run "$tmp/console4.list"
halted_hang="$tmp/t/halted_hang"
image "$halted_hang" halted_hang <<EOF
${S}In last chance handler
HANG
EOF
list "$tmp/console5.list" "halted_hang${tab}$halted_hang${tab}0${tab}console${tab}^interrupt stack overflow${tab}the guard word is found"
expect_rc  "runner: a console row whose program hangs without the line is killed and fails" nonzero run "$tmp/console5.list"
list "$tmp/console6.list" "halted${tab}$halted${tab}0${tab}console${tab}-${tab}-"
expect_rc  "runner: a console row without regexp and reason fails" nonzero run "$tmp/console6.list"

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

# tasking_test and interrupt_test run on hart 0, hart 1 and on U54 hart 3 (-smp 5 in the runner)
for ex in tasking_test interrupt_test; do
  for hart in e51 u54 u54h3; do
    grep -q "^${ex}_${hart}${tab}examples/${ex}${tab}0${tab}pass${tab}-${tab}-\$" "$list_c" \
      && pass "tests.list: ${ex}_$hart" || fail "tests.list: ${ex}_$hart"
  done
  grep -q '^BUILD_HARTS=e51 u54 u54-h3$' "$ROOT/examples/$ex/example.conf" \
    && pass "$ex is built for e51, u54 and u54-h3" || fail "$ex is built for e51, u54 and u54-h3"
done
# float_test (both hart classes) and fp_context_test (U54 only: the E51 has no FP registers)
for hart in e51 u54; do
  grep -q "^float_test_${hart}${tab}examples/float_test${tab}0${tab}pass${tab}-${tab}-\$" "$list_c" \
    && pass "tests.list: float_test_$hart" || fail "tests.list: float_test_$hart"
done
grep -q '^BUILD_HARTS=e51 u54$' "$ROOT/examples/float_test/example.conf" \
  && pass "float_test is built for both harts" || fail "float_test is built for both harts"
grep -q "^fp_context_test_u54${tab}examples/fp_context_test${tab}0${tab}pass${tab}-${tab}-\$" "$list_c" \
  && pass "tests.list: fp_context_test_u54" || fail "tests.list: fp_context_test_u54"
grep -q '^fp_context_test_e51' "$list_c" \
  && fail "tests.list: no fp_context_test row for the E51 (no FP registers)" \
  || pass "tests.list: no fp_context_test row for the E51 (no FP registers)"
grep -q '^BUILD_HARTS=u54$' "$ROOT/examples/fp_context_test/example.conf" \
  && pass "fp_context_test is built for the U54 only" || fail "fp_context_test is built for the U54 only"
# exceptions_test, unhandled_test and unhandled_task_test are three images of one example
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
# heap_test (embedded) and the three secondary stack tests, one per profile, for the E51 and hart 1
# of the U54: the example of a profile has that profile in its example.conf
for spec in heap_test:embedded secstack_test:embedded secstack_light_test:light secstack_tasking_test:light-tasking; do
  t="${spec%%:*}"; prof="${spec#*:}"
  for hart in e51 u54; do
    grep -q "^${t}_${hart}${tab}examples/${t}${tab}0${tab}pass${tab}-${tab}-\$" "$list_c" \
      && pass "tests.list: ${t}_$hart" || fail "tests.list: ${t}_$hart"
  done
  grep -q '^BUILD_HARTS=e51 u54$' "$ROOT/examples/$t/example.conf" \
    && grep -q "^PROFILE=$prof\$" "$ROOT/examples/$t/example.conf" \
    && pass "$t is built for e51 and u54 with the $prof runtime" \
    || fail "$t is built for e51 and u54 with the $prof runtime"
  [ -f "$ROOT/examples/$t/console.expected" ] && pass "$t has a console.expected file" || fail "$t has a console.expected file"
done
# textio_test (six images: the console of the runtime on each MMUART and with init 0) and console_none_test
for hart in e51 u54; do
  hs=0; [ "$hart" = u54 ] && hs=1   # the console of the runtime is the MMUART of the hart
  grep -q "^textio_test_${hart}${tab}examples/textio_test${tab}${hs}${tab}pass${tab}-${tab}-\$" "$list_c" \
    && pass "tests.list: textio_test_$hart" || fail "tests.list: textio_test_$hart"
  for n in 1 2 3 4; do
    grep -q "^console_mmuart${n}_test_${hart}${tab}examples/textio_test${tab}${n}${tab}pass${tab}-${tab}-\$" "$list_c" \
      && pass "tests.list: console_mmuart${n}_test_$hart reports on serial $n" \
      || fail "tests.list: console_mmuart${n}_test_$hart reports on serial $n"
  done
  grep -q "^console_noinit_test_${hart}${tab}examples/textio_test${tab}${hs}${tab}pass${tab}-${tab}-\$" "$list_c" \
    && pass "tests.list: console_noinit_test_$hart" || fail "tests.list: console_noinit_test_$hart"
  grep -q "^console_none_test_${hart}${tab}examples/console_none_test${tab}0${tab}pass${tab}-${tab}-\$" "$list_c" \
    && pass "tests.list: console_none_test_$hart" || fail "tests.list: console_none_test_$hart"
done
for ex in textio_test console_none_test; do
  grep -q '^BUILD_HARTS=e51 u54$' "$ROOT/examples/$ex/example.conf" \
    && pass "$ex is built for both harts" || fail "$ex is built for both harts"
done
for t in textio_test console_mmuart1_test console_mmuart2_test console_mmuart3_test console_mmuart4_test console_noinit_test; do
  [ -f "$ROOT/examples/textio_test/$t.expected" ] && pass "$t has its own .expected file" || fail "$t has its own .expected file"
done
# The cells of the test set (docs/assurance/test-matrix.md): a test that runs in several runtime profiles is one
# example per profile (examples/STYLE.md, "Profile variants"). Each variant is built for the harts it names,
# has the profile in its example.conf, a row per hart image in tests/qemu/tests.list, and the same expected
# console (and input) as the example whose sources it shares, so that the two cannot drift apart.
# <example>:<example of the sources>:<profile>:<harts>
for spec in \
  trap_tasking_test:trap_test:light-tasking:"e51 u54" \
  textio_tasking_test:textio_test:light-tasking:"e51 u54" \
  textio_embedded_test:textio_test:embedded:"e51 u54" \
  float_tasking_test:float_test:light-tasking:"e51 u54" \
  float_embedded_test:float_test:embedded:"e51 u54" \
  tasking_embedded_test:tasking_test:embedded:"e51 u54" \
  protected_embedded_test:protected_test:embedded:"e51 u54" \
  interrupt_embedded_test:interrupt_test:embedded:"e51 u54" \
  delay_accuracy_embedded_test:delay_accuracy_test:embedded:"e51 u54" \
  fp_context_embedded_test:fp_context_test:embedded:u54 \
  elab_embedded_test:elab_tasking_test:embedded:"e51 u54"; do
  IFS=: read -r v o prof harts <<< "$spec"
  ec="$ROOT/examples/$v/example.conf"
  grep -q "^PROFILE=$prof\$" "$ec" && grep -q "^BUILD_HARTS=$harts\$" "$ec" \
    && pass "$v is built for $harts with the $prof runtime" || fail "$v is built for $harts with the $prof runtime"
  for hart in $harts; do
    #  the report of a textio variant goes out through System.Text_IO, i.e. the console of the hart:
    #  MMUART1 on hart 1 (serial 1 of QEMU); the other tests report through Bare_Console (MMUART0)
    port=0; case "$v:$hart" in textio_*_test:u54) port=1 ;; esac
    grep -q "^${v}_${hart}${tab}examples/${v}${tab}${port}${tab}pass${tab}-${tab}-\$" "$list_c" \
      && pass "tests.list: ${v}_$hart" || fail "tests.list: ${v}_$hart"
  done
  #  (an example with several images has <image>.expected files instead of a console.expected)
  src="$ROOT/examples/$o/console.expected"; [ -f "$src" ] || src="$ROOT/examples/$o/$o.expected"
  cmp -s "$src" "$ROOT/examples/$v/console.expected" \
    && pass "$v has the expected console of $o" || fail "$v has the expected console of $o"
  if [ -f "$ROOT/examples/$o/console.in" ] || [ -f "$ROOT/examples/$v/console.in" ]; then
    cmp -s "$ROOT/examples/$o/console.in" "$ROOT/examples/$v/console.in" \
      && pass "$v has the console.in of $o" || fail "$v has the console.in of $o"
  fi
  grep -q "for Spec (\"Test_Name\") use \"test_name_[a-z]*\.ads\"" "$ROOT/examples/$v/app.gpr" \
    && pass "$v has a Test_Name of its own" || fail "$v has a Test_Name of its own"
done
# Cells that are not variants of another example: one per profile and hart class
for spec in protected_test:light-tasking trap_embedded_test:embedded elab_test:light elab_tasking_test:light-tasking; do
  t="${spec%%:*}"; prof="${spec#*:}"
  for hart in e51 u54; do
    grep -q "^${t}_${hart}${tab}examples/${t}${tab}0${tab}pass${tab}-${tab}-\$" "$list_c" \
      && pass "tests.list: ${t}_$hart" || fail "tests.list: ${t}_$hart"
  done
  grep -q '^BUILD_HARTS=e51 u54$' "$ROOT/examples/$t/example.conf" \
    && grep -q "^PROFILE=$prof\$" "$ROOT/examples/$t/example.conf" \
    && pass "$t is built for e51 and u54 with the $prof runtime" \
    || fail "$t is built for e51 and u54 with the $prof runtime"
  [ -f "$ROOT/examples/$t/console.expected" ] && pass "$t has a console.expected file" || fail "$t has a console.expected file"
done
# The tests of the interrupt stack (#91, docs/assurance/test-matrix.md): two examples that share their sources, one
# per profile; each is built for both harts with its profile; the images that report (peak, overflow) have a row
# of the kind pass and an <image>.expected file, the images that end in the last chance handler of the runtime
# (halt, and tiny in light-tasking) a row of the kind console on the port of the console of the runtime (MMUART0 on
# the E51, MMUART1 on U54 hart 1); the expected console of the two profiles is the same.
for spec in interrupt_stack_embedded_test:embedded:"peak overflow halt" interrupt_stack_tasking_test:light-tasking:"peak overflow halt tiny"; do
  IFS=: read -r t prof imgs <<< "$spec"; p="${t#interrupt_stack_}"; p="${p%_test}"
  grep -q '^BUILD_HARTS=e51 u54$' "$ROOT/examples/$t/example.conf" && grep -q "^PROFILE=$prof\$" "$ROOT/examples/$t/example.conf" \
    && pass "$t is built for e51 and u54 with the $prof runtime" || fail "$t is built for e51 and u54 with the $prof runtime"
  for img in $imgs; do
    for hart in e51 u54; do
      hs=0; [ "$hart" = u54 ] && hs=1
      case "$img" in
        peak|overflow) row="istack_${img}_${p}_test_${hart}${tab}examples/${t}${tab}0${tab}pass${tab}-${tab}-" ;;
        *) row="istack_${img}_${p}_test_${hart}${tab}examples/${t}${tab}${hs}${tab}console${tab}^interrupt stack overflow${tab}" ;;
      esac
      grep -q "^${row}" "$list_c" && pass "tests.list: istack_${img}_${p}_test_$hart" || fail "tests.list: istack_${img}_${p}_test_$hart"
    done
  done
  for img in peak overflow; do
    [ -f "$ROOT/examples/$t/istack_${img}_${p}_test.expected" ] \
      && pass "istack_${img}_${p}_test has its own .expected file" || fail "istack_${img}_${p}_test has its own .expected file"
  done
done
for img in peak overflow; do
  cmp -s "$ROOT/examples/interrupt_stack_embedded_test/istack_${img}_embedded_test.expected" \
         "$ROOT/examples/interrupt_stack_tasking_test/istack_${img}_tasking_test.expected" \
    && pass "istack_${img}: the two profiles have the same expected console" || fail "istack_${img}: the two profiles have the same expected console"
done
grep -q 'for Spec ("Test_Name") use "test_name_tasking.ads"' "$ROOT/examples/interrupt_stack_tasking_test/app.gpr" \
  && pass "interrupt_stack_tasking_test has a Test_Name of its own" || fail "interrupt_stack_tasking_test has a Test_Name of its own"
# No expected failure in the committed list: every cell of the test set is a test that passes on QEMU
# (a row that documents a defect would hide that the cell is not green).
if grep -v '^[[:space:]]*#' "$list_c" | awk -F'\t' '$4 == "xfail" { f = 1 } END { exit f ? 0 : 1 }'; then
  fail "tests.list: no xfail row"
else
  pass "tests.list: no xfail row"
fi
# and none is skipped: the directory of every row is an example that has the image's project
missing=0
while IFS="$tab" read -r name dir rest; do
  [ "$name" = name ] && continue
  [ -f "$ROOT/$dir/app.gpr" ] && [ -f "$ROOT/$dir/example.conf" ] || { missing=$((missing + 1)); echo "  no project for $name in $dir" >&2; }
done < <(grep -v '^[[:space:]]*#' "$list_c" | grep -v '^[[:space:]]*$')
[ $missing -eq 0 ] && pass "tests.list: every row names an example with a project" \
  || fail "tests.list: every row names an example with a project"
grep -q -- '-smp 5' "$ROOT/tests/qemu/run_tests.sh" \
  && pass "the runner starts all five harts (-smp 5)" || fail "the runner starts all five harts (-smp 5)"

echo "summary: $fails failure(s)"
[ $fails -eq 0 ]
