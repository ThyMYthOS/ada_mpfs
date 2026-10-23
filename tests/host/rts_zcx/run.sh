#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Tests for the zero-cost exceptions of the embedded runtime (crates/mpfs_rts: link-zcx.spec,
# mpfs/remove.list, mpfs/gnat/start.S, ld/sections.ld), master plan #41 work package P1.7 (R8):
#
#   - the premise: the linker of the pinned toolchain does not know --eh-frame-hdr (if it ever does,
#     the decision of P1.7 is to be revisited, so this fails);
#   - link-zcx.spec: no --eh-frame-hdr, crtbegin.o and crtend.o around the link, -u
#     __register_frame_info; the variant of the embedded profile has exactly this file, the others
#     have none; the spec is part of the cache key, a missing one is refused for the embedded
#     profile only; the bb unwinder (unwind-dw2-fde-bb) is in neither the library nor the sources
#     of the embedded variant, "<profile>: <path>" of mpfs/remove.list applies to that profile only;
#   - the images of examples/exceptions_test (E51 and U54): no .eh_frame_hdr, _Unwind_Find_FDE and
#     __register_frame_info are linked (from libgcc), frame_dummy of crtbegin.o is the entry of
#     .init_array (and the only one of unhandled_test), .eh_frame is bracketed by __eh_frame_start
#     and __eh_frame_end, __EH_FRAME_BEGIN__ of crtbegin.o is its start, the zero word follows;
#   - an image of the light runtime (examples/trap_test) has none of this: no frame_dummy, no
#     registration, empty constructor arrays.
#
# That the exceptions are propagated is the business of the QEMU tests (tests/qemu/tests.list:
# exceptions_test, unhandled_test, unhandled_task_test). Needs the pinned GNAT, zstd and GNU tar;
# skipped without them. Exits non-zero on any failure.

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
  echo "all ok"; exit 0
fi
if ! command -v zstd >/dev/null 2>&1 || ! tar --version 2>&1 | grep -q 'GNU tar'; then
  skip "everything: zstd or GNU tar is not installed"
  echo "all ok"; exit 0
fi

sym () {   # sym <elf> <name>: the value of a symbol, as nm prints it
  riscv64-elf-nm "$1" | awk -v n="$2" '$3 == n { print $1 }'
}
sec () {   # sec <elf> <section> <field>: field 3 (size) or 4 (address) of objdump -h, "" if absent
  riscv64-elf-objdump -h -j "$2" "$1" 2>/dev/null | awk -v s="$2" -v f="$3" '$2 == s { print $f }'
}
num () { echo $(( 16#${1:-0} )); }

# -- the premise ------------------------------------------------------------------------------------
out="$(riscv64-elf-ld --eh-frame-hdr 2>&1)"
case "$out" in
  *"unrecognized option"*) pass "the linker does not know --eh-frame-hdr (the premise of link-zcx.spec)" ;;
  *) fail "the linker does not know --eh-frame-hdr: it does now ($out), revisit R8 (P1.7)" ;;
esac

# -- the spec ---------------------------------------------------------------------------------------
spec="$CRATE/link-zcx.spec"
body="$(grep -v '^[[:space:]]*#' "$spec")"
case "$body" in *eh-frame-hdr*) fail "link-zcx.spec passes --eh-frame-hdr" ;; *) pass "link-zcx.spec does not pass --eh-frame-hdr" ;; esac
case "$body" in *"crtbegin.o%s"*) pass "link-zcx.spec links crtbegin.o" ;; *) fail "link-zcx.spec links crtbegin.o" ;; esac
case "$body" in *"crtend.o%s"*) pass "link-zcx.spec links crtend.o" ;; *) fail "link-zcx.spec links crtend.o" ;; esac
case "$body" in *"-u __register_frame_info"*) pass "link-zcx.spec forces __register_frame_info (libgcc's unwind-dw2-fde.o)" ;;
  *) fail "link-zcx.spec forces __register_frame_info" ;; esac
printf '%s\n' "$body" | awk '/^\*startfile:/ { s = 1 } /^\*endfile:/ { s = 2 } s == 1 && /crtbegin/ { b = NR } s == 2 && /crtend/ { e = NR } END { exit !(b && e) }' \
  && pass "crtbegin.o is in *startfile and crtend.o in *endfile" || fail "crtbegin.o is in *startfile and crtend.o in *endfile"

# -- the variants -----------------------------------------------------------------------------------
for v in "embedded e51" "embedded u54" "light e51"; do
  # shellcheck disable=SC2086
  bash "$GEN" $v 1 m >"$work/gen.out" 2>&1 || { cat "$work/gen.out" >&2; fail "gen_runtime.sh $v 1 m"; }
