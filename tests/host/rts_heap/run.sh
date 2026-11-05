#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Tests for the heap and the secondary stack of crates/mpfs_rts (the overlay overlays/tlsf, the defaults
# set by gen_runtime.sh):
#
#   - the TLSF allocator on the host: the sources of the runtime (Tlsf_Core and Tlsf_Math) built with
#     the native GNAT and assertions on, run with a stress and the cases of a 64-bit target (host/, adopted
#     from the allocator test of ada_esp32s3); a control with the refusal of a request above
#     Tlsf_Math.Max_Alloc taken out must fail it (it would index the tables out of range);
#   - the variants: only the embedded runtime has the heap units, light and light-tasking have none
#     (the bump allocator of light-tasking stays); libgnat.a of the embedded variants defines malloc, free,
#     realloc and calloc, once, in the object of MPFS_Heap, and the allocator has no elaboration code;
#     the body of the heap lock clears and sets mstatus.MIE; the default size of the secondary stack is
#     16 KiB (light), 8 KiB (light-tasking) and 16 KiB (embedded);
#   - an overlay has <profile>/gnat for that profile only (gen_runtime.sh);
#   - the images: heap_test and the images of exceptions_test define malloc and free once, from the
#     allocator of the runtime, and link nothing of the allocator of newlib; an image of light-tasking
#     has no allocator.
#
# That the heap works, and that the secondary stack has its sizes and overflows as it should, is the
# business of the QEMU tests (tests/qemu/tests.list: heap_test, secstack_test, secstack_tasking_test,
# secstack_light_test). Needs the pinned GNAT, zstd and GNU tar; skipped without them. The variants need
# the register package of the PAC, which is not committed: gen_runtime.sh runs tools/pac.sh ensure.
# Exits non-zero on any failure.

set -u
export LC_ALL=C
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CRATE="$ROOT/crates/mpfs_rts"
GEN="$CRATE/gen_runtime.sh"
OVERLAY="$CRATE/overlays/tlsf/embedded/gnat"
fails=0

pass () { echo "ok:   $1"; }
fail () { echo "FAIL: $1" >&2; fails=$((fails + 1)); }
skip () { echo "skip: $1"; }

work="$(mktemp -d)"
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT

. "$ROOT/tools/mpfs-env.sh"
if ! mpfs_toolchain_on_path >/dev/null 2>&1; then
  skip "everything: the pinned toolchain is not installed (./x toolchain install gnat)"
  echo "all ok"; exit 0
fi
if ! command -v zstd >/dev/null 2>&1 || ! tar --version 2>&1 | grep -q 'GNU tar'; then
  skip "everything: zstd or GNU tar is not installed"
  echo "all ok"; exit 0
fi

# -- the allocator on the host ----------------------------------------------------------------------
mkdir -p "$work/host"
cp -R "$ROOT/tests/host/rts_heap/host" "$ROOT/tests/host/common" "$work/host/"
# the project names the sources of the runtime relative to its place in the repository
sed -i "s|\"../../../../crates/mpfs_rts/overlays/tlsf/embedded/gnat\"|\"$OVERLAY\"|; s|\"../../common\"|\"../common\"|" \
  "$work/host/host/tlsf_host.gpr"
if gprbuild -q -p -P "$work/host/host/tlsf_host.gpr" >"$work/host.build" 2>&1; then
  "$work/host/host/bin/allocator_test" >"$work/host.out" 2>&1; rc=$?
  if [ $rc -eq 0 ] && grep -q '^TEST tlsf_host: PASS$' "$work/host.out"; then
    pass "TLSF host test: $(grep -c '^  ok:' "$work/host.out") checks, all ok"
  else
    tail -5 "$work/host.out" >&2; fail "TLSF host test (exit $rc)"
  fi
else
  cat "$work/host.build" >&2; fail "TLSF host test: the allocator builds natively"
fi

