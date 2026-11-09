#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Tests for the E51 specifics of the runtime (crates/mpfs_rts): the software floating point of the E51 and
# the local memories (ITIM and DTIM), issue #52.
#
#   - the E51 image of examples/float_test is a soft-float image (ABI lp64, no instruction on an f register,
#     a square root in it); the U54 image has fsqrt.d: the check is not vacuous. (The trap frame and the
#     context switch of the E51 are checked by tests/host/rts_context.)
#   - the runtime declares no section for the ITIM and DTIM: the linker script has no .fast_text and
#     .fast_data, and the image of an application without hook has both ranges empty (the defaults of
#     sections.ld) and no such section;
#   - the image of examples/itim_reject_test (the hook of an application that places code in the real
#     ITIM): the run address is in the ITIM of the E51, the load address in the LIM, start_fast.S has the check
#     (the local trap handler for mtvec, the pattern, fence.i);
#   - the image of examples/itim_test (code and data run from RAM, loaded elsewhere: what QEMU can run) is
#     linked as the hook defines it;
#   - negative links with the message that names the fault: a range that ends before it starts, a start
#     that is not a multiple of 8, a load address that is not, code in an ITIM of length 0, a hook without the switch
#     that pulls start_fast.S.
#
# What runs the images (the copy, the rejection) is ./x test qemu (itim_test_e51, itim_reject_test_e51).
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

sym () {   # sym <elf> <name>: the value of a symbol, as nm prints it
  riscv64-elf-nm "$1" | awk -v n="$2" '$3 == n { print $1 }'
}
num () { printf '%d' "$((16#${1:-0}))"; }

# -- the linker scripts declare no section for the local memories --------------------------------------
if grep -qE '^[[:space:]]*\.fast_(text|data)[[:space:]]*(:|ALIGN)' "$CRATE/ld/sections.ld"; then
  fail "sections.ld declares .fast_text or .fast_data (the application's hook does)"
else
  pass "sections.ld declares no .fast_text and no .fast_data"
fi
for f in mpfs-memory.ld place-lim.ld place-scratchpad.ld place-envm.ld app-sections.ld; do
  if grep -qE '^[[:space:]]*\.fast_(text|data)[[:space:]]*(:|ALIGN)' "$CRATE/ld/$f"; then
    fail "$f declares a section for the local memories"
  fi
done
[ "$(grep -cE '^[[:space:]]*[^[:space:]/*]' "$CRATE/ld/app-sections.ld")" = 0 ] \
  && pass "app-sections.ld of the runtime is empty (comments only)" || fail "app-sections.ld of the runtime is empty"

# -- the E51 is a soft-float image ------------------------------------------------------------------------
fp_insns () {   # fp_insns <elf>: the instructions on f registers of the disassembly
  riscv64-elf-objdump -d "$1" | grep -E '[[:space:]](c\.)?f(add|sub|mul|div|sqrt|min|max|cvt|mv|eq|lt|le|class|sgnj|madd|msub|nmadd|nmsub|l[wd]|s[wd])' || true
}
for hart in e51 u54; do
  if "$ROOT/x" build float_test --hart "$hart" >"$work/build-float.out" 2>&1; then
    elf="$ROOT/examples/float_test/bin-$hart/float_test.elf"
    flags="$(riscv64-elf-readelf -hW "$elf" | awk '/Flags/ { $1 = ""; print }')"
    n="$(fp_insns "$elf" | wc -l)"
    if [ "$hart" = e51 ]; then
      case "$flags" in *soft-float*) pass "float_test e51: soft-float ABI (lp64)";; *) fail "float_test e51: soft-float ABI ($flags)";; esac
      [ "$n" = 0 ] && pass "float_test e51: no instruction on an f register" \
        || fail "float_test e51: no instruction on an f register ($n found: $(fp_insns "$elf" | head -n 3))"
      [ -n "$(riscv64-elf-nm "$elf" | grep -i sqrt)" ] && pass "float_test e51: a square root is linked (software)" \
        || fail "float_test e51: a square root is linked"
    else
      case "$flags" in *double-float*) pass "float_test u54: double-float ABI (lp64d)";; *) fail "float_test u54: double-float ABI ($flags)";; esac
      fp_insns "$elf" | grep -q 'fsqrt\.d' && pass "float_test u54: fsqrt.d (the control: the check for f instructions can see them)" \
        || fail "float_test u54: fsqrt.d"
    fi
  else
    tail -5 "$work/build-float.out" >&2; fail "./x build float_test --hart $hart"
  fi