done
rts="$ROOT/build/rts"
for hart in e51 u54; do
  dir="$rts/embedded-$hart-cpus1-m"
  cmp -s "$dir/link-zcx.spec" "$spec" && pass "embedded-$hart: link-zcx.spec is the one of crates/mpfs_rts" \
    || fail "embedded-$hart: link-zcx.spec is the one of crates/mpfs_rts"
  grep -q 'link-zcx.spec' "$dir/runtime.xml" && pass "embedded-$hart: runtime.xml links with it" || fail "embedded-$hart: runtime.xml links with it"
  members="$(riscv64-elf-ar t "$dir/adalib/libgnat.a")"
  echo "$members" | grep -q '^unwind-dw2-fde-bb' && fail "embedded-$hart: libgnat.a has the bb unwinder" \
    || pass "embedded-$hart: libgnat.a has no bb unwinder (unwind-dw2-fde-bb)"
  [ ! -e "$dir/adainclude/unwind-dw2-fde-bb.c" ] && pass "embedded-$hart: adainclude/ has no unwind-dw2-fde-bb.c" \
    || fail "embedded-$hart: adainclude/ has no unwind-dw2-fde-bb.c"
  echo "$members" | grep -qx 'raise-gcc.o' && pass "embedded-$hart: libgnat.a has raise-gcc.o" || fail "embedded-$hart: libgnat.a has raise-gcc.o"
done
[ ! -e "$rts/light-e51-cpus1-m/link-zcx.spec" ] && pass "light-e51: no link spec" || fail "light-e51: no link spec"

# the spec is part of the cache key
bash "$GEN" --check --spec "$spec" embedded u54 1 m >/dev/null 2>&1; rc=$?
[ $rc -eq 0 ] && pass "the committed spec: up to date" || fail "the committed spec: up to date (exit $rc)"
cp "$spec" "$work/other.spec"; echo "# changed" >> "$work/other.spec"
bash "$GEN" --check --spec "$work/other.spec" embedded u54 1 m >/dev/null 2>&1; rc=$?
[ $rc -eq 1 ] && pass "another spec: not up to date" || fail "another spec: not up to date (exit $rc)"
bash "$GEN" --check --spec "$work/other.spec" light e51 1 m >/dev/null 2>&1; rc=$?
[ $rc -eq 0 ] && pass "another spec does not touch a profile without one (light)" || fail "another spec does not touch a profile without one (light, exit $rc)"
out="$(bash "$GEN" --out "$work/rts-bad" --spec "$work/none.spec" embedded u54 1 m 2>&1)"; rc=$?
{ [ $rc -eq 2 ] && case "$out" in *"no link spec"*) true ;; *) false ;; esac; } \
  && pass "a missing spec is refused for the embedded profile" || fail "a missing spec is refused for the embedded profile ($rc: $out)"

# "<profile>: <path>" of remove.list: refused for its profile when the pack has no such file
mkdir -p "$work/port/gnat"
cp "$CRATE/mpfs/gnat/start.S" "$work/port/gnat/"
echo "embedded: gnat/no-such-file.c" > "$work/port/remove.list"
out="$(bash "$GEN" --out "$work/rts-bad" --port-dir "$work/port" embedded e51 1 m 2>&1)"; rc=$?
{ [ $rc -eq 2 ] && case "$out" in *"has no gnat/no-such-file.c"*) true ;; *) false ;; esac; } \
  && pass "remove.list: a line for the profile is applied (and refused: no such file)" \
  || fail "remove.list: a line for the profile is applied (and refused: no such file) ($rc: $out)"

