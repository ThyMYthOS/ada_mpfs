#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Tests for the start code and the linker base of the runtime (crates/mpfs_rts: mpfs/gnat/start.S,
# ld/*.ld, mpfs_link.gpr), master plan #41 work package P1.3:
#
#   - gen_runtime.sh puts the linker scripts into ld/ of a variant, replaces the upstream
#     start-ram.S by start.S (mpfs/remove.list) and refuses a remove list that names a file the
#     pack does not have;
#   - the four boot scenarios build: primary on the E51 (hart 0) and secondary on a U54 (hart 2),
#     each placed in the L2 LIM and in the scratchpad (examples/trap_test, which links the light
#     runtime): the image starts with _start at the start of the lowest segment, the trap record
#     is the last 32 bytes of the region, the partition data reach the image (mask, role, the
#     debugger's first CPU id), .data needs no copy;
#   - the place-envm.ld placement links with .data loaded in the eNVM and running in the LIM;
#   - the start code: whole 64-bit stores in the trap stub, three clear loops, one loop that calls
#     the entries of .preinit_array and .init_array; the hook app-sections.ld of an application is
#     included, the empty one of the runtime otherwise;
#   - the constructor arrays and .eh_frame (R8, P1.7): in every scenario image the arrays are
#     bracketed by their symbols (empty without constructors, 8-byte entries, in the order
#     preinit, init, fini) and .eh_frame is bracketed by __eh_frame_start and __eh_frame_end with
#     the zero word of the linker script behind it; an object with a constructor entry gets it into
#     .init_array; an entry that is not 8 bytes fails the link;
#   - negative builds: a missing mandatory symbol (undefined reference or undefined symbol in the
#     linker script), a stack size or interrupt stack size that is not a multiple of 16 or is 0, a
#     stack that leaves no room, an empty region, and a _start that is not at the start of the
#     lowest segment; each fails with the message that names it.
#
# The builds are skipped when the pinned GNAT, zstd or GNU tar is missing. Exits non-zero on any
# failure.

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

# -- the variants (built once into build/rts, where ./x build keeps them) -------------------------
for v in "light e51" "light u54"; do
  # shellcheck disable=SC2086
  bash "$GEN" $v 1 m >"$work/gen.out" 2>&1 || { cat "$work/gen.out" >&2; fail "gen_runtime.sh $v 1 m"; }
done
rts="$ROOT/build/rts"
e51="$rts/light-e51-cpus1-m"
u54="$rts/light-u54-cpus1-m"

for f in mpfs-memory.ld place-lim.ld place-scratchpad.ld place-envm.ld sections.ld app-sections.ld; do
  [ -f "$e51/ld/$f" ] && cmp -s "$e51/ld/$f" "$CRATE/ld/$f" \
    && pass "ld/$f of the variant is the one of crates/mpfs_rts/ld" || fail "ld/$f of the variant is the one of crates/mpfs_rts/ld"
done
members="$(riscv64-elf-ar t "$e51/adalib/libgnat.a")"
echo "$members" | grep -qx 'start.o' && pass "libgnat.a has start.o" || fail "libgnat.a has start.o"
echo "$members" | grep -qx 'start-ram.o' && fail "libgnat.a has no start-ram.o (remove.list)" || pass "libgnat.a has no start-ram.o (remove.list)"
[ ! -e "$e51/adainclude/start-ram.S" ] && [ -f "$e51/adainclude/start.S" ] \
  && pass "adainclude/ has start.S and no start-ram.S" || fail "adainclude/ has start.S and no start-ram.S"

# remove.list: a file the pack does not have is refused, a path outside the pack too
mkdir -p "$work/port/gnat"
cp "$CRATE/mpfs/gnat/start.S" "$work/port/gnat/"
echo "gnat/no-such-file.S" > "$work/port/remove.list"
out="$(bash "$GEN" --out "$work/rts-bad" --port-dir "$work/port" light e51 1 m 2>&1)"; rc=$?
{ [ $rc -eq 2 ] && case "$out" in *"has no gnat/no-such-file.S"*) true ;; *) false ;; esac; } \
  && pass "remove.list: a file the pack does not have is refused" || fail "remove.list: a file the pack does not have is refused ($rc: $out)"
