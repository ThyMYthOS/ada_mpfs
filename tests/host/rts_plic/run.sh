#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Tests for the hart-indexed PLIC and CLINT of the runtime (crates/mpfs_rts: mpfs/gnarl/s-bbripl.ad[sb],
# s-bbricl.ad[sb], s-bbsuti.adb, s-bbhart.ad[sb], mpfs/gnat/s-bbbopa.ads), master plan #41 work package P1.4:
#
#   - tools/check_plic_stores.py, the disassembly check for a 64-bit store (sd, fsd, amo*.d, sc.d) in the
#     window 0x0C00_0000 - 0x1000_0000 of the PLIC, on fixtures: a store with a constant base, a base computed
#     from a hart number, a base that is set at the end of a loop, an atomic, a floating-point store and the
#     last page of the window must FAIL (the check is not vacuous); 32-bit accesses, stack stores, stores
#     outside the window and through a loaded value must PASS; an Ada aggregate assigned to an array of PLIC
#     registers, compiled with the real compiler against the runtime, must FAIL (this is the defect the check
#     is for); a missing file, a missing objdump and a file that is no object are errors (2), not passes;
#   - the six runtime variants: no 64-bit store into the window in libgnat.a, libgnarl.a or in the images of
#     interrupt_test and tasking_test; the units System.BB.RISCV_PLIC, .RISCV_CLINT and .Hart are in the
#     library; no hart literal (PLIC_Hart_Id, GDB_First_CPU_Id, the mtimecmp offset 16#4008#) is left in the
#     sources of a variant and the library defines no __gnat_gdb_cpu_first_id (the linker script does);
#   - the register packages of the PAC in adainclude/ are the files of libs/mpfs_pac byte for byte and are part
#     of the cache key of gen_runtime.sh; a missing one is refused.
#
# The builds are skipped when the pinned GNAT, zstd or GNU tar is missing. Exits non-zero on any failure.

set -u
export LC_ALL=C
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HERE="$ROOT/tests/host/rts_plic"
CRATE="$ROOT/crates/mpfs_rts"
GEN="$CRATE/gen_runtime.sh"
CHECK="$ROOT/tools/check_plic_stores.py"
PAC="$ROOT/libs/mpfs_pac/src/generated"
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
if ! command -v python3 >/dev/null 2>&1; then
  skip "everything: python3 is not installed"
  echo "summary: $fails failure(s)"; exit 0
fi

# check <expected exit status> <description> <arguments of check_plic_stores.py...>
check () {
  local want="$1" desc="$2"; shift 2
  local out rc
  out="$(python3 "$CHECK" "$@" 2>&1)"; rc=$?
  if [ "$rc" = "$want" ]; then pass "$desc"; else fail "$desc (exit $rc, wanted $want: $out)"; fi
  last_out="$out"
}

# -- the check on fixtures --------------------------------------------------------------------------
ARCH=(-march=rv64imafdc_zicsr_zifencei -mabi=lp64d)
for f in bad_const bad_dynamic bad_loop bad_amo bad_fsd bad_edge good; do
  riscv64-elf-gcc -c "${ARCH[@]}" -o "$work/$f.o" "$HERE/fixtures/$f.S" 2>"$work/$f.err" \
    || fail "assembling $f.S ($(cat "$work/$f.err"))"
done
last_out=""
check 1 "a store to a PLIC register with a constant base fails" "$work/bad_const.o"
case "$last_out" in *"fx: 0x4: sd a0,4(a5)"*) pass "  and names the function, the address and the store" ;;
  *) fail "  and names the function, the address and the store ($last_out)" ;; esac
check 1 "a store to the enable block of a context computed from a hart fails" "$work/bad_dynamic.o"
check 1 "a store whose base is set at the end of the loop fails (back edge)" "$work/bad_loop.o"
check 1 "a 64-bit atomic on a PLIC register fails" "$work/bad_amo.o"
check 1 "a 64-bit floating-point store to a PLIC register fails" "$work/bad_fsd.o"
check 1 "a store in the last page of the window fails" "$work/bad_edge.o"
check 0 "32-bit accesses, stack stores and stores outside the window pass" "$work/good.o"
check 0 "another window: the constant base is outside it" --lo 0x0D000000 --hi 0x0E000000 "$work/bad_const.o"
check 1 "a window that is just right: the edge store fails" --lo 0x0FFFF000 --hi 0x10000000 "$work/bad_edge.o"
check 1 "one failing file among passing ones fails" "$work/good.o" "$work/bad_const.o" "$work/good.o"
check 2 "a file that does not exist is an error" "$work/none.o"
check 2 "no objdump is an error" --objdump "$work/no-such-objdump" "$work/good.o"
echo "this is not an object" > "$work/garbage.o"
check 2 "a file that is no object is an error" "$work/garbage.o"
check 2 "no argument is an error (usage)"

# -- the variants -------------------------------------------------------------------------------
if ! command -v zstd >/dev/null 2>&1 || ! tar --version 2>&1 | grep -q 'GNU tar'; then
  skip "the variants: zstd or GNU tar is not installed"
  echo "summary: $fails failure(s)"; [ $fails -eq 0 ]; exit
fi
rts="$ROOT/build/rts"
for v in "light e51" "light u54" "light-tasking e51" "light-tasking u54" "embedded e51" "embedded u54"; do
  # shellcheck disable=SC2086
  bash "$GEN" $v 1 m >"$work/gen.out" 2>&1 || { cat "$work/gen.out" >&2; fail "gen_runtime.sh $v 1 m"; }