done

# -- an application without hook: both ranges empty, no such section ---------------------------------------
if "$ROOT/x" build trap_test --hart e51 >"$work/build.out" 2>&1; then
  elf="$ROOT/examples/trap_test/bin-e51/trap_test.elf"
  ds="$(sym "$elf" __data_start)"
  ok=1
  for k in text data; do
    [ "$(sym "$elf" "__fast_${k}_start")" = "$ds" ] && [ "$(sym "$elf" "__fast_${k}_end")" = "$ds" ] \
      && [ "$(sym "$elf" "__fast_${k}_load")" = "$ds" ] || ok=0
  done
  [ $ok = 1 ] && pass "no hook: __fast_{text,data}_{start,end,load} default to the start of .data (empty ranges)" \
    || fail "no hook: the defaults of the __fast_* symbols"
  [ -z "$(sym "$elf" __mpfs_start_fast)" ] && pass "no hook: the start code is start.S, without the check and copy step" \
    || fail "no hook: start_fast.S is in the image"
  riscv64-elf-readelf -SW "$elf" | grep -q '\.fast_' && fail "no hook: the image has a .fast_* section" \
    || pass "no hook: the image has no .fast_text and no .fast_data"
else
  tail -5 "$work/build.out" >&2; fail "./x build trap_test --hart e51"
fi

# -- the image that is rejected: code in the real ITIM ---------------------------------------------------
if "$ROOT/x" build itim_reject_test --hart e51 >"$work/build.out" 2>&1; then
  elf="$ROOT/examples/itim_reject_test/bin-e51/itim_reject_test.elf"
  st="$(sym "$elf" __fast_text_start)"; en="$(sym "$elf" __fast_text_end)"; ld="$(sym "$elf" __fast_text_load)"
  { [ "$(num "$st")" = $((0x01800000)) ] && [ "$(num "$en")" -gt "$(num "$st")" ] && [ "$(num "$en")" -le $((0x01802000)) ]; } \
    && pass "itim_reject_test: the code runs in the ITIM of the E51 ($st .. $en)" \
    || fail "itim_reject_test: the code runs in the ITIM of the E51 ($st .. $en)"
  { [ "$(num "$ld")" -ge $((0x08000000)) ] && [ "$(num "$ld")" -lt $((0x081e0000)) ]; } \
    && pass "itim_reject_test: the image holds the code in the LIM ($ld)" \
    || fail "itim_reject_test: the image holds the code in the LIM ($ld)"
  [ "$(( $(num "$st") & 7 ))" = 0 ] && [ "$(( $(num "$en") & 7 ))" = 0 ] && [ "$(( $(num "$ld") & 7 ))" = 0 ] \
    && pass "itim_reject_test: start, end and load address are multiples of 8" || fail "itim_reject_test: multiples of 8"
  riscv64-elf-readelf -lW "$elf" | awk '$1 == "LOAD" && $3 == "0x0000000001800000" { f = 1; p = $4 } END { exit !f }' \
    && pass "itim_reject_test: a loadable segment runs at the ITIM address" || fail "itim_reject_test: a segment at the ITIM address"
  [ "$(num "$(sym "$elf" __fast_data_start)")" = "$(num "$(sym "$elf" __fast_data_end)")" ] \
    && pass "itim_reject_test: the DTIM range is empty (nothing in .fast_data): nothing to check there" \
    || fail "itim_reject_test: the DTIM range is empty"
  [ "$(num "$(sym "$elf" _start)")" = $((0x08000000)) ] && pass "itim_reject_test: _start is first in the LIM" || fail "itim_reject_test: _start"

  # start_fast.S: the check is local code of _start with its own trap handler, and ends in fence.i
  riscv64-elf-objdump -d "$elf" >"$work/reject.dis"
  start="$(awk '/^[0-9a-f]+ <_start>:/ { on = 1; next } on && /^[0-9a-f]+ </ { exit } on' "$work/reject.dis")"
  n="$(printf '%s\n' "$start" | grep -cE '[[:space:]]csrw[[:space:]]+mtvec')"
  [ "$n" -ge 3 ] && pass "itim_reject_test: _start sets mtvec to the stub, to the check's handler and back ($n writes)" \
    || fail "itim_reject_test: mtvec writes in _start ($n)"
  printf '%s\n' "$start" | grep -qE '[[:space:]]fence\.i' && pass "itim_reject_test: _start executes fence.i after the copy" \
    || fail "itim_reject_test: fence.i in _start"
  [ -n "$(sym "$elf" __mpfs_start_fast)" ] && [ -n "$(sym "$elf" _start)" ] \
    && pass "itim_reject_test: the start code is start_fast.o (it defines __mpfs_start_fast)" \
    || fail "itim_reject_test: the start code is start_fast.o"