echo "../packs/SHA256SUMS" > "$work/port/remove.list"
out="$(bash "$GEN" --out "$work/rts-bad" --port-dir "$work/port" light e51 1 m 2>&1)"; rc=$?
{ [ $rc -eq 2 ] && case "$out" in *"is not a path inside the pack"*) true ;; *) false ;; esac; } \
  && pass "remove.list: a path outside the pack is refused" || fail "remove.list: a path outside the pack is refused ($rc: $out)"
[ ! -e "$work/rts-bad/light-e51-cpus1-m" ] && pass "a refused remove list builds nothing" || fail "a refused remove list builds nothing"
# the linker scripts are part of the cache key
mkdir -p "$work/ld"
cp "$CRATE"/ld/*.ld "$work/ld/"
bash "$GEN" --check --ld-dir "$work/ld" light e51 1 m >/dev/null 2>&1; rc=$?
[ $rc -eq 0 ] && pass "an ld directory with the same files: up to date" || fail "an ld directory with the same files: up to date (exit $rc)"
echo "/* changed */" >> "$work/ld/place-lim.ld"
bash "$GEN" --check --ld-dir "$work/ld" light e51 1 m >/dev/null 2>&1; rc=$?
[ $rc -eq 1 ] && pass "another ld directory: not up to date" || fail "another ld directory: not up to date (exit $rc)"
bash "$GEN" --check light e51 1 m >/dev/null 2>&1; rc=$?
[ $rc -eq 0 ] && pass "the committed ld directory: up to date" || fail "the committed ld directory: up to date (exit $rc)"

# -- a copy of what trap_test needs, linked with the variants built above -------------------------
tree="$work/tree"
mkdir -p "$tree/examples/bare_hello" "$tree/tests" "$tree/crates/mpfs_rts"
cp -r "$ROOT/examples/trap_test" "$tree/examples/"
cp -r "$ROOT/examples/bare_hello/src" "$tree/examples/bare_hello/"
cp -r "$ROOT/tests/common" "$tree/tests/"
cp "$CRATE/mpfs_rts.gpr" "$CRATE/mpfs_link.gpr" "$tree/crates/mpfs_rts/"
rm -rf "$tree/examples/trap_test"/obj-* "$tree/examples/trap_test"/bin-*
ex="$tree/examples/trap_test"

# build <log> <hart> [NAME=value ...] [-- <gprbuild -largs arguments>]: gprbuild -f of the copy.
build () {
  local log="$1" hart="$2"; shift 2
  local xs=() largs=() seen=0 a
  for a in "$@"; do
    if [ "$a" = -- ]; then seen=1; continue; fi
    if [ $seen = 1 ]; then largs+=("$a"); else xs+=("-X$a"); fi
  done
  rm -rf "$ex/obj-$hart" "$ex/bin-$hart"
  ( cd "$ex" && gprbuild -q -p -f -P app.gpr "-XMPFS_RTS_ROOT=$rts" -XMPFS_HART="$hart" -XMPFS_PROFILE=light \
      -XMPFS_CPUS=1 -XMPFS_PRIV=m ${xs[@]+"${xs[@]}"} ${largs[@]+-largs "${largs[@]}"} ) >"$log" 2>&1
}

sym () {   # sym <elf> <name>: the value of a symbol, as nm prints it
  riscv64-elf-nm "$1" | awk -v n="$2" '$3 == n { print $1 }'
}

