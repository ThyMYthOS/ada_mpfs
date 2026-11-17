#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Tests for the bring-up of the console of a primary image (crates/mpfs_rts: mpfs/gnat/s-textio.adb;
# examples/bare_hello/src/bare_console.adb): which images touch SYSREG, and in which order.
#
#   - the link: s-textio.o of the runtime reads __mpfs_boot_role (and the four console symbols), a bare image
#     is a primary image (__mpfs_boot_role = 1), and ./x build --role secondary gives the role 0;
#   - QEMU's register trace (-trace memory_region_ops_read/write, checked by check_trace.py) of the images:
#       * a primary image with __mpfs_console_init = 1 writes SYSREG.SUBBLK_CLOCK_CR (only the bit of its
#         MMUART: MMUART0 to MMUART4 and the MMUART1 of a U54 image) and then SYSREG.SOFT_RESET_CR (the bit
#         clear), 32-bit, before the first register of the port and so before the first data byte; the
#         second Initialize of textio_test repeats the pair, and the test still passes (a second
#         bring-up is harmless);
#       * Bare_Console (examples/bare_hello) does the same for MMUART0 on a primary image;
#       * a secondary image (the console of the runtime with init 1, Bare_Console, console none) and a
#         primary image with __mpfs_console_init = 0 make no access to SYSREG at all, and the first two
#         still print their verdict (QEMU does not fault on the accesses of the others either: the
#         primary images pass).
#
# The QEMU part is skipped when QEMU 10.1 or newer is missing (QEMU_MIN of tools/toolchain.env), the builds
# when the pinned GNAT, zstd or GNU tar is missing. Exits non-zero on any failure.
#
# @verifies RTS-026

set -u
export LC_ALL=C
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HERE="$ROOT/tests/host/rts_console_bringup"
fails=0

