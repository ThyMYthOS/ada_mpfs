#!/bin/sh
#  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
#  SPDX-License-Identifier: Apache-2.0
#  Derived from ThyMYthOS/ada-machine rts-spikes/smoke.sh @ 2f0be23; modified for PolarFire SoC.
#
#  smoke.sh -- boot every console-producing image under QEMU and ASSERT that it
#  printed what smoke.expected says it must.   Driven by `./x test qemu`.
#
#  usage: sh tests/qemu/smoke.sh        (the images must be built; ./x test qemu does it)
#
#    QEMU            qemu-system-riscv64 binary (name on PATH, or a path)
#    QEMU_MACHINE    microchip-icicle-kit
#    QEMU_MIN        oldest acceptable QEMU, "major.minor"; "0" disables the check
#                    (default: QEMU_MIN of tools/toolchain.env)
#    SMOKE_EXPECTED  the expectation file (default smoke.expected next to this script)
#    SMOKE_TIMEOUT   seconds a boot may take before it is killed (default 20)
#
#  WHY THIS EXISTS. `./x qemu` shows output and exits 0 whatever it saw: a check
#  that reports success while testing nothing. Each rule below closes one way
#  this script could pass without the image having run:
#
#    - QEMU missing, unusable, too old, or without the machine is a FAILURE with
#      the reason, never a skip.
#    - A missing image is a FAILURE, never a skip.
#    - The strings are searched on the GUEST CONSOLE only. The serial port is
#      routed to a file (-serial file:...), so QEMU's own stderr -- including its
#      unconditional "does not generate a device tree" warning -- can never
#      satisfy an expectation, and neither can a shell echo of ours.
#    - An empty console fails (and says it was empty).
#    - An empty or unparseable expectation file, or a row with an empty field, is
#      a FAILURE: zero expectations must not mean zero failures.
#    - A boot is bounded. Success ends it early, so a passing run is fast and the
#      timeout only costs anything when something is wrong.
#
#  The run is bounded by a watchdog, not `timeout`: there is no `timeout` on
#  macOS, and alarm()-based substitutes do not work against QEMU.
#
#  POSIX sh only: this runs under dash (Ubuntu's /bin/sh) and macOS's bash-as-sh.

set -u

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)

#  The QEMU floor is pinned in tools/toolchain.env (plain NAME=VALUE lines).
if [ -z "${QEMU_MIN:-}" ]; then
  QEMU_MIN=$(sed -n 's/^QEMU_MIN=//p' "$root/tools/toolchain.env" 2>/dev/null | head -n 1)
  QEMU_MIN=${QEMU_MIN:-10.1}
fi
QEMU=${QEMU:-qemu-system-riscv64}
QEMU_MACHINE=${QEMU_MACHINE:-microchip-icicle-kit}
SMOKE_EXPECTED=${SMOKE_EXPECTED:-$here/smoke.expected}
SMOKE_TIMEOUT=${SMOKE_TIMEOUT:-20}

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

case "$SMOKE_TIMEOUT" in
  ''|*[!0-9]*) fail "SMOKE_TIMEOUT must be a whole number of seconds, got '$SMOKE_TIMEOUT'" ;;
esac