# scenario <name> <hart> <origin of the region> <expected mask> <role> <first cpu id> <build variables...>
scenario () {
  local name="$1" hart="$2" origin="$3" mask="$4" role="$5" first="$6"; shift 6
  local elf="$ex/bin-$hart/trap_test.elf" log="$work/$name.log" want got
  if ! build "$log" "$hart" "$@"; then fail "scenario $name builds ($(tail -5 "$log"))"; return; fi
  [ -f "$elf" ] && pass "scenario $name builds" || { fail "scenario $name builds (no image)"; return; }
  got="$(sym "$elf" _start)"
  [ "$got" = "$(printf '%016x' "$origin")" ] && pass "$name: _start is at the origin of the region" \
    || fail "$name: _start is at the origin of the region ($got)"
  got="$(riscv64-elf-readelf -lW "$elf" | awk '$1 == "LOAD" && $4 != "0x0000000000000000" { print $4 }' | sort | head -1)"
  [ "$(printf '%d' "$got")" = "$origin" ] && pass "$name: the lowest segment starts at _start" \
    || fail "$name: the lowest segment starts at _start ($got)"
  got="$(riscv64-elf-readelf -hW "$elf" | awk '/Entry point/ { print $4 }')"
  [ "$(printf '%d' "$got")" = "$origin" ] && pass "$name: the entry point is _start" || fail "$name: the entry point is _start ($got)"
  want="$(sym "$elf" __mpfs_harts_mask)"; [ "$((16#${want:-0}))" = "$mask" ] \
    && pass "$name: __mpfs_harts_mask is $mask" || fail "$name: __mpfs_harts_mask is $mask ($want)"
  want="$(sym "$elf" __mpfs_boot_role)"; [ "$((16#${want:-0}))" = "$role" ] \
    && pass "$name: __mpfs_boot_role is $role" || fail "$name: __mpfs_boot_role is $role ($want)"
  got="$(riscv64-elf-objdump -s -j .mpfs_gdb "$elf" | awk '/^ [0-9a-f]+ / { print $2 }' | head -1)"
  [ "$got" = "$(printf '%02x000000' "$first")" ] && pass "$name: __gnat_gdb_cpu_first_id is $first" \
    || fail "$name: __gnat_gdb_cpu_first_id is $first ($got)"
  [ "$(sym "$elf" __data_load)" = "$(sym "$elf" __data_start)" ] && pass "$name: .data is loaded where it runs" \
    || fail "$name: .data is loaded where it runs"
  # The constructor arrays: no constructor in the light runtime, so they are empty and start.S calls
  # nothing; they are bracketed in the order preinit, init, fini and start.S walks 8-byte entries.
  local a0 a1 a2 a3 a4 a5
  a0="$(sym "$elf" __preinit_array_start)"; a1="$(sym "$elf" __preinit_array_end)"
  a2="$(sym "$elf" __init_array_start)"; a3="$(sym "$elf" __init_array_end)"
  a4="$(sym "$elf" __fini_array_start)"; a5="$(sym "$elf" __fini_array_end)"
  { [ -n "$a0" ] && [ "$a0" = "$a1" ] && [ "$a1" = "$a2" ] && [ "$a2" = "$a3" ] && [ "$a3" = "$a4" ] && [ "$a4" = "$a5" ]; } \
    && pass "$name: the constructor arrays are empty and in order" \
    || fail "$name: the constructor arrays are empty and in order ($a0 $a1 $a2 $a3 $a4 $a5)"
  [ "$(( 16#${a2:-1} & 7 ))" = 0 ] && pass "$name: the constructor arrays are 8-byte aligned" \
    || fail "$name: the constructor arrays are 8-byte aligned ($a2)"
  eh_frame "$name" "$elf"
  local rec end
  rec="$(sym "$elf" __mpfs_trap_record)"; end="$(sym "$elf" __heap_end)"
  [ "$rec" = "$end" ] && [ "$(( 16#$rec & 7 ))" = 0 ] && pass "$name: the heap ends at the trap record" \
    || fail "$name: the heap ends at the trap record ($rec, $end)"
  [ "$(( (16#$(sym "$elf" __stack_end)) & 15 ))" = 0 ] && pass "$name: the stack is 16-byte aligned" \
    || fail "$name: the stack is 16-byte aligned"
}