# the control: without the refusal of a request above Max_Alloc the test must fail
mkdir -p "$work/ctl/gnat" "$work/ctl/host"
cp "$OVERLAY"/tlsf_*.ad? "$work/ctl/gnat/"
sed -i "s/N > Max_Alloc/N > Storage_Count'Last - Align/" "$work/ctl/gnat/tlsf_core.adb"
if [ "$(grep -c "Storage_Count'Last - Align" "$work/ctl/gnat/tlsf_core.adb")" -ne 2 ]; then
  fail "control: the backstop of Allocate and Reallocate was found and taken out"
else
  cp -R "$work/host/host/src" "$work/ctl/host/src"
  cp -R "$work/host/common" "$work/ctl/common"
  sed "s|\"$OVERLAY\"|\"../gnat\"|; s|\"../common\"|\"../common\"|" "$work/host/host/tlsf_host.gpr" >"$work/ctl/host/tlsf_host.gpr"
  if gprbuild -q -p -P "$work/ctl/host/tlsf_host.gpr" >"$work/ctl.build" 2>&1; then
    "$work/ctl/host/bin/allocator_test" >"$work/ctl.out" 2>&1; rc=$?
    if [ $rc -ne 0 ]; then pass "control: without the refusal of a request above Max_Alloc the host test fails"
    else fail "control: without the refusal of a request above Max_Alloc the host test fails"; fi
  else
    cat "$work/ctl.build" >&2; fail "control: the allocator without the backstop builds"
  fi
fi

# -- the variants -----------------------------------------------------------------------------------
for v in "embedded e51" "embedded u54" "light e51" "light-tasking e51"; do
  # shellcheck disable=SC2086
  bash "$GEN" $v 1 m >"$work/gen.out" 2>&1 || { cat "$work/gen.out" >&2; fail "gen_runtime.sh $v 1 m"; }
done
rts="$ROOT/build/rts"
units="tlsf_core tlsf_math heap_guard mpfs_heap mpfs_heap_lock"
for hart in e51 u54; do
  d="$rts/embedded-$hart-cpus1-m"
  missing=""
  for u in $units; do
    [ -f "$d/adainclude/$u.ads" ] && [ -f "$d/adainclude/$u.adb" ] || missing="$missing $u"
  done
  [ -z "$missing" ] && pass "embedded-$hart: adainclude/ has the five units of the heap" \
    || fail "embedded-$hart: adainclude/ has the five units of the heap (missing:$missing)"
  for sym in malloc free realloc calloc; do
    defs="$(riscv64-elf-nm -A --defined-only "$d/adalib/libgnat.a" "$d/adalib/libgnarl.a" 2>/dev/null \
            | awk -v s="$sym" '$2 == "T" && $3 == s { print $1 }')"
    # one definition: the line has the library, the object and the address
    case "$defs" in
      "$d/adalib/libgnat.a:mpfs_heap.o:"*) pass "embedded-$hart: $sym is defined once, in mpfs_heap.o of libgnat.a" ;;
      *) fail "embedded-$hart: $sym is defined once, in mpfs_heap.o of libgnat.a (got: $defs)" ;;
    esac
  done
  # no elaboration code: nothing of the allocator is elaborated, and it is used before the units of
  # the program are
  els="$(riscv64-elf-nm "$d/adalib/libgnat.a" 2>/dev/null | grep -E '(tlsf_core|tlsf_math|heap_guard|mpfs_heap|mpfs_heap_lock)___elab' || true)"
  [ -z "$els" ] && pass "embedded-$hart: no unit of the heap has elaboration code" \
    || fail "embedded-$hart: no unit of the heap has elaboration code ($els)"
  # the lock: csrrci reads and clears mstatus.MIE, csrsi sets it
  dis="$(cd "$work" && rm -rf x && mkdir x && cd x && riscv64-elf-ar x "$d/adalib/libgnat.a" mpfs_heap_lock.o \
         && riscv64-elf-objdump -d mpfs_heap_lock.o)"
  if echo "$dis" | grep -qE 'csrrci[[:space:]]+[a-z0-9]+,mstatus,8' && echo "$dis" | grep -qE 'csrsi[[:space:]]+mstatus,8'; then
    pass "embedded-$hart: the heap lock clears mstatus.MIE (csrrci) and sets it again (csrsi)"
  else
    fail "embedded-$hart: the heap lock clears mstatus.MIE (csrrci) and sets it again (csrsi)"
  fi
  # the heap is the range of the linker script
  riscv64-elf-nm "$d/adalib/libgnat.a" 2>/dev/null | grep -q ' U __heap_start$' \
    && riscv64-elf-nm "$d/adalib/libgnat.a" 2>/dev/null | grep -q ' U __heap_end$' \
    && pass "embedded-$hart: the heap is __heap_start to __heap_end" || fail "embedded-$hart: the heap is __heap_start to __heap_end"