else
  tail -5 "$work/build.out" >&2; fail "./x build itim_reject_test --hart e51"
fi

# -- the image that is copied: code and data run elsewhere than they are loaded --------------------------
if "$ROOT/x" build itim_test --hart e51 >"$work/build.out" 2>&1; then
  elf="$ROOT/examples/itim_test/bin-e51/itim_test.elf"
  for k in text data; do
    st="$(sym "$elf" "__fast_${k}_start")"; en="$(sym "$elf" "__fast_${k}_end")"; ld="$(sym "$elf" "__fast_${k}_load")"
    { [ "$(num "$en")" -gt "$(num "$st")" ] && [ "$st" != "$ld" ] && [ "$(( ($(num "$st") | $(num "$en") | $(num "$ld")) & 7 ))" = 0 ]; } \
      && pass "itim_test: .fast_$k runs at $st and is loaded at $ld" || fail "itim_test: .fast_$k ($st $en $ld)"
    riscv64-elf-readelf -SW "$elf" | grep -q "\.fast_$k" && pass "itim_test: the image has .fast_$k (from the hook)" \
      || fail "itim_test: the image has .fast_$k"
  done
else
  tail -5 "$work/build.out" >&2; fail "./x build itim_test --hart e51"
fi

# -- the runtime directory has the fast start object, and no plain image uses it -------------------------
[ -f "$ROOT/build/rts/light-e51-cpus1-m/adalib/start_fast.o" ] && pass "adalib/start_fast.o is in the runtime directory" \
  || fail "adalib/start_fast.o is in the runtime directory"

# -- negative links ------------------------------------------------------------------------------------------
for v in "light e51"; do
  # shellcheck disable=SC2086
  bash "$GEN" $v 1 m >"$work/gen.out" 2>&1 || { cat "$work/gen.out" >&2; fail "gen_runtime.sh $v 1 m"; }
done
rts="$ROOT/build/rts"
tree="$work/tree"
mkdir -p "$tree/examples/bare_hello" "$tree/tests" "$tree/crates/mpfs_rts"
cp -r "$ROOT/examples/itim_reject_test" "$ROOT/examples/itim_test" "$tree/examples/"
cp -r "$ROOT/examples/bare_hello/src" "$tree/examples/bare_hello/"
cp -r "$ROOT/tests/common" "$tree/tests/"
cp "$CRATE/mpfs_rts.gpr" "$CRATE/mpfs_link.gpr" "$tree/crates/mpfs_rts/"
rm -rf "$tree/examples"/*/obj-* "$tree/examples"/*/bin-*
ex="$tree/examples/itim_reject_test"

