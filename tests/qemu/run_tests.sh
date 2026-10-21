#!/bin/sh
#  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
#  SPDX-License-Identifier: Apache-2.0
#
#  run_tests.sh -- boot every test application under QEMU and ASSERT its
#  verdict.   Driven by `./x test qemu` (after smoke.sh), which builds the images.
#
#  usage: sh tests/qemu/run_tests.sh [test-name ...]       (default: every test listed)
#
#    QEMU QEMU_MACHINE QEMU_MIN   as for smoke.sh (qemu_preflight.sh)
#    TEST_LIST      the list of tests (default tests.list next to this script)
#    TEST_TIMEOUT   seconds a test may run before it is killed (default 30)
#
#  THE LIST (tests.list, TAB-separated, edited by hand): name, dir, serial,
#  expect, observe, why. `name` is the <name> of the "TEST <name>: PASS" line;
#  `dir` is the example directory relative to the repository root (or absolute). The image of
#  a name ending in _e51 or _u54 is <dir>/bin-<e51|u54>/<rest of the name>.elf,
#  otherwise <dir>/bin/<name>.elf.
#
#  THE PROTOCOL (tests/common/test_report.ads, tests/host/common/host_report.ads):
#  a test prints
#      TEST <name>: START ... "  FAIL: <what>" lines ... TEST <name>: PASS|FAIL
#  on a guest serial port (column 3 of the list says which: 0..4 = MMUART0..MMUART4,
#  QEMU's first..fifth -serial; all five are always attached, each to its own
#  file). A `pass` test passes only if ALL hold:
#      - its image exists                              (else FAIL, never a skip)
#      - "TEST <name>: START" was printed              (the program really ran)
#      - "TEST <name>: PASS" was printed               (it reached its verdict)
#      - no "TEST <name>: FAIL" line, and no "  FAIL:" line
#      - every line of <dir>/console.expected, if the file exists, appears on the
#        port (output is asserted by the HOST: a program cannot check its own wire)
#      - NOTHING was written to any OTHER serial port, so that a test of a console
#        configuration means something: output on the wrong port must not pass
#        because the test also looked at the right one.
#  and fails with the reason otherwise: a failed check, a missing sentinel (hang,
#  crash, silence), a missing line, or a timeout. If <dir>/console.in exists its
#  bytes are fed to the serial port as the guest's input.
#
#  EXPECTED FAILURES. A row whose `expect` is `xfail` documents a KNOWN defect.
#  It is not a skip and not a pass; it must fail IN THE DOCUMENTED WAY:
#      - the test must NOT print "TEST <name>: PASS" on its port (if it does, that
#        is an UNEXPECTED PASS: the defect is fixed -- flip the row to `pass`), and
#      - the row's `observe` regexp (grep -E) must match somewhere in QEMU's
#        `-d int,guest_errors` trace or on a serial port. A test that fails for a
#        DIFFERENT reason is a failure, never an xfail: that is the whole point of
#        requiring a signature. Re-document the row, or fix the defect.
#  The trace signature depends on QEMU's log format; it fails closed (a format
#  change turns an xfail into a failure that says so), never open.
#
#  Exit status: non-zero if ANY test failed. A test list that is empty or
#  malformed is a failure too (zero tests must not mean zero failures).
#
#  The console is searched on the guest's serial ports only (-serial file:...),
#  never on QEMU's own stderr -- the same rule as smoke.sh -- and each test ends
#  as soon as its outcome is decided, so a passing run is fast and the timeout
#  only costs anything when something is wrong. The bound is a watchdog
#  (background + poll + kill -9), not `timeout`/alarm(): QEMU swallows SIGALRM
#  and BSD userland has no `timeout`.
#
#  POSIX sh only: this runs under dash (Ubuntu's /bin/sh) and macOS's bash-as-sh.

set -u

QEMU=${QEMU:-qemu-system-riscv64}
QEMU_MACHINE=${QEMU_MACHINE:-microchip-icicle-kit}
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
if [ -z "${QEMU_MIN:-}" ]; then
  QEMU_MIN=$(sed -n 's/^QEMU_MIN=//p' "$root/tools/toolchain.env" 2>/dev/null | head -n 1)
  QEMU_MIN=${QEMU_MIN:-10.1}
fi
TEST_LIST=${TEST_LIST:-$here/tests.list}
TEST_TIMEOUT=${TEST_TIMEOUT:-30}

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

case "$TEST_TIMEOUT" in
  ''|*[!0-9]*) fail "TEST_TIMEOUT must be a whole number of seconds, got '$TEST_TIMEOUT'" ;;
esac