tab=$(printf '\t')
tmpd=$(mktemp -d "${TMPDIR:-/tmp}/smoke.XXXXXX") || fail "mktemp -d failed"
qpid=
wdog=
cleanup() {
  [ -n "$wdog" ] && kill "$wdog" 2>/dev/null
  [ -n "$qpid" ] && kill -9 "$qpid" 2>/dev/null
  rm -rf "$tmpd"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

#  --- the expectation file ---------------------------------------------------
[ -f "$SMOKE_EXPECTED" ] || fail "expectation file '$SMOKE_EXPECTED' does not exist"

#  Normalised rows: "image<TAB>string", comments, blanks and the header dropped.
#  awk, not a shell read loop, so a string with a backslash or leading space
#  survives untouched.
rows="$tmpd/rows"
awk -F'\t' '
  /^[ \t]*#/ || /^[ \t]*$/ { next }
  !hdr { hdr = 1; if ($1 != "image") { print "BADHEADER" > "/dev/stderr"; bad = 1 } ; next }
  NF != 2 || $1 == "" || $2 == "" { printf "BADROW\t%s\n", $0; bad = 1; next }
  { print }
  END { exit bad ? 1 : 0 }
' "$SMOKE_EXPECTED" > "$rows" 2> "$tmpd/awk.err"
if [ $? -ne 0 ]; then
  cat "$tmpd/awk.err" >&2
  grep '^BADROW' "$rows" | while IFS= read -r l; do printf '  %s\n' "$l" >&2; done
  fail "$SMOKE_EXPECTED is malformed: the first non-comment line must be the 'image<TAB>string' header, and every row needs both fields, TAB-separated"
fi
[ -s "$rows" ] || fail "$SMOKE_EXPECTED contains no expectations; an empty file would make this test pass vacuously"

apps=$(awk -F'\t' '!seen[$1]++ { print $1 }' "$rows")

#  --- QEMU: loud preconditions -------------------------------------------------
. "$here/qemu_preflight.sh"

#  --- boot each image --------------------------------------------------------
#  Does every expected string for $1 occur in console file $2?  Prints nothing.
all_present() {
  awk -F'\t' -v a="$1" '$1 == a { print $2 }' "$rows" | {
    while IFS= read -r needle; do
      grep -qF -- "$needle" "$2" || exit 1
    done
  }
}

failures=0
passed=0
n=0
for app in $apps; do
  #  The image column is a path relative to the repository root (or absolute).
  case "$app" in /*) img="$app" ;; *) img="$root/$app" ;; esac
  n=$((n + 1))
  printf '==> %s\n' "$app"
  if [ ! -f "$img" ]; then
    printf 'FAIL %s: image %s not found (run ./x build, or ./x test qemu which builds it)\n' "$app" "$img" >&2
    failures=$((failures + 1)); continue
  fi

  con="$tmpd/$n.console"; err="$tmpd/$n.stderr"
  : > "$con"
  #  QEMU parses the value after "file:" as a comma-separated option list, so a
  #  comma in the path has to be doubled.
  qcon=$(printf '%s' "$con" | sed 's/,/,,/g')
  "$QEMU" -M "$QEMU_MACHINE" -m 2G -display none -monitor none \
      -serial "file:$qcon" -bios none -kernel "$img" -no-reboot \
      </dev/null >"$err" 2>&1 &
  qpid=$!
  #  Poll for success so a passing boot ends in about a second; kill on expiry.
  (
    i=0
    while [ "$i" -lt "$SMOKE_TIMEOUT" ]; do
      all_present "$app" "$con" && break
      sleep 1
      i=$((i + 1))
    done
    kill -9 "$qpid" 2>/dev/null
  ) &
  wdog=$!
  wait "$qpid" 2>/dev/null
  qstatus=$?
  kill "$wdog" 2>/dev/null
  wait "$wdog" 2>/dev/null
  qpid=; wdog=

  missing=0
  while IFS= read -r needle; do
    if grep -qF -- "$needle" "$con"; then
      printf '    ok:      "%s"\n' "$needle"
    else
      printf '    MISSING: "%s"\n' "$needle" >&2
      missing=$((missing + 1))
    fi
  done <<EOF
$(awk -F'\t' -v a="$app" '$1 == a { print $2 }' "$rows")
EOF

  if [ "$missing" -ne 0 ]; then
    failures=$((failures + 1))
    printf 'FAIL %s: %d expected string(s) absent from the guest console (QEMU exit status %s; 137 = killed by the %ss watchdog)\n' \
      "$app" "$missing" "$qstatus" "$SMOKE_TIMEOUT" >&2
    nbytes=$(wc -c < "$con" | tr -d ' ')
    if [ "$nbytes" = 0 ]; then
      echo "  guest console: EMPTY -- the image booted (or failed to) and wrote nothing to MMUART0" >&2
    else
      echo "  guest console ($nbytes bytes), first 20 lines:" >&2
      head -n 20 "$con" | while IFS= read -r l; do printf '    | %s\n' "$l" >&2; done
    fi
    if [ -s "$err" ]; then
      echo "  QEMU stderr:" >&2
      head -n 20 "$err" | while IFS= read -r l; do printf '    | %s\n' "$l" >&2; done
    fi
  else
    passed=$((passed + 1))
  fi
done

if [ "$failures" -ne 0 ]; then
  printf 'smoke FAILED: %d of %d image(s) did not print what %s expects\n' \
    "$failures" "$((failures + passed))" "$SMOKE_EXPECTED" >&2
  exit 1
fi
printf 'smoke OK: %d image(s) printed every string %s expects\n' "$passed" "$SMOKE_EXPECTED"
