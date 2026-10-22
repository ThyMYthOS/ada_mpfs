#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Tests for the context switch and the trap frame of the runtime (crates/mpfs_rts: mpfs/gnarl/context_switch.S,
# mpfs/gnat/riscv_def.h), master plan #41 work package P1.5, on the disassembly of the real objects:
#
#   - U54 (-mabi=lp64d): __gnat_context_switch stores fs0 - fs11 with fsd to 112 + 8 * i (t0, the context of the
#     outgoing task) and loads them with fld from the same offsets from a1, the context of the INCOMING task. The
#     upstream file loads from t0 (defect no. 1 of the master plan): the same check run on a copy of the overlay
#     with t0 in the loads must FAIL, so that the check is not vacuous;
#   - E51 (-mabi=lp64): neither context_switch.o nor trap_handler.o has an instruction on an f register;
#   - the trap frame: 256 bytes (x1 - x31) on the E51, 512 bytes (x1 - x31 and f0 - f31) on the U54, every slot
#     of the save and of the restore inside the frame, 16-byte aligned frame; a soft-float ABI on a core with an
#     FPU gives the small frame too; a hard-float ABI without FLEN does not assemble (riscv_def.h);
#   - the overlay of context_switch.S differs from the upstream file in nothing but the header and the twelve
#     FLREG lines (t0 -> a1);
#   - the image of examples/fp_context_test has instructions on f registers only in the functions that are meant
#     to have them (the two helpers of the test, the context switch and the trap handler): nothing else keeps a
#     value in fs0 - fs11 between Load and Mismatch.
#
# Needs the pinned GNAT, zstd and GNU tar (the variants are built), skipped without them. The variants need the
# register package of the PAC, which is not committed: gen_runtime.sh runs tools/pac.sh ensure (the pinned svd2ada,
# ./x toolchain install pac, unless the package is there). Exits non-zero on any failure.

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

U54=(-march=rv64imafdc_zicsr_zifencei -mabi=lp64d)
E51=(-march=rv64imac_zicsr_zifencei -mabi=lp64)