tmpd=$(mktemp -d "${TMPDIR:-/tmp}/tests.XXXXXX") || fail "mktemp -d failed"
qpid=
wdog=
cleanup() {
  [ -n "$wdog" ] && kill "$wdog" 2>/dev/null
  [ -n "$qpid" ] && kill -9 "$qpid" 2>/dev/null
  rm -rf "$tmpd"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

#  --- the list ----------------------------------------------------------------
[ -f "$TEST_LIST" ] || fail "test list '$TEST_LIST' does not exist"
rows="$tmpd/rows"
awk -F'\t' '
  /^[ \t]*#/ || /^[ \t]*$/ { next }
  !hdr { hdr = 1
         if ($1 != "name" || $2 != "dir" || $3 != "serial" || $4 != "expect" || $5 != "observe" || $6 != "why" || NF != 6) {
           print "BADHEADER" > "/dev/stderr"; bad = 1 }
         next }
  NF != 6 || $1 == "" || $2 == "" || $5 == "" || $6 == "" ||
  $3 !~ /^[0-4]$/ || ($4 != "pass" && $4 != "xfail") ||
  ($4 == "xfail" && ($5 == "-" || $6 == "-")) { printf "BADROW\t%s\n", $0; bad = 1; next }
  { print }
  END { exit bad ? 1 : 0 }
' "$TEST_LIST" > "$rows" 2> "$tmpd/awk.err"
if [ $? -ne 0 ]; then
  cat "$tmpd/awk.err" >&2
  grep '^BADROW' "$rows" | while IFS= read -r l; do printf '  %s\n' "$l" >&2; done
  fail "$TEST_LIST is malformed: the first non-comment line must be the 'name dir serial expect observe why' header (TAB-separated); every row needs all six fields, serial 0..4, expect pass|xfail, and an xfail row a real observe regexp and reason"
fi
[ -s "$rows" ] || fail "$TEST_LIST lists no tests; an empty list would make this pass vacuously"

#  Names to run: the arguments, each of which must be listed; else all.
if [ $# -gt 0 ]; then
  names=
  for n in "$@"; do
    awk -F'\t' -v n="$n" '$1 == n { f = 1 } END { exit f ? 0 : 1 }' "$rows" \
      || fail "'$n' is not listed in $TEST_LIST"
    names="$names $n"
  done
else
  names=$(awk -F'\t' '{ print $1 }' "$rows")
fi

. "$here/qemu_preflight.sh"

#  --- run each test -------------------------------------------------------------
final_line() {   #  $1 = name, $2 = console file: has a PASS or FAIL verdict line?
  grep -Eq "^TEST $1: (PASS|FAIL)" "$2"
}

field() {        #  $1 = name, $2 = column number
  awk -F'\t' -v n="$1" -v c="$2" '$1 == n { print $c; exit }' "$rows"
}

failures=0
passed=0
xfailed=0
for name in $names; do
  dir=$(field "$name" 2)
  serial=$(field "$name" 3)
  expect=$(field "$name" 4)
  observe=$(field "$name" 5)
  why=$(field "$name" 6)
  case "$dir" in /*) base=$dir ;; *) base="$root/$dir" ;; esac
  case "$name" in
    *_e51) img="$base/bin-e51/${name%_e51}.elf" ;;
    *_u54) img="$base/bin-u54/${name%_u54}.elf" ;;
    *)     img="$base/bin/$name.elf" ;;
  esac
  printf '==> %s%s\n' "$name" "$([ "$expect" = xfail ] && echo ' (expected failure)')"
  if [ ! -f "$img" ]; then
    printf 'FAIL %s: image %s not found (run ./x test qemu, which builds it)\n' "$name" "$img" >&2
    failures=$((failures + 1)); continue
  fi

  conbase="$tmpd/$name.console"
  err="$tmpd/$name.stderr"; log="$tmpd/$name.qemulog"
  : > "$log"
  consoles=
  for i in 0 1 2 3 4; do : > "$conbase$i"; consoles="$consoles $conbase$i"; done
  verdict="$conbase$serial"
  #  A comma in a path must be doubled for QEMU's option parser.
  q0=$(printf '%s' "${conbase}0" | sed 's/,/,,/g')
  qlog=$(printf '%s' "$log" | sed 's/,/,,/g')

  set -- -M "$QEMU_MACHINE" -m 2G -display none -monitor none -bios none -kernel "$img" -no-reboot
  if [ -f "$base/console.in" ]; then
    qin=$(printf '%s' "$base/console.in" | sed 's/,/,,/g')
    set -- "$@" -chardev "file,id=con0,path=$q0,input-path=$qin" -serial chardev:con0
  else
    set -- "$@" -serial "file:$q0"
  fi
  for i in 1 2 3 4; do
    qi=$(printf '%s' "$conbase$i" | sed 's/,/,,/g')
    set -- "$@" -serial "file:$qi"
  done
  [ "$expect" = xfail ] && set -- "$@" -d int,guest_errors -D "$qlog"

  #  The trace of a guest stuck in a trap loop grows without bound (measured: 2.4 GB
  #  in under a minute, and `grep` over it then outran the watchdog). So QEMU runs
  #  under a file-size limit -- QEMU dies of SIGXFSZ at the cap, which is far
  #  more than the signature needs -- and the watchdog counts wall-clock seconds,
  #  not polls. ulimit -f is in 512-byte blocks (POSIX): 40000 = 20 MB.
  ( ulimit -f 40000 2>/dev/null; exec "$QEMU" "$@" ) </dev/null >"$err" 2>&1 &
  qpid=$!
  (
    end=$(( $(date +%s) + TEST_TIMEOUT ))
    while [ "$(date +%s)" -lt "$end" ]; do
      final_line "$name" "$verdict" && break
      if [ "$expect" = xfail ]; then
        grep -Eq -- "$observe" "$log" $consoles && break
      fi
      sleep 0.1 2>/dev/null || sleep 1
    done
    kill -9 "$qpid" 2>/dev/null
  ) &
  wdog=$!
  wait "$qpid" 2>/dev/null
  qstatus=$?
  kill "$wdog" 2>/dev/null
  wait "$wdog" 2>/dev/null
  qpid=; wdog=

  #  Show the test's own lines (the serial ports only, never QEMU stderr).
  for i in 0 1 2 3 4; do
    if [ -s "$conbase$i" ]; then
      echo "    | -- MMUART$i --"; tr -d '\r' < "$conbase$i" | sed 's/^/    | /'
    fi
  done

  reason=
  if [ "$expect" = xfail ]; then
    started="did not print its START line"
    grep -Eq "^TEST $name: START" "$verdict" && started="DID print its START line"
    if grep -Eq "^TEST $name: PASS" "$verdict"; then
      reason="UNEXPECTED PASS on serial $serial although this row documents a known failure ($why). The defect looks fixed: change the row's expect to 'pass'."
    elif ! grep -Eq -- "$observe" "$log" $consoles; then
      reason="it failed, but NOT in the documented way: nothing matched /$observe/ in QEMU's trace or on either serial port within ${TEST_TIMEOUT}s (the test $started). Documented failure: $why. Either the defect changed -- re-document the row -- or this is a new failure."
    fi
    if [ -n "$reason" ]; then
      printf 'FAIL %s: %s\n' "$name" "$reason" >&2
      failures=$((failures + 1))
    else
      printf 'XFAIL %s: failed as documented -- %s\n' "$name" "$why"
      xfailed=$((xfailed + 1))
    fi
    continue
  fi

  if ! grep -Eq "^TEST $name: START" "$verdict"; then
    reason="the START line never appeared on serial $serial -- the image did not run, or printed nothing there"
  elif ! final_line "$name" "$verdict"; then
    reason="no verdict line (TEST $name: PASS or FAIL) within ${TEST_TIMEOUT}s -- hung, crashed or looped before Finish (QEMU exit status $qstatus; 137 = killed by the watchdog)"
  elif grep -Eq "^TEST $name: FAIL" "$verdict" || grep -Eq '^  FAIL:' "$verdict"; then
    reason="the test reported failing checks"
  elif ! grep -Eq "^TEST $name: PASS" "$verdict"; then
    reason="no PASS line"
  elif [ -f "$base/console.expected" ]; then
    missing=0
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      if ! grep -qF -- "$line" "$verdict"; then
        printf '    MISSING from the console: "%s"\n' "$line" >&2
        missing=$((missing + 1))
      fi
    done < "$base/console.expected"
    [ "$missing" -eq 0 ] || reason="$missing line(s) of $dir/console.expected never appeared on serial $serial"
  fi

  #  A pass test must be silent on every port but its own.
  if [ -z "$reason" ]; then
    stray=
    for i in 0 1 2 3 4; do
      [ "$i" = "$serial" ] && continue
      [ -s "$conbase$i" ] && stray="$stray MMUART$i"
    done
    [ -z "$stray" ] || reason="output appeared on${stray}, but the test belongs to MMUART$serial and nothing may be written to another port"
  fi

  if [ -n "$reason" ]; then
    printf 'FAIL %s: %s\n' "$name" "$reason" >&2
    if [ -s "$err" ]; then
      echo "  QEMU stderr:" >&2
      head -n 20 "$err" | while IFS= read -r l; do printf '    | %s\n' "$l" >&2; done
    fi
    failures=$((failures + 1))
  else
    printf 'PASS %s\n' "$name"
    passed=$((passed + 1))
  fi
done

if [ "$failures" -ne 0 ]; then
  printf 'tests FAILED: %d of %d test(s) did not do what tests.list says (%d passed, %d failed as documented)\n' \
    "$failures" "$((failures + passed + xfailed))" "$passed" "$xfailed" >&2
  exit 1
fi
printf 'tests OK: %d passed under QEMU, %d failed as documented (expected failures)\n' "$passed" "$xfailed"