# -- the images of the embedded runtime -----------------------------------------------------------------
image_checks () {   # image_checks <name> <elf> <init array entries> <preinit array entries>
  local name="$1" elf="$2" entries="$3" pre="$4" got ia_s ia_e addr size st en b
  [ -z "$(sec "$elf" .eh_frame_hdr 3)" ] && pass "$name: no .eh_frame_hdr" || fail "$name: no .eh_frame_hdr"
  [ -n "$(sym "$elf" _Unwind_Find_FDE)" ] && pass "$name: _Unwind_Find_FDE is linked" || fail "$name: _Unwind_Find_FDE is linked"
  [ -n "$(sym "$elf" __register_frame_info)" ] && pass "$name: __register_frame_info is linked (libgcc)" \
    || fail "$name: __register_frame_info is linked (libgcc)"
  # the unwinder is libgcc's: its object has the registration functions next to _Unwind_Find_FDE
  [ -n "$(sym "$elf" __deregister_frame_info)" ] && pass "$name: the registration functions of unwind-dw2-fde.o are linked" \
    || fail "$name: the registration functions of unwind-dw2-fde.o are linked"
  # the constructor array: bracketed, frame_dummy first
  ia_s="$(sym "$elf" __init_array_start)"; ia_e="$(sym "$elf" __init_array_end)"
  addr="$(sec "$elf" .init_array 4)"; size="$(sec "$elf" .init_array 3)"
  { [ "$(num "$ia_s")" = "$(num "$addr")" ] && [ "$(( $(num "$ia_e") - $(num "$ia_s") ))" = $(( entries * 8 )) ] \
      && [ "$(num "$size")" = $(( entries * 8 )) ]; } \
    && pass "$name: .init_array has $entries entries between __init_array_start and __init_array_end" \
    || fail "$name: .init_array has $entries entries between __init_array_start and __init_array_end ($ia_s $ia_e $addr $size)"
  got="$(riscv64-elf-objdump -s -j .init_array "$elf" | awk '/^ [0-9a-f]+ / { print $2 " " $3 }' | head -1)"
  b="$(sym "$elf" frame_dummy | sed -E 's/^.{8}(..)(..)(..)(..)$/\4\3\2\1/') 00000000"
  [ "$got" = "$b" ] && pass "$name: the first entry of .init_array is frame_dummy of crtbegin.o" \
    || fail "$name: the first entry of .init_array is frame_dummy of crtbegin.o ($got, wanted $b)"
  [ "$(( $(num "$(sym "$elf" __preinit_array_end)") - $(num "$(sym "$elf" __preinit_array_start)") ))" = $(( pre * 8 )) ] \
    && pass "$name: .preinit_array has $pre entries" || fail "$name: .preinit_array has $pre entries"
  # .eh_frame: bracketed, crtbegin.o's __EH_FRAME_BEGIN__ is the start, zero words end it
  addr="$(sec "$elf" .eh_frame 4)"; size="$(sec "$elf" .eh_frame 3)"
  st="$(sym "$elf" __eh_frame_start)"; en="$(sym "$elf" __eh_frame_end)"
  { [ "$(num "$st")" = "$(num "$addr")" ] && [ "$(num "$(sym "$elf" __EH_FRAME_BEGIN__)")" = "$(num "$st")" ] \
      && [ "$(( $(num "$st") & 7 ))" = 0 ] && [ "$(num "$en")" -gt "$(num "$st")" ] \
      && [ "$(num "$en")" -le $(( $(num "$addr") + $(num "$size") )) ]; } \
    && pass "$name: .eh_frame starts at __eh_frame_start (= __EH_FRAME_BEGIN__) and ends at __eh_frame_end" \
    || fail "$name: .eh_frame starts at __eh_frame_start (= __EH_FRAME_BEGIN__) and ends at __eh_frame_end ($st $en $addr $size)"
  # the list of crtend.o and the one of the linker script: zero words at the end of the range
  got="$(riscv64-elf-objdump -s -j .eh_frame --start-address="$(printf '0x%x' $(( $(num "$en") - 4 )))" \
          --stop-address="$(printf '0x%x' $(( $(num "$en") + 4 )))" "$elf" | awk '/^ [0-9a-f]+ / { print $2 " " $3 }' | head -1)"
  [ "$got" = "00000000 00000000" ] && pass "$name: the range ends with the zero word of crtend.o and the script has one more" \
    || fail "$name: the range ends with the zero word of crtend.o and the script has one more ($got)"
  # the first record of the range is a CIE or an FDE of a function of the image: a non-zero length
  got="$(riscv64-elf-objdump -s -j .eh_frame --start-address="0x$st" --stop-address="$(printf '0x%x' $(( $(num "$st") + 4 )))" "$elf" \
          | awk '/^ [0-9a-f]+ / { print $2 }' | head -1)"
  { [ -n "$got" ] && [ "$got" != 00000000 ]; } && pass "$name: the range starts with a record" || fail "$name: the range starts with a record ($got)"
}

for hart in e51 u54; do
  if "$ROOT/x" build exceptions_test --hart "$hart" >"$work/build.out" 2>&1; then
    d="$ROOT/examples/exceptions_test/bin-$hart"
    # exceptions_test has the two constructors of ctor.S (one preinit, one init) besides frame_dummy;
    # the others only frame_dummy
    image_checks "exceptions_test ($hart)" "$d/exceptions_test.elf" 2 1
    image_checks "unhandled_test ($hart)" "$d/unhandled_test.elf" 1 0
    image_checks "unhandled_task_test ($hart)" "$d/unhandled_task_test.elf" 1 0
  else
    tail -5 "$work/build.out" >&2; fail "./x build exceptions_test --hart $hart"
  fi
done

# -- an image of the light runtime has none of it -----------------------------------------------------
if "$ROOT/x" build trap_test --hart e51 >"$work/build.out" 2>&1; then
  elf="$ROOT/examples/trap_test/bin-e51/trap_test.elf"
  [ -z "$(sym "$elf" frame_dummy)" ] && [ -z "$(sym "$elf" __register_frame_info)" ] \
    && pass "light image: no crtbegin.o (frame_dummy) and no registration" || fail "light image: no crtbegin.o and no registration"
  [ "$(num "$(sym "$elf" __init_array_start)")" = "$(num "$(sym "$elf" __init_array_end)")" ] \
    && pass "light image: .init_array is empty" || fail "light image: .init_array is empty"
else
  tail -5 "$work/build.out" >&2; fail "./x build trap_test --hart e51"
fi

echo "summary: $fails failure(s)"
[ $fails -eq 0 ]