# The partition of the copy: the link symbols of config/gen/standalone.py for the E51 with the ITIM and
# DTIM of the example (PARTITION_OPTS of its example.conf), read by Mpfs_Link as MPFS_DEFSYMS. The
# build of the copy is gprbuild itself, so the Ada checks of the partition do not run here.
mpfs_find_python
defsyms () {   # defsyms <generator option>...
  rm -rf "$work/part"
  "$MPFS_PYTHON" -I "$ROOT/config/gen/standalone.py" --hart e51 "$@" --output "$work/part/mpfs_partition.ads" || return 1
  sed -e '/^#/d' -e '/^$/d' -e 's/^/-Wl,--defsym=/' "$work/part/mpfs_partition.defsyms" | paste -sd";" -
}
itim_opts=(--itim-length 0x2000 --dtim-length 0x2000)
gpr () {   # gpr <log>: gprbuild of the copy with the partition of itim_opts
  ( cd "$ex" && env "MPFS_DEFSYMS=$(defsyms "${itim_opts[@]}")" gprbuild -q -p -f -P app.gpr "-XMPFS_RTS_ROOT=$rts" -XMPFS_HART=e51 -XMPFS_PROFILE=light -XMPFS_CPUS=1 -XMPFS_PRIV=m ) >"$1" 2>&1
}

# negative <name> <message>: build the copy and expect a failed link whose output has the message
negative () {
  local name="$1" msg="$2" log
  log="$work/neg-$name.log"
  rm -rf "$ex/obj-e51" "$ex/bin-e51"
  if gpr "$log"; then
    fail "negative $name: the link succeeded"
  elif grep -qF -- "$msg" "$log"; then
    pass "negative $name: the link fails with \"$msg\""
  else
    fail "negative $name: the link fails, but not with \"$msg\" ($(grep -E 'ld:|ASSERT|assert' "$log" | head -n 3))"
  fi
}
hook () { cat >"$ex/ld/app-sections.ld"; }   # the hook of the copy

hook <<'EOF'
	__fast_text_start = 0x01800008;
	__fast_text_end   = 0x01800000;
	__fast_text_load  = 0x08000000;
EOF
negative end_below_start "app-sections.ld: __fast_text_end or __fast_data_end lies below its start"

hook <<'EOF'
	__fast_text_start = 0x01800004;
	__fast_text_end   = 0x01800008;
	__fast_text_load  = 0x08000000;
EOF
negative start_not_8 "must be multiples of 8"

hook <<'EOF'
	__fast_data_start = 0x01000000;
	__fast_data_end   = 0x01000008;
	__fast_data_load  = 0x08000004;
EOF
negative load_not_8 "must be multiples of 8"

hook <<'EOF'
	__fast_text_start = 0x01800000;
	__fast_text_end   = 0x01800008;
	__fast_text_load  = 0x07000000;
EOF
negative load_below_text "a loadable section lies below .text"

# code in an ITIM of length 0 (the default of Mpfs_Link, no ITIM): the link fails instead of an image that crashes
cp "$ROOT/examples/itim_reject_test/ld/app-sections.ld" "$ex/ld/app-sections.ld"
itim_opts=(--itim-length 0 --dtim-length 0x2000)
negative itim_length_0 "region \`local_itim' overflowed"
itim_opts=(--itim-length 0x2000 --dtim-length 0x2000)

# a hook without the switch that pulls the check and copy step: the link fails instead of an image that never copies
sed -i 's/        & Mpfs_Link.Fast_Switches//' "$ex/app.gpr"
negative no_fast_start "the start code is start.S"

# the control: the unchanged copy links
cp "$ROOT/examples/itim_reject_test/app.gpr" "$ex/app.gpr"
rm -rf "$ex/obj-e51" "$ex/bin-e51"
if gpr "$work/control.log"; then
  pass "control: the copy of itim_reject_test with the real hook links"
else
  tail -5 "$work/control.log" >&2; fail "control: the copy with the real hook links"
fi

echo "summary: $fails failure(s)"
[ $fails -eq 0 ]