done
for v in light-e51 light-tasking-e51; do
  d="$rts/$v-cpus1-m"
  found=""
  for u in $units; do
    ls "$d"/adainclude/"$u".ad? >/dev/null 2>&1 && found="$found $u"
  done
  [ -z "$found" ] && pass "$v: no unit of the heap" || fail "$v: no unit of the heap (found:$found)"
  # the bump allocator of s-memory.o (light, light-tasking) is the only malloc
  defs="$(riscv64-elf-nm -A --defined-only "$d"/adalib/*.a 2>/dev/null | awk '$2 == "T" && $3 == "malloc" { print $1 }')"
  case "$defs" in
    "$d/adalib/libgnat.a:s-memory.o:"*) pass "$v: malloc is the bump allocator of s-memory.o" ;;
    *) fail "$v: malloc is the bump allocator of s-memory.o (got: $defs)" ;;
  esac
done

# the default size of the secondary stack of each profile
for spec in "light-e51:16" "light-tasking-e51:8" "embedded-e51:16" "embedded-u54:16"; do
  v="${spec%%:*}"; kib="${spec#*:}"
  grep -q "^   Runtime_Default_Sec_Stack_Size : constant Size_Type := $kib \* 1024;\$" "$rts/$v-cpus1-m/adainclude/s-parame.ads" \
    && pass "$v: the default secondary stack is $kib KiB" || fail "$v: the default secondary stack is $kib KiB"
done

# -- an overlay has <profile>/gnat for that profile only ----------------------------------------------
mkdir -p "$work/ov/10-test/light/gnat" "$work/ov/10-test/embedded/gnat" "$work/ov/10-test/light-tasking/gnarl"
echo "package ZZ_Light is end ZZ_Light;" > "$work/ov/10-test/light/gnat/zz_light.ads"
echo "package ZZ_Embedded is end ZZ_Embedded;" > "$work/ov/10-test/embedded/gnat/zz_embedded.ads"
echo "package ZZ_Tasking is end ZZ_Tasking;" > "$work/ov/10-test/light-tasking/gnarl/zz_tasking.ads"
if bash "$GEN" --out "$work/rts-ov" --overlay-dir "$work/ov" light e51 1 m >"$work/ov.out" 2>&1; then
  v="$work/rts-ov/light-e51-cpus1-m/adainclude"
  [ -f "$v/zz_light.ads" ] && pass "overlay: <profile>/gnat of the profile is in the variant" \
    || fail "overlay: <profile>/gnat of the profile is in the variant"
  [ ! -e "$v/zz_embedded.ads" ] && [ ! -e "$v/zz_tasking.ads" ] \
    && pass "overlay: <profile>/gnat and gnarl of other profiles are not" || fail "overlay: <profile>/gnat and gnarl of other profiles are not"
else
  tail -5 "$work/ov.out" >&2; fail "overlay: gen_runtime.sh light e51 with an overlay that has profile directories"