# eh_frame <name> <elf>: .eh_frame is bracketed by __eh_frame_start and __eh_frame_end, 8-byte aligned,
# and the zero word of the linker script follows the range (the list ends for libgcc).
eh_frame () {
  local name="$1" elf="$2" st en sec addr size w
  st="$(sym "$elf" __eh_frame_start)"; en="$(sym "$elf" __eh_frame_end)"
  sec="$(riscv64-elf-objdump -h -j .eh_frame "$elf" | awk '$2 == ".eh_frame" { print $3, $4 }')"
  size="${sec% *}"; addr="${sec#* }"
  if [ -z "$st" ] || [ -z "$en" ] || [ -z "$addr" ]; then fail "$name: __eh_frame_start/__eh_frame_end bracket .eh_frame ($st $en $sec)"; return; fi
  { [ "$(( 16#$st ))" = "$(( 16#$addr ))" ] && [ "$(( 16#$en ))" -le "$(( 16#$addr + 16#$size ))" ] && [ "$(( 16#$st & 7 ))" = 0 ]; } \
    && pass "$name: __eh_frame_start is the start of .eh_frame, 8-byte aligned, __eh_frame_end inside" \
    || fail "$name: __eh_frame_start is the start of .eh_frame, 8-byte aligned, __eh_frame_end inside ($st $en $addr $size)"
  w="$(riscv64-elf-objdump -s -j .eh_frame --start-address="0x$en" --stop-address="$(printf '0x%x' $(( 16#$en + 4 )))" "$elf" \
        | awk '/^ [0-9a-f]+ / { print $2 }')"
  [ "$w" = 00000000 ] && pass "$name: a zero word follows __eh_frame_end" || fail "$name: a zero word follows __eh_frame_end ($w)"
}

scenario primary_lim        e51 $((0x08000000)) 1 1 0 MPFS_PLACEMENT=lim        MPFS_BOOT_ROLE=primary
scenario primary_scratchpad e51 $((0x0A000000)) 1 1 0 MPFS_PLACEMENT=scratchpad MPFS_BOOT_ROLE=primary
scenario secondary_lim        u54 $((0x08000000)) 4 0 2 MPFS_PLACEMENT=lim        MPFS_BOOT_ROLE=secondary MPFS_HARTS=2
scenario secondary_scratchpad u54 $((0x0A000000)) 4 0 2 MPFS_PLACEMENT=scratchpad MPFS_BOOT_ROLE=secondary MPFS_HARTS=2

# The scratchpad image runs from the scratchpad: no word of it is in the LIM or in the eNVM.
elf="$ex/bin-u54/trap_test.elf"
lo="$(riscv64-elf-readelf -lW "$elf" | awk '$1 == "LOAD" { print $3 }' | sort | head -1)"
[ "$(printf '%d' "$lo")" -ge $((0x0A000000)) ] && pass "a scratchpad image has no segment below the scratchpad" \
  || fail "a scratchpad image has no segment below the scratchpad ($lo)"

# place-envm.ld: code in the eNVM, .data loaded there and run in the LIM (start.S copies it)
if build "$work/envm.log" e51 MPFS_PLACEMENT=envm; then
  elf="$ex/bin-e51/trap_test.elf"
  [ "$(sym "$elf" _start)" = 0000000020220100 ] && pass "envm: _start is the start of the eNVM image" || fail "envm: _start is the start of the eNVM image ($(sym "$elf" _start))"
  ds="$(sym "$elf" __data_start)"; dl="$(sym "$elf" __data_load)"
  { [ "$(( 16#$ds >> 24 ))" = 8 ] && [ "$(( 16#$dl >> 24 ))" = 32 ]; } \
    && pass "envm: .data runs in the LIM ($ds) and is loaded from the eNVM ($dl)" \
    || fail "envm: .data runs in the LIM and is loaded from the eNVM ($ds, $dl)"
  [ "$(( 16#$(sym "$elf" __bss_start) >> 24 ))" = 8 ] && pass "envm: .bss, the stacks and the heap are in the LIM" \
    || fail "envm: .bss, the stacks and the heap are in the LIM"
else
  fail "place-envm.ld links ($(tail -5 "$work/envm.log"))"
fi

# The start code: the trap stub stores whole 64-bit words only (ECC memory, never written before),
# and .bss, the interrupt stacks and the stack of the environment task are each cleared by a loop.
if build "$work/disasm.log" e51; then
  elf="$ex/bin-e51/trap_test.elf"
  riscv64-elf-objdump -d --disassemble=__mpfs_trap_stub "$elf" > "$work/stub.dis"
  if grep -qE '[[:space:]]sd[[:space:]]' "$work/stub.dis" && ! grep -qE '[[:space:]](c\.)?s[wbh][[:space:]]' "$work/stub.dis"; then
    pass "the trap stub stores only 64-bit words"
  else fail "the trap stub stores only 64-bit words"; fi
  riscv64-elf-objdump -d --disassemble=_start "$elf" > "$work/start.dis"
  n="$(grep -cE '[[:space:]]sd[[:space:]]+zero' "$work/start.dis")"
  [ "$n" = 3 ] && pass "start.S clears .bss, the interrupt stacks and the stack with three loops" \
    || fail "start.S clears .bss, the interrupt stacks and the stack with three loops ($n)"
  n="$(grep -cE '[[:space:]]jalr[[:space:]]+t0' "$work/start.dis")"
  [ "$n" = 1 ] && pass "start.S calls the entries of .preinit_array and .init_array with one loop" \
    || fail "start.S calls the entries of .preinit_array and .init_array with one loop ($n)"
else
  fail "disassembly build ($(tail -5 "$work/disasm.log"))"
fi

# The hook of the application: app-sections.ld of the application is found first (-L order), the
# empty one of the runtime otherwise (the builds above are the case without one).
mkdir -p "$work/app"
cat > "$work/app/app-sections.ld" <<'EOF'
.app_marker : { __app_marker = .; LONG(0x4d505041) } > REGION_TEXT
EOF
if build "$work/app.log" e51 MPFS_APP_LD="$work/app"; then
  elf="$ex/bin-e51/trap_test.elf"
  [ -n "$(sym "$elf" __app_marker)" ] && pass "an app-sections.ld of the application is included" \
    || fail "an app-sections.ld of the application is included"
else
  fail "a link with an application hook ($(tail -5 "$work/app.log"))"
fi
if build "$work/noapp.log" e51; then
  [ -z "$(sym "$ex/bin-e51/trap_test.elf" __app_marker)" ] && pass "without one the empty hook of the runtime is used" \
    || fail "without one the empty hook of the runtime is used"
else
  fail "a link without an application hook ($(tail -5 "$work/noapp.log"))"
fi

# -- negative builds: each must fail with the message that names the fault ------------------------
# negative <name> <hart> <message> <build variables...> [-- <link arguments>]
negative () {
  local name="$1" hart="$2" text="$3"; shift 3
  local log="$work/neg-$name.log"
  if build "$log" "$hart" "$@"; then
    fail "$name: it linked, it must fail"
  elif [ -f "$ex/bin-$hart/trap_test.elf" ]; then
    fail "$name: it failed but left an image"
  elif grep -qF -- "$text" "$log"; then
    pass "$name fails (\"$text\")"
  else
    fail "$name failed, but not with \"$text\": $(tail -8 "$log")"
  fi
}

negative missing_boot_role e51 "undefined reference to \`__mpfs_boot_role'" MPFS_OMIT=boot_role
negative missing_harts_mask e51 "undefined symbol \`__mpfs_harts_mask' referenced in expression" MPFS_OMIT=harts_mask
negative missing_stack_size e51 "undefined symbol \`__stack_size' referenced in expression" MPFS_OMIT=stack_size
negative missing_interrupt_stack_size e51 "undefined symbol \`__interrupt_stack_size' referenced in expression" \
  MPFS_OMIT=interrupt_stack_size
negative stack_size_not_16 e51 "__stack_size is not a multiple of 16" MPFS_STACK_SIZE=16392
negative stack_size_zero e51 "__stack_size is 0" MPFS_STACK_SIZE=0
negative interrupt_stack_size_not_16 e51 "__interrupt_stack_size is not a multiple of 16" MPFS_INTERRUPT_STACK_SIZE=8200
negative stack_leaves_no_room e51 "region \`l2lim' overflowed" MPFS_STACK_SIZE=$((0x400000))
negative empty_scratchpad e51 "MPFS_SCRATCHPAD_LENGTH is 0" MPFS_PLACEMENT=scratchpad -- -Wl,--defsym=MPFS_SCRATCHPAD_LENGTH=0
negative empty_lim e51 "MPFS_LIM_LENGTH is 0" -- -Wl,--defsym=MPFS_LIM_LENGTH=0
negative mask_names_no_hart e51 "__mpfs_harts_mask must name harts 0 .. 4" -- -Wl,--defsym=__mpfs_harts_mask=0x20

# _start is not at the start of the lowest segment: another object puts bytes in .start first
printf '\t.section .start,"ax",@progbits\n\t.word 0x00000013\n' > "$work/misplaced.S"
if riscv64-elf-gcc -c -march=rv64imac_zicsr_zifencei -mabi=lp64 -o "$work/misplaced.o" "$work/misplaced.S"; then
  negative start_not_first e51 "_start is not at the start of .text" -- "$work/misplaced.o"
else
  fail "start_not_first: the fixture does not assemble"
fi

# A constructor entry: an 8-byte entry in .init_array (as __attribute__((constructor)) makes it) is
# kept (KEEP), lands between __init_array_start and __init_array_end and in no other array; an entry
# that is not 8 bytes fails the link.
printf '\t.text\nctor_fixture:\n\tret\n\t.section .init_array,"aw",@init_array\n\t.balign 8\n\t.dword ctor_fixture\n' > "$work/ctor.S"
printf '\t.text\nctor_fixture:\n\tret\n\t.section .init_array,"aw",@init_array\n\t.word 0\n' > "$work/ctor4.S"
if riscv64-elf-gcc -c -march=rv64imac_zicsr_zifencei -mabi=lp64 -o "$work/ctor.o" "$work/ctor.S" \
   && riscv64-elf-gcc -c -march=rv64imac_zicsr_zifencei -mabi=lp64 -o "$work/ctor4.o" "$work/ctor4.S"; then
  if build "$work/ctor.log" e51 -- "$work/ctor.o"; then
    elf="$ex/bin-e51/trap_test.elf"
    a2="$(sym "$elf" __init_array_start)"; a3="$(sym "$elf" __init_array_end)"; a1="$(sym "$elf" __preinit_array_end)"
    { [ "$(( 16#$a3 - 16#$a2 ))" = 8 ] && [ "$a1" = "$(sym "$elf" __preinit_array_start)" ]; } \
      && pass "an .init_array entry of an object is kept: one entry, .preinit_array empty" \
      || fail "an .init_array entry of an object is kept: one entry, .preinit_array empty ($a1 $a2 $a3)"
    w="$(riscv64-elf-objdump -s -j .init_array "$elf" | awk '/^ [0-9a-f]+ / { print $2 " " $3 }' | head -1)"
    want="$(sym "$elf" ctor_fixture | sed -E 's/^.{8}(..)(..)(..)(..)$/\4\3\2\1/') 00000000"
    [ "$w" = "$want" ] && pass "the entry is the address of the constructor" \
      || fail "the entry is the address of the constructor ($w, wanted $want)"
  else
    fail "a link with a constructor entry ($(tail -5 "$work/ctor.log"))"
  fi
  negative init_array_entry_not_8_bytes e51 ".preinit_array, .init_array or .fini_array is not 8-byte aligned" -- "$work/ctor4.o"
else
  fail "the constructor fixtures do not assemble"
fi

# A control for the negatives above: the same build with no fault links and leaves an image.
if build "$work/control.log" e51 && [ -f "$ex/bin-e51/trap_test.elf" ]; then pass "control: the build without a fault links"
else fail "control: the build without a fault links ($(tail -5 "$work/control.log"))"; fi

[ $fails -eq 0 ] || { echo "$fails failure(s)" >&2; exit 1; }
echo "all ok"
