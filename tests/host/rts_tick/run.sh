#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Tests for the tick and the idle of the runtime (crates/mpfs_rts: mpfs/gnarl/s-bbsuti.adb, s-bbbosu.adb,
# s-bbricl.ad[sb], mpfs/gnat/s-bbbopa.ads), master plan #41 work package P1.6 (#47). What QEMU cannot decide
# (the accuracy of delay until, the power of wfi) is decided on the board (P1.14); what a host test can decide
# is decided here:
#
#   - the four tasking runtime variants: the idle task (System.Task_Primitives.Operations.Idle) executes wfi
#     (Power_Down is not the null procedure of the upstream unit), and the sources of the variant are the
#     port units;
#   - the CLINT accessors are one 64-bit access each: Mtime is a single ld, Set_Mtimecmp a single sd (no pair
#     of 32-bit accesses, whose intermediate value could raise or hide a timer interrupt);
#   - the image of delay_accuracy_test: Install_Alarm_Handler disarms mtimecmp (Set_Mtimecmp) BEFORE it
#     installs the handler, which sets mie.MTIE (a stale mtimecmp would raise a spurious tick); the alarm
#     handler acknowledges with Set_Mtimecmp; Clear_Alarm_Interrupt writes the maximum (all ones);
#   - Clock_Frequency = Clocks.Rtc_Toggle_Hz as a compile-time check (examples/delay_accuracy_test/src/
#     standalone_clocks.ads, the stand-in for the partition package of P1.12): a partition with 1 MHz
#     compiles, one with 2 MHz, 999 999 Hz or 100 MHz does not, with the message of the check; a runtime
#     whose Clock_Frequency is not 1 MHz (checked on a copy of the variant) fails the 1 MHz partition.
#
# The builds are skipped when the pinned GNAT, zstd or GNU tar is missing. Exits non-zero on any failure.

set -u
export LC_ALL=C
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CRATE="$ROOT/crates/mpfs_rts"
GEN="$CRATE/gen_runtime.sh"
fails=0

pass () { echo "ok:   $1"; }
fail () { echo "FAIL: $1" >&2; fails=$((fails + 1)); }
skip () { echo "skip: $1"; }

work="$(mktemp -d)"
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT

. "$ROOT/tools/mpfs-env.sh"
if ! mpfs_toolchain_on_path >/dev/null 2>&1; then
  skip "everything: the pinned toolchain is not installed (./x toolchain install gnat)"
  echo "summary: $fails failure(s)"; exit 0
fi
if ! command -v zstd >/dev/null 2>&1 || ! tar --version 2>&1 | grep -q 'GNU tar'; then
  skip "everything: zstd or GNU tar is not installed"
  echo "summary: $fails failure(s)"; exit 0
fi

rts="$ROOT/build/rts"
for v in "light-tasking e51" "light-tasking u54" "embedded e51" "embedded u54"; do
  # shellcheck disable=SC2086
  bash "$GEN" $v 1 m >"$work/gen.out" 2>&1 || { cat "$work/gen.out" >&2; fail "gen_runtime.sh $v 1 m"; }
done

# body <disassembly file> <function name>: the instructions of one function
# (up to the next symbol or section; local labels such as .L24 belong to the function)
body () { awk -v f="<$2>:" 'index($0, f) { on = 1; next } on && (/^Disassembly/ || /^[0-9a-f]+ <[^.]/) { exit } on' "$1"; }