fi
bash "$GEN" --check --out "$work/rts-ov" --overlay-dir "$work/ov" light e51 1 m >/dev/null 2>&1; rc=$?
[ $rc -eq 0 ] && pass "overlay: the same overlay: up to date" || fail "overlay: the same overlay: up to date (exit $rc)"
echo "-- changed" >> "$work/ov/10-test/embedded/gnat/zz_embedded.ads"
bash "$GEN" --check --out "$work/rts-ov" --overlay-dir "$work/ov" light e51 1 m >/dev/null 2>&1; rc=$?
[ $rc -eq 0 ] && pass "overlay: a change in the directory of another profile leaves the variant up to date" \
  || fail "overlay: a change in the directory of another profile leaves the variant up to date (exit $rc)"
echo "-- changed" >> "$work/ov/10-test/light/gnat/zz_light.ads"
bash "$GEN" --check --out "$work/rts-ov" --overlay-dir "$work/ov" light e51 1 m >/dev/null 2>&1; rc=$?
[ $rc -eq 1 ] && pass "overlay: a changed file of a profile directory: not up to date" \
  || fail "overlay: a changed file of a profile directory: not up to date (exit $rc)"

# -- the images -------------------------------------------------------------------------------------
defs () {   # defs <elf> <symbol>: how many times a function of that name is defined
  riscv64-elf-nm --defined-only "$1" | awk -v s="$2" '$3 == s' | wc -l
}
image_checks () {   # image_checks <name> <elf>
  local name="$1" elf="$2" s
  [ "$(defs "$elf" malloc)" = 1 ] && [ "$(defs "$elf" free)" = 1 ] \
    && pass "$name: malloc and free are defined once" || fail "$name: malloc and free are defined once"
  [ -n "$(riscv64-elf-nm --defined-only "$elf" | awk '$3 == "tlsf_core__allocate"')" ] \
    && pass "$name: malloc is the TLSF allocator of the runtime" || fail "$name: malloc is the TLSF allocator of the runtime"
  # nothing of newlib's allocator (mallocr) or of its sbrk glue is linked
  s="$(riscv64-elf-nm --defined-only "$elf" | awk '$3 ~ /^(_malloc_r|_free_r|_realloc_r|_calloc_r|_sbrk|__malloc_lock|mallinfo)$/ { print $3 }' | tr '\n' ' ')"
  [ -z "$s" ] && pass "$name: nothing of newlib's allocator is linked" || fail "$name: newlib's allocator is linked ($s)"
}
for hart in e51 u54; do
  if "$ROOT/x" build heap_test --hart "$hart" >"$work/build.out" 2>&1; then
    image_checks "heap_test ($hart)" "$ROOT/examples/heap_test/bin-$hart/heap_test.elf"
  else
    tail -5 "$work/build.out" >&2; fail "./x build heap_test --hart $hart"
  fi
done
if "$ROOT/x" build exceptions_test --hart e51 >"$work/build.out" 2>&1; then
  image_checks "exceptions_test (e51)" "$ROOT/examples/exceptions_test/bin-e51/exceptions_test.elf"
else
  tail -5 "$work/build.out" >&2; fail "./x build exceptions_test --hart e51"
fi
if "$ROOT/x" build tasking_test --hart e51 >"$work/build.out" 2>&1; then
  elf="$ROOT/examples/tasking_test/bin-e51/tasking_test.elf"
  [ "$(defs "$elf" malloc)" = 0 ] && [ -z "$(riscv64-elf-nm --defined-only "$elf" | awk '$3 == "tlsf_core__allocate"')" ] \
    && pass "tasking_test (e51): the image of light-tasking has no allocator" \
    || fail "tasking_test (e51): the image of light-tasking has no allocator"
else
  tail -5 "$work/build.out" >&2; fail "./x build tasking_test --hart e51"
fi

echo "summary: $fails failure(s)"
[ $fails -eq 0 ]