pass () { echo "ok:   $1"; }
fail () { echo "FAIL: $1" >&2; fails=$((fails + 1)); }
skip () { echo "skip: $1"; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

. "$ROOT/tools/mpfs-env.sh"
if ! mpfs_toolchain_on_path >/dev/null 2>&1; then
  skip "everything: the pinned toolchain is not installed (./x toolchain install gnat)"
  echo "all ok"; exit 0
fi
if ! command -v zstd >/dev/null 2>&1 || ! tar --version 2>&1 | grep -q 'GNU tar'; then
  skip "everything: zstd or GNU tar is not installed"
  echo "all ok"; exit 0
fi
mpfs_find_python
PY="$MPFS_PYTHON"

# QEMU: the version floor of the project
QEMU="${QEMU:-qemu-system-riscv64}"
qemu_ok=0
qemu_min="$(sed -n 's/^QEMU_MIN=//p' "$ROOT/tools/toolchain.env" | head -n 1)"
if command -v "$QEMU" >/dev/null 2>&1; then
  have="$("$QEMU" --version 2>&1 | sed -n '1s/.*version \([0-9]*\)\.\([0-9]*\).*/\1 \2/p')"
  # shellcheck disable=SC2086
  set -- $have
  if [ $# -eq 2 ] && { [ "$1" -gt "${qemu_min%%.*}" ] || { [ "$1" -eq "${qemu_min%%.*}" ] && [ "$2" -ge "${qemu_min#*.}" ]; }; }; then
    qemu_ok=1
  fi
fi
[ "$qemu_ok" = 1 ] || skip "the QEMU cases: QEMU $qemu_min or newer is not installed"

sym () {   # sym <elf> <name>: the value of a symbol, as nm prints it
  riscv64-elf-nm "$1" | awk -v n="$2" '$3 == n { print $1 }'
}
role_of () {   # role_of <elf>: __mpfs_boot_role as a number
  local v; v="$(sym "$1" __mpfs_boot_role)"; [ -n "$v" ] && echo $((16#$v)) || echo missing
}

# xbuild <log> <example> <hart> [./x build option ...]; the images stay in examples/<example>/bin-<hart>
xbuild () {
  local log="$1" exname="$2" hart="$3"; shift 3
  rm -rf "$ROOT/examples/$exname/obj-$hart" "$ROOT/examples/$exname/bin-$hart"
  "$ROOT/x" build "$exname" --hart "$hart" "$@" >"$log" 2>&1
}

# qrun <name> <elf> <regexp>: boots the image with the register trace; the serial ports are $work/<name>.s0 to
# .s4 and the trace $work/<name>.trace. Returns 0 if the regexp is on a port within 30 s.
qrun () {
  local name="$1" elf="$2" re="$3" pid i ok=1
  "$QEMU" -M microchip-icicle-kit -smp 5 -m 2G -display none -monitor none -bios none -kernel "$elf" -no-reboot \
    -serial "file:$work/$name.s0" -serial "file:$work/$name.s1" -serial "file:$work/$name.s2" \
    -serial "file:$work/$name.s3" -serial "file:$work/$name.s4" \
    -trace memory_region_ops_read -trace memory_region_ops_write -D "$work/$name.trace" \
    >"$work/$name.qemu" 2>&1 &
  pid=$!
  for i in $(seq 1 60); do
    if cat "$work/$name".s? 2>/dev/null | grep -Eq "$re"; then ok=0; break; fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.5
  done
  sleep 0.3
  kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  return $ok
}

# case_bringup <name> <elf> <MMUART n> <pairs> <verdict regexp> <what>
case_bringup () {
  local name="$1" elf="$2" n="$3" pairs="$4" re="$5" what="$6" msg
  if ! qrun "$name" "$elf" "$re"; then fail "$what: no verdict /$re/ under QEMU"; return; fi
  if msg="$("$PY" -I "$HERE/check_trace.py" "$work/$name.trace" bringup "$n" "$pairs" 2>&1)"; then
    pass "$what: $msg"
  else
    fail "$what: $msg"
  fi
}

# case_none <name> <elf> <verdict regexp> <what>
case_none () {
  local name="$1" elf="$2" re="$3" what="$4" msg
  if ! qrun "$name" "$elf" "$re"; then fail "$what: no verdict /$re/ under QEMU"; return; fi
  if msg="$("$PY" -I "$HERE/check_trace.py" "$work/$name.trace" none 2>&1)"; then
    pass "$what: $msg"
  else
    fail "$what: $msg"
  fi
}

tx="$ROOT/examples/textio_test"

# -- the link: the runtime reads the role ------------------------------------------------------------------
if bash "$ROOT/crates/mpfs_rts/gen_runtime.sh" light e51 1 m >"$work/gen.out" 2>&1; then
  rts="$ROOT/build/rts/light-e51-cpus1-m"
  mkdir -p "$work/textio-o"
  ( cd "$work/textio-o" && riscv64-elf-ar x "$rts/adalib/libgnat.a" s-textio.o )
  undef="$(riscv64-elf-nm -u "$work/textio-o/s-textio.o" 2>/dev/null)"
  for sy in __mpfs_boot_role __mpfs_console_base __mpfs_console_init; do
    echo "$undef" | grep -qw "$sy" && pass "s-textio.o refers to $sy" || fail "s-textio.o refers to $sy"
  done
  cmp -s "$ROOT/libs/mpfs_pac/src/generated/mpfs_registers-sysreg.ads" "$rts/adainclude/mpfs_registers-sysreg.ads" \
    && pass "adainclude/ has the register package MPFS_Registers.SYSREG of the PAC" \
    || fail "adainclude/ has the register package MPFS_Registers.SYSREG of the PAC"
else
  cat "$work/gen.out" >&2; fail "gen_runtime.sh light e51 1 m"
fi

# -- primary images --------------------------------------------------------------------------------------
if xbuild "$work/tx.log" textio_test e51; then
  mkdir -p "$work/img"
  cp "$tx"/bin-e51/*.elf "$work/img/"
  [ "$(role_of "$work/img/textio_test.elf")" = 1 ] && pass "textio_test: __mpfs_boot_role is 1 (primary, the default)" \
    || fail "textio_test: __mpfs_boot_role is 1 (primary, the default)"
  if [ "$qemu_ok" = 1 ]; then
    case_bringup tx_e51 "$work/img/textio_test.elf" 0 2 'TEST textio_test_e51: PASS' \
      "textio_test E51, primary, init 1: MMUART0, a second Initialize repeats the pair"
    for n in 1 2 3 4; do
      case_bringup "tx_m$n" "$work/img/console_mmuart${n}_test.elf" "$n" 1 "TEST console_mmuart${n}_test_e51: PASS" \
        "console_mmuart${n}_test E51, primary, init 1"
    done
    case_none tx_noinit "$work/img/console_noinit_test.elf" 'TEST console_noinit_test_e51: PASS' \
      "console_noinit_test E51, primary, init 0"
  fi
else
  fail "textio_test builds ($(tail -5 "$work/tx.log"))"
fi

if xbuild "$work/tx_u.log" textio_test u54; then
  mkdir -p "$work/img_u"
  cp "$tx"/bin-u54/textio_test.elf "$work/img_u/"
  [ "$qemu_ok" = 1 ] && case_bringup tx_u54 "$work/img_u/textio_test.elf" 1 2 'TEST textio_test_u54: PASS' \
    "textio_test U54 hart 1, primary, init 1: MMUART1 (bit 6 and no other)"
else
  fail "textio_test --hart u54 builds ($(tail -5 "$work/tx_u.log"))"
fi

# Bare_Console of the examples: bare_hello is a bare image, which is a primary image
if "$ROOT/x" build bare_hello --hart e51 >"$work/bh.log" 2>&1; then
  elf="$ROOT/examples/bare_hello/bin-e51/bare_hello.elf"
  [ "$(role_of "$elf")" = 1 ] && pass "bare_hello: __mpfs_boot_role is 1 (a bare image is a primary image)" \
    || fail "bare_hello: __mpfs_boot_role is 1 (a bare image is a primary image)"
  [ "$qemu_ok" = 1 ] && case_bringup bare "$elf" 0 1 'bare hello E51' "bare_hello E51 (Bare_Console), primary: MMUART0"
else
  fail "bare_hello builds ($(tail -5 "$work/bh.log"))"
fi

# trap_test links the runtime and reports through Bare_Console, whatever the console of the runtime
ex="$ROOT/examples/trap_test"
if xbuild "$work/trap.log" trap_test e51; then
  [ "$qemu_ok" = 1 ] && case_bringup trap "$ex/bin-e51/trap_test.elf" 0 1 'TEST trap_test_e51: PASS' \
    "trap_test E51 (Bare_Console over the runtime), primary: MMUART0, once"
else
  fail "trap_test builds ($(tail -5 "$work/trap.log"))"
fi

# -- secondary images and consoles that are none ------------------------------------------------------------
if xbuild "$work/tx_s.log" textio_test e51 --role secondary; then
  elf="$tx/bin-e51/textio_test.elf"
  [ "$(role_of "$elf")" = 0 ] && pass "textio_test --role secondary: __mpfs_boot_role is 0" \
    || fail "textio_test --role secondary: __mpfs_boot_role is 0"
  [ "$qemu_ok" = 1 ] && case_none tx_sec "$elf" 'TEST textio_test_e51: PASS' \
    "textio_test E51, secondary, init 1: the port is programmed, SYSREG is not touched"
else
  fail "textio_test --role secondary builds ($(tail -5 "$work/tx_s.log"))"
fi

if xbuild "$work/trap_s.log" trap_test u54 --harts 2 --role secondary; then
  elf="$ex/bin-u54-h2/trap_test.elf"
  [ -f "$elf" ] || elf="$ex/bin-u54/trap_test.elf"
  [ "$(role_of "$elf")" = 0 ] && pass "trap_test --role secondary: __mpfs_boot_role is 0" \
    || fail "trap_test --role secondary: __mpfs_boot_role is 0"
  [ "$qemu_ok" = 1 ] && case_none trap_sec "$elf" 'TEST trap_test_[a-z0-9]+: PASS' \
    "trap_test U54 hart 2 (Bare_Console), secondary: SYSREG is not touched"
else
  fail "trap_test --harts 2 --role secondary builds ($(tail -5 "$work/trap_s.log"))"
fi

if xbuild "$work/none.log" console_none_test e51 --role secondary; then
  [ "$qemu_ok" = 1 ] && case_none none_sec "$ROOT/examples/console_none_test/bin-e51/console_none_test.elf" \
    'TEST console_none_test_e51: PASS' "console_none_test E51, console none, init 1, secondary: SYSREG is not touched"
else
  fail "console_none_test --role secondary builds ($(tail -5 "$work/none.log"))"
fi

# Controls: the checker is not vacuous. The trace of a primary image is not "no SYSREG access", and the trace of a
# secondary image is not a bring-up; a bring-up of another MMUART or with another number of pairs is refused.
if [ "$qemu_ok" = 1 ] && [ -f "$work/tx_e51.trace" ] && [ -f "$work/tx_sec.trace" ]; then
  "$PY" -I "$HERE/check_trace.py" "$work/tx_e51.trace" none >/dev/null 2>&1 \
    && fail "control: the trace of a primary image passes as 'no access to SYSREG'" \
    || pass "control: the trace of a primary image is not 'no access to SYSREG'"
  "$PY" -I "$HERE/check_trace.py" "$work/tx_sec.trace" bringup 0 2 >/dev/null 2>&1 \
    && fail "control: the trace of a secondary image passes as a bring-up" \
    || pass "control: the trace of a secondary image is not a bring-up"
  "$PY" -I "$HERE/check_trace.py" "$work/tx_e51.trace" bringup 1 2 >/dev/null 2>&1 \
    && fail "control: the bring-up of MMUART0 passes as that of MMUART1" \
    || pass "control: the bring-up of MMUART0 is not that of MMUART1"
  "$PY" -I "$HERE/check_trace.py" "$work/tx_e51.trace" bringup 0 1 >/dev/null 2>&1 \
    && fail "control: two bring-ups pass as one" \
    || pass "control: two bring-ups are not one"
fi

rm -rf "$tx/obj-e51" "$tx/bin-e51" "$tx/obj-u54" "$tx/bin-u54" "$ROOT/examples/bare_hello/obj-e51" "$ROOT/examples/bare_hello/bin-e51" \
  "$ex/obj-e51" "$ex/bin-e51" "$ex"/obj-u54* "$ex"/bin-u54* "$ROOT/examples/console_none_test/obj-e51" "$ROOT/examples/console_none_test/bin-e51"

[ $fails -eq 0 ] || { echo "$fails failure(s)" >&2; exit 1; }
echo "all ok"