# -- the runtime variants -------------------------------------------------------------------------------
for dir in light-tasking-e51 light-tasking-u54 embedded-e51 embedded-u54; do
  d="$rts/$dir-cpus1-m"
  riscv64-elf-objdump -d "$d/adalib/libgnarl.a" >"$work/$dir.dis" 2>/dev/null
  idle="$(body "$work/$dir.dis" system__task_primitives__operations__idle)"
  if [ -n "$idle" ] && printf '%s\n' "$idle" | grep -qE '[[:space:]]wfi$'; then
    pass "$dir: the idle task executes wfi"
  else
    fail "$dir: the idle task executes wfi ($(printf '%s' "$idle" | head -n 20))"
  fi
  n="$(grep -cE '[[:space:]]wfi$' "$work/$dir.dis")"
  [ "$n" -ge 1 ] && pass "$dir: libgnarl.a has wfi (Power_Down is inlined into the idle task)" \
    || fail "$dir: libgnarl.a has wfi (found $n)"
  cmp -s "$CRATE/mpfs/gnarl/s-bbbosu.adb" "$d/adainclude/s-bbbosu.adb" \
    && pass "$dir: s-bbbosu.adb of the variant is the port unit (not the null Power_Down of the upstream unit)" \
    || fail "$dir: s-bbbosu.adb of the variant is the port unit"
  cmp -s "$CRATE/mpfs/gnarl/s-bbsuti.adb" "$d/adainclude/s-bbsuti.adb" \
    && pass "$dir: s-bbsuti.adb of the variant is the port unit" || fail "$dir: s-bbsuti.adb of the variant is the port unit"

  # one 64-bit access per register access
  mt="$(body "$work/$dir.dis" system__bb__riscv_clint__mtime)"
  nld="$(printf '%s\n' "$mt" | grep -cE '[[:space:]]ld[[:space:]]')"
  nother="$(printf '%s\n' "$mt" | grep -cE '[[:space:]](lw|lwu|lh|lhu|lb|lbu|c\.lw)[[:space:]]')"
  [ "$nld" = 1 ] && [ "$nother" = 0 ] && pass "$dir: Mtime is one 64-bit load" \
    || fail "$dir: Mtime is one 64-bit load (ld: $nld, narrower: $nother: $mt)"
  sc="$(body "$work/$dir.dis" system__bb__riscv_clint__set_mtimecmp)"
  nsd="$(printf '%s\n' "$sc" | grep -cE '[[:space:]](sd|c\.sd|c\.sdsp)[[:space:]]')"
  nother="$(printf '%s\n' "$sc" | grep -cE '[[:space:]](sw|sh|sb|c\.sw|c\.swsp)[[:space:]]')"
  [ "$nsd" = 1 ] && [ "$nother" = 0 ] && pass "$dir: Set_Mtimecmp is one 64-bit store" \
    || fail "$dir: Set_Mtimecmp is one 64-bit store (sd: $nsd, narrower: $nother: $sc)"
done

# -- the image: the order in Install_Alarm_Handler and the maximum --------------------------------------
for hart in e51 u54; do
  if "$ROOT/x" build delay_accuracy_test --hart "$hart" >"$work/build.out" 2>&1; then
    img="$ROOT/examples/delay_accuracy_test/bin-$hart/delay_accuracy_test.elf"
    riscv64-elf-objdump -d "$img" >"$work/img-$hart.dis" 2>/dev/null
    ia="$(body "$work/img-$hart.dis" system__bb__board_support__time__install_alarm_handler)"
    first="$(printf '%s\n' "$ia" | grep -nE 'set_mtimecmp|install_trap_handler' | head -n 1)"
    case "$first" in
      *set_mtimecmp*) pass "$hart image: Install_Alarm_Handler disarms mtimecmp before it installs the handler (MTIE)" ;;
      *) fail "$hart image: Install_Alarm_Handler disarms mtimecmp before it installs the handler ($ia)" ;;
    esac
    printf '%s\n' "$ia" | grep -qE 'li[[:space:]]+a1,-1$' \
      && pass "$hart image: the value written is the maximum (a1 = -1)" \
      || fail "$hart image: the value written is the maximum ($ia)"
    ah="$(body "$work/img-$hart.dis" system__bb__time__alarm_handler)"
    printf '%s\n' "$ah" | grep -qE 'li[[:space:]]+a1,-1$' && printf '%s\n' "$ah" | grep -q 'set_mtimecmp' \
      && pass "$hart image: the alarm handler acknowledges with the maximum before it runs any handler" \
      || fail "$hart image: the alarm handler acknowledges with the maximum ($ah)"
  else
    tail -5 "$work/build.out" >&2; fail "./x build delay_accuracy_test --hart $hart"
  fi