# dis <object>: the instructions of an object, one per line, "<function>: <mnemonic> <operands>"
dis () {
  riscv64-elf-objdump -d --no-show-raw-insn "$1" | awk -F'\t' '
    /^[0-9a-f]+ <.*>:$/ { fn = $0; sub(/^[0-9a-f]+ </, "", fn); sub(/>:$/, "", fn); next }
    NF >= 3 && $2 != "" { sub(/ *#.*/, "", $3); print fn ": " $2 " " $3 }'
}

# ctx_check <object>: the callee-saved FP registers of a U54 context switch are saved to t0 and restored from a1.
# Prints what is wrong; status 0 if all is right.
ctx_check () {
  local o="$1" bad=0 want got
  want="$(for i in $(seq 0 11); do echo "__gnat_context_switch: fsd fs$i,$((112 + 8 * i))(t0)"; done)"
  got="$(dis "$o" | grep -E '^__gnat_context_switch: fsd ')"
  [ "$got" = "$want" ] || { echo "stores: wanted fsd fs0 - fs11 to 112 + 8 * i (t0); got: $got"; bad=1; }
  want="$(for i in $(seq 0 11); do echo "__gnat_context_switch: fld fs$i,$((112 + 8 * i))(a1)"; done)"
  got="$(dis "$o" | grep -E '^__gnat_context_switch: fld ')"
  [ "$got" = "$want" ] || { echo "loads: wanted fld fs0 - fs11 from 112 + 8 * i (a1); got: $got"; bad=1; }
  return $bad
}

# frame_check <object> <frame size> <number of f registers saved>: shape of the trap frame of trap_handler.o
frame_check () {
  local o="$1" size="$2" nf="$3" d bad=0 n m
  d="$(dis "$o")"
  printf '%s\n' "$d" | grep -qE ": addi tp,tp,-$size\$" \
    || { echo "no 'addi tp,tp,-$size' (the frame)"; bad=1; }
  printf '%s\n' "$d" | grep -qE ": addi t1,sp,$size\$" \
    || { echo "no 'addi t1,sp,$size' (the frame given back after a context switch)"; bad=1; }
  n="$(printf '%s\n' "$d" | grep -cE ': sd [a-z0-9]+,[0-9]+\(tp\)$')"
  [ "$n" = 30 ] || { echo "$n saves of an integer register (wanted 30: x1 - x3, x5 - x31)"; bad=1; }
  n="$(printf '%s\n' "$d" | grep -E ': ld [a-z0-9]+,[0-9]+\(tp\)$' | grep -vc ': ld tp,')"
  [ "$n" = 30 ] || { echo "$n restores of an integer register (wanted 30)"; bad=1; }
  n="$(printf '%s\n' "$d" | grep -cE ': fsd [a-z0-9]+,[0-9]+\(tp\)$')"
  m="$(printf '%s\n' "$d" | grep -cE ': fld [a-z0-9]+,[0-9]+\(tp\)$')"
  { [ "$n" = "$nf" ] && [ "$m" = "$nf" ]; } || { echo "$n saves and $m restores of an f register (wanted $nf)"; bad=1; }
  # every slot lies inside the frame, is 8-byte aligned, and no slot is used twice by the saves
  local offs max dup
  offs="$(printf '%s\n' "$d" | grep -E ': f?sd [a-z0-9]+,[0-9]+\(tp\)$' | sed -E 's/.*,([0-9]+)\(tp\)$/\1/')"
  max="$(printf '%s\n' "$offs" | sort -n | tail -1)"
  dup="$(printf '%s\n' "$offs" | sort -n | uniq -d | head -1)"
  [ -n "$max" ] && [ "$max" -lt "$size" ] || { echo "a save at $max is outside the $size-byte frame"; bad=1; }
  [ -z "$dup" ] || { echo "two saves to the slot $dup"; bad=1; }
  printf '%s\n' "$offs" | awk '$1 % 8 != 0 { exit 1 }' || { echo "a slot is not 8-byte aligned"; bad=1; }
  return $bad
}

# no_fp <object>: no instruction on an f register (the E51 has none)
no_fp () {
  dis "$1" | grep -E ': (fld|fsd|flw|fsw|fmv[.a-z]*|fcvt[.a-z]*|fadd[.a-z]*) ' | head -3
}

# -- the variants -------------------------------------------------------------------------------------------
for v in "light-tasking e51" "light-tasking u54" "embedded e51" "embedded u54"; do
  # shellcheck disable=SC2086
  bash "$GEN" $v 1 m >"$work/gen.out" 2>&1 || { cat "$work/gen.out" >&2; fail "gen_runtime.sh $v 1 m"; }
done

for dir in light-tasking-u54 embedded-u54 light-tasking-e51 embedded-e51; do
  d="$ROOT/build/rts/$dir-cpus1-m"
  mkdir -p "$work/$dir"
  ( cd "$work/$dir" && riscv64-elf-ar x "$d/adalib/libgnarl.a" context_switch.o trap_handler.o ) 2>"$work/ar.err" \
    || { fail "$dir: libgnarl.a has context_switch.o and trap_handler.o ($(cat "$work/ar.err"))"; continue; }
  case "$dir" in
    *-u54)
      out="$(ctx_check "$work/$dir/context_switch.o")" \
        && pass "$dir: fs0 - fs11 are saved to the context of the outgoing task (t0) and restored from the incoming one (a1)" \
        || fail "$dir: context switch of the callee-saved FP registers: $out"
      out="$(frame_check "$work/$dir/trap_handler.o" 512 32)" \
        && pass "$dir: the trap frame is 512 bytes: x1 - x31 and f0 - f31, every slot inside it" \
        || fail "$dir: trap frame: $out" ;;
    *-e51)
      out="$(no_fp "$work/$dir/context_switch.o")"
      [ -z "$out" ] && pass "$dir: context_switch.o has no instruction on an f register" \
        || fail "$dir: context_switch.o has instructions on f registers: $out"
      out="$(no_fp "$work/$dir/trap_handler.o")"
      [ -z "$out" ] && pass "$dir: trap_handler.o has no instruction on an f register" \
        || fail "$dir: trap_handler.o has instructions on f registers: $out"
      out="$(frame_check "$work/$dir/trap_handler.o" 256 0)" \
        && pass "$dir: the trap frame is 256 bytes: x1 - x31, every slot inside it" \
        || fail "$dir: trap frame: $out" ;;
  esac
done

# -- the control: the check fails on the upstream restore ---------------------------------------------------
inc="$ROOT/build/rts/light-tasking-u54-cpus1-m/adainclude"
sed -E '/FLREG/ s/\(a1\)/(t0)/' "$CRATE/mpfs/gnarl/context_switch.S" >"$work/context_switch_old.S"
if riscv64-elf-gcc -c -I"$inc" "${U54[@]}" -o "$work/old.o" "$work/context_switch_old.S" 2>"$work/old.err"; then
  out="$(ctx_check "$work/old.o")" \
    && fail "the upstream restore (fld from t0) passes the check: the check is vacuous" \
    || pass "the upstream restore (fld from t0) fails the check (defect no. 1)"
else
  fail "assembling the upstream restore ($(cat "$work/old.err"))"
fi
up="$ROOT/crates/bb-runtimes/riscv/src/context_switch.S"
if riscv64-elf-gcc -c -I"$inc" "${U54[@]}" -o "$work/up.o" "$up" 2>"$work/up.err"; then
  ctx_check "$work/up.o" >/dev/null \
    && fail "the upstream context_switch.S of the fork passes the check: the check is vacuous" \
    || pass "the upstream context_switch.S of the fork (crates/bb-runtimes) fails the check too"