done

for dir in light-e51 light-u54 light-tasking-e51 light-tasking-u54 embedded-e51 embedded-u54; do
  d="$rts/$dir-cpus1-m"
  libs=("$d/adalib/libgnat.a")
  [ -f "$d/adalib/libgnarl.a" ] && libs+=("$d/adalib/libgnarl.a")
  check 0 "$dir: no 64-bit store into the PLIC window in the libraries" "${libs[@]}"
  # the PAC registers of the runtime are the files of the PAC
  same=1
  for f in mpfs_registers.ads mpfs_registers-plic.ads mpfs_registers-clint.ads; do
    cmp -s "$d/adainclude/$f" "$PAC/$f" || same=0
  done
  [ $same = 1 ] && pass "$dir: adainclude/ has the register packages of the PAC byte for byte" \
    || fail "$dir: adainclude/ has the register packages of the PAC byte for byte"
  # no hart literal left in the sources of the variant, and no exporter of the debugger's CPU id
  lits="$(cd "$d/adainclude" && grep -lE 'PLIC_Hart_Id|GDB_First_CPU_Id|16#4008#|CLINT_Mtimecmp_Offset' \
            s-bbbopa.ads s-bbbosu.adb s-bbpara.ads s-bbripl.ads s-bbripl.adb s-bbsuti.adb s-bbricl.adb s-bbhart.adb 2>/dev/null)"
  [ -z "$lits" ] && pass "$dir: no hart literal (PLIC_Hart_Id, GDB_First_CPU_Id, 16#4008#) in the board units" \
    || fail "$dir: no hart literal in the board units ($lits)"
  defs="$(for l in "${libs[@]}"; do riscv64-elf-nm -A --defined-only "$l" 2>/dev/null | grep ' __gnat_gdb_cpu_first_id$'; done)"
  [ -z "$defs" ] && pass "$dir: no library member defines __gnat_gdb_cpu_first_id (the linker script does)" \
    || fail "$dir: a library member defines __gnat_gdb_cpu_first_id ($defs)"
  case "$dir" in
    light-e51|light-u54) ;;
    *)
      members="$(riscv64-elf-ar t "$d/adalib/libgnarl.a")"
      for m in s-bbripl.o s-bbricl.o s-bbhart.o s-bbbosu.o; do
        echo "$members" | grep -qx "$m" && pass "$dir: libgnarl.a has $m" || fail "$dir: libgnarl.a has $m"
      done ;;
  esac
done

# -- the real compiler writes an aggregate with sd: the check must catch it --------------------------
cp "$HERE/fixtures/aggregate.adb" "$work/aggregate.adb"
if riscv64-elf-gcc -c -O2 -gnatp "${ARCH[@]}" --RTS="$rts/light-tasking-u54-cpus1-m" \
     -o "$work/aggregate.o" "$work/aggregate.adb" 2>"$work/aggregate.err"; then
  check 1 "an aggregate assigned to an array of PLIC registers (real compiler, -O2) fails" "$work/aggregate.o"
  n="$(printf '%s\n' "$last_out" | grep -c ': sd ')"
  [ "$n" -ge 1 ] && pass "  with the 64-bit stores listed ($n)" || fail "  with the 64-bit stores listed ($last_out)"
else
  fail "compiling the aggregate fixture ($(cat "$work/aggregate.err"))"
fi

# -- the images -----------------------------------------------------------------------------------
for t in interrupt_test tasking_test; do
  for opts in "--hart e51" "--hart u54" "--hart u54 --harts 3"; do
    # shellcheck disable=SC2086
    if "$ROOT/x" build $t $opts >"$work/build.out" 2>&1; then
      case "$opts" in *harts*) img="$ROOT/examples/$t/bin-u54-h3/$t.elf" ;; *e51) img="$ROOT/examples/$t/bin-e51/$t.elf" ;;
        *) img="$ROOT/examples/$t/bin-u54/$t.elf" ;; esac
      check 0 "$t ($opts): no 64-bit store into the PLIC window in the image" "$img"
    else
      tail -5 "$work/build.out" >&2; fail "./x build $t $opts"
    fi
  done
done

# -- the register packages are part of the cache key ---------------------------------------------
mkdir -p "$work/pac"
cp "$PAC"/mpfs_registers.ads "$PAC"/mpfs_registers-plic.ads "$PAC"/mpfs_registers-clint.ads "$work/pac/"
bash "$GEN" --check --pac-dir "$work/pac" light-tasking u54 1 m >/dev/null 2>&1; rc=$?
[ $rc -eq 0 ] && pass "a copy of the register packages: up to date" || fail "a copy of the register packages: up to date (exit $rc)"
echo "--  changed" >> "$work/pac/mpfs_registers-plic.ads"
bash "$GEN" --check --pac-dir "$work/pac" light-tasking u54 1 m >/dev/null 2>&1; rc=$?
[ $rc -eq 1 ] && pass "a changed register package: not up to date" || fail "a changed register package: not up to date (exit $rc)"
rm "$work/pac/mpfs_registers-clint.ads"
out="$(bash "$GEN" --pac-dir "$work/pac" light-tasking u54 1 m 2>&1)"; rc=$?
{ [ $rc -eq 2 ] && case "$out" in *"mpfs_registers-clint.ads"*) true ;; *) false ;; esac; } \
  && pass "a missing register package is refused and named" || fail "a missing register package is refused and named ($rc: $out)"

echo "summary: $fails failure(s)"
[ $fails -eq 0 ]