done

# -- Clock_Frequency against Clocks.Rtc_Toggle_Hz, at compile time -----------------------------------------
clk="$ROOT/examples/delay_accuracy_test/src/standalone_clocks.ads"
ARCH=(-march=rv64imafdc_zicsr_zifencei -mabi=lp64d)
try_clock () { # <Rtc_Toggle_Hz literal> <runtime dir>: compile the stand-in with that frequency, output in $work/clk.err
  mkdir -p "$work/clk"
  sed "s/Rtc_Toggle_Hz : constant := 1_000_000;/Rtc_Toggle_Hz : constant := $1;/" "$clk" >"$work/clk/standalone_clocks.ads"
  (cd "$work/clk" && riscv64-elf-gcc -c "${ARCH[@]}" --RTS="$2" standalone_clocks.ads) 2>"$work/clk.err"
}
grep -q 'Rtc_Toggle_Hz : constant := 1_000_000;' "$clk" && pass "the stand-in has the standalone default 1 MHz" \
  || fail "the stand-in has the standalone default 1 MHz"
for dir in light-tasking-u54 embedded-e51; do
  d="$rts/$dir-cpus1-m"
  if try_clock 1_000_000 "$d"; then pass "$dir: a partition with Rtc_Toggle_Hz = 1 MHz compiles"
  else fail "$dir: a partition with Rtc_Toggle_Hz = 1 MHz compiles ($(cat "$work/clk.err"))"; fi
  for hz in 2_000_000 999_999 100_000_000 32_768; do
    if try_clock "$hz" "$d"; then
      fail "$dir: a partition with Rtc_Toggle_Hz = $hz is rejected"
    elif grep -q 'Clock_Frequency of the runtime is not Clocks.Rtc_Toggle_Hz' "$work/clk.err"; then
      pass "$dir: a partition with Rtc_Toggle_Hz = $hz is rejected with the message of the check"
    else
      fail "$dir: a partition with Rtc_Toggle_Hz = $hz is rejected with the message of the check ($(cat "$work/clk.err"))"
    fi
  done
done

# the other way round: the partition says 1 MHz, the runtime has another Clock_Frequency (a copy of the variant)
cp -r "$rts/light-tasking-u54-cpus1-m" "$work/rts-2mhz"
chmod -R u+w "$work/rts-2mhz"
rm -f "$work/rts-2mhz"/adainclude/s-bbbopa.ad? "$work/rts-2mhz"/adalib/s-bbbopa.ali "$work/rts-2mhz"/adalib/a-reatim.ali \
  "$work/rts-2mhz"/adalib/s-bbpara.ali
sed 's/Decrementer_Frequency : constant Positive := 1_000_000;/Decrementer_Frequency : constant Positive := 2_000_000;/' \
  "$rts/light-tasking-u54-cpus1-m/adainclude/s-bbbopa.ads" >"$work/rts-2mhz/adainclude/s-bbbopa.ads"
if grep -q '2_000_000' "$work/rts-2mhz/adainclude/s-bbbopa.ads"; then
  if try_clock 1_000_000 "$work/rts-2mhz"; then
    fail "a runtime whose Clock_Frequency is 2 MHz is rejected by the 1 MHz partition"
  elif grep -q 'Clock_Frequency of the runtime is not Clocks.Rtc_Toggle_Hz' "$work/clk.err"; then
    pass "a runtime whose Clock_Frequency is 2 MHz is rejected by the 1 MHz partition"
  else
    fail "a runtime whose Clock_Frequency is 2 MHz is rejected by the 1 MHz partition ($(cat "$work/clk.err"))"
  fi
else
  fail "the copy of the runtime has a Clock_Frequency of 2 MHz"
fi

echo "summary: $fails failure(s)"
[ $fails -eq 0 ]