else
  fail "assembling the upstream context_switch.S ($(cat "$work/up.err"))"
fi

# -- the overlay is the upstream file with the twelve loads changed ---------------------------------------
body () { awk '/^#include/ { on = 1 } on' "$1"; }
body "$up" | sed -E '/FLREG/ s/\(t0\)/(a1)/' >"$work/up.body"
body "$CRATE/mpfs/gnarl/context_switch.S" | grep -v 'a1 is the context of the incoming task' >"$work/ov.body"
if cmp -s "$work/up.body" "$work/ov.body"; then
  pass "context_switch.S differs from the upstream file in the header and the twelve FLREG lines only"
else
  fail "context_switch.S differs from the upstream file in more than the header and the FLREG lines"
  diff "$work/up.body" "$work/ov.body" | head -10 >&2
fi
n="$(grep -c 'FLREG fs[0-9]*, [0-9]*\*REGBYTES(a1)' "$CRATE/mpfs/gnarl/context_switch.S")"
[ "$n" = 12 ] && pass "context_switch.S: twelve FLREG from a1" || fail "context_switch.S: $n FLREG from a1 (wanted 12)"
grep -qE 'FLREG.*\(t0\)' "$CRATE/mpfs/gnarl/context_switch.S" \
  && fail "context_switch.S: an FLREG from t0 is left" || pass "context_switch.S: no FLREG from t0"

# -- riscv_def.h: the frame follows the ABI, a contradiction does not assemble ------------------------------
th="$inc/trap_handler.S"
asm () { riscv64-elf-gcc -c -I"$inc" "$@" -o "$work/x.o" "$th" 2>"$work/x.err"; }
if asm "${E51[@]}"; then
  out="$(frame_check "$work/x.o" 256 0)" && pass "rv64imac / lp64: 256-byte frame, no f registers" \
    || fail "rv64imac / lp64: $out"
else fail "assembling trap_handler.S for rv64imac / lp64 ($(cat "$work/x.err"))"; fi
if asm -march=rv64imafdc_zicsr_zifencei -mabi=lp64; then
  out="$(frame_check "$work/x.o" 256 0)" && pass "rv64imafdc / lp64 (soft ABI on a core with an FPU): 256-byte frame" \
    || fail "rv64imafdc / lp64: $out"
else fail "assembling trap_handler.S for rv64imafdc / lp64 ($(cat "$work/x.err"))"; fi
if asm "${U54[@]}"; then
  out="$(frame_check "$work/x.o" 512 32)" && pass "rv64imafdc / lp64d: 512-byte frame with f0 - f31" \
    || fail "rv64imafdc / lp64d: $out"
else fail "assembling trap_handler.S for rv64imafdc / lp64d ($(cat "$work/x.err"))"; fi
if asm "${U54[@]}" -U__riscv_flen; then
  fail "a hard-float ABI without FLEN assembles"
elif grep -q 'hard-float ABI without an FPU' "$work/x.err"; then
  pass "a hard-float ABI without FLEN does not assemble (error names the fault)"
else
  fail "a hard-float ABI without FLEN fails, but not with the message of riscv_def.h ($(head -3 "$work/x.err"))"
fi

# -- the image of fp_context_test keeps no value in fs0 - fs11 outside the test's own helpers -----------------
if "$ROOT/x" build fp_context_test --hart u54 >"$work/build.out" 2>&1; then
  img="$ROOT/examples/fp_context_test/bin-u54/fp_context_test.elf"
  users="$(dis "$img" | grep -E ': (fld|fsd|flw|fsw|fmv[.a-z]*|fcvt[.a-z]*|fadd[.a-z]*|fmul[.a-z]*|fsub[.a-z]*|fdiv[.a-z]*|fsqrt[.a-z]*) ' \
             | sed -E 's/: .*//' | sort -u)"
  strange="$(printf '%s\n' "$users" | grep -vE '^(fp_regs__load|fp_regs__mismatch|__gnat_context_switch|__gnat_trap_entry|[a-z_]*interrupted_context|[a-z_]*in_interrupt_stack)$')"
  [ -z "$strange" ] && pass "fp_context_test: f registers are used only by Fp_Regs, the context switch and the trap handler" \
    || fail "fp_context_test: f registers are used elsewhere too: $(echo $strange)"
  printf '%s\n' "$users" | grep -q '^fp_regs__load$' \
    && printf '%s\n' "$users" | grep -q '^fp_regs__mismatch$' \
    && pass "fp_context_test: Fp_Regs.Load and Fp_Regs.Mismatch are in the image" \
    || fail "fp_context_test: Fp_Regs.Load or Fp_Regs.Mismatch is not in the image ($(echo $users))"
else
  tail -5 "$work/build.out" >&2; fail "./x build fp_context_test --hart u54"
fi

echo "summary: $fails failure(s)"
[ $fails -eq 0 ]
