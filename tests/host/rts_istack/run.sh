#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# The interrupt stack of the runtime mpfs_rts (issue #91), on real images:
#
#   - The size of the stack is the partition data: the space between __interrupt_stack_start and
#     __interrupt_stack_end is __interrupt_stack_size, whatever it is (--interrupt-stack-size of ./x build),
#     for the E51 and the U54, in the light-tasking and the embedded profile. The runtime used to declare
#     an array of a size of its own, so a larger value changed nothing and a smaller one failed the link.
#   - The defaults by profile: 8192 for light-tasking, 12912 for embedded (examples/interrupt_stack_*_test).
#   - An image that does not link System.BB.Interrupts has no interrupt stack at all: the light profile
#     (no tasking, no trap handler of its own) and a tasking-profile image of a program without tasks.
#   - The guard word at the lower end of the stack: an image that has a stack has the arming function (the
#     only entry of .preinit_array), the check at the exit of the trap (la t0, ld t1, bne t0 t1 after the
#     handler) and the failure path (__mpfs_interrupt_stack_overflow, called with sp at __stack_end); an
#     image that has none has no trace of it, so it does not grow.
#
# The builds are skipped when the pinned GNAT, zstd or GNU tar is missing. Exits non-zero on any failure.
#
# @verifies RTS-022, RTS-023

set -u
export LC_ALL=C
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fails=0

pass () { echo "ok:   $1"; }
fail () { echo "FAIL: $1" >&2; fails=$((fails + 1)); }
skip () { echo "skip: $1"; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

. "$ROOT/tools/mpfs-env.sh"

if ! mpfs_toolchain_on_path >/dev/null 2>&1; then
  skip "the builds: the pinned toolchain is not installed (./x toolchain install gnat)"
  echo "all ok"; exit 0
fi
if ! command -v zstd >/dev/null 2>&1 || ! tar --version 2>&1 | grep -q 'GNU tar'; then
  skip "the builds: zstd or GNU tar is not installed"
  echo "all ok"; exit 0
fi

sym () { riscv64-elf-nm "$1" | awk -v n="$2" '$3 == n { print "0x" $1 }'; }

# xbuild <example> <hart> <./x build option>...: ./x build with no image left from an earlier build; the
# image is printed by "$ex/bin-<hart>/..." of the caller
xbuild () {
  local example="$1" hart="$2"; shift 2
  rm -rf "$ROOT/examples/$example/obj-$hart" "$ROOT/examples/$example/bin-$hart"
  "$ROOT/x" build "$example" --hart "$hart" "$@" >"$work/build.log" 2>&1 \
    || { fail "./x build $example --hart $hart $* ($(tail -4 "$work/build.log"))"; return 1; }
}

# stack_size_is <image> <expected bytes> <what>
stack_size_is () {
  local elf="$1" want="$2" what="$3" start end
  start="$(sym "$elf" __interrupt_stack_start)"; end="$(sym "$elf" __interrupt_stack_end)"
  if [ -n "$start" ] && [ -n "$end" ] && [ $((end - start)) -eq "$want" ]; then
    pass "$what: the interrupt stack is $want bytes"
  else
    fail "$what: the interrupt stack is $((end - start)) bytes, expected $want"
  fi
}

# -- the size follows the partition data, in both tasking profiles and for both hart classes ------------------
for example in interrupt_stack_tasking_test interrupt_stack_embedded_test; do
  for hart in e51 u54; do
    for size in 4096 32768; do
      if xbuild "$example" "$hart" --interrupt-stack-size "$size"; then
        elf="$(ls "$ROOT/examples/$example/bin-$hart/"istack_peak_*.elf | head -1)"
        stack_size_is "$elf" "$size" "$example $hart --interrupt-stack-size $size"
        [ "$(sym "$elf" __interrupt_stack_size)" = "$(printf '0x%016x' "$size")" ] \
          && pass "$example $hart: __interrupt_stack_size is $size" \
          || fail "$example $hart: __interrupt_stack_size is $(sym "$elf" __interrupt_stack_size)"
      fi
    done
    rm -rf "$ROOT/examples/$example/obj-$hart" "$ROOT/examples/$example/bin-$hart"
  done
done

# -- the defaults by profile (config/gen/standalone.py): 8 KiB, and 12 912 bytes (the peak of the first unwind in a
# trap plus 50 %) for the embedded profile
for hart in e51 u54; do
  for pair in interrupt_stack_tasking_test:8192 interrupt_stack_embedded_test:12912; do
    example="${pair%%:*}"; want="${pair##*:}"
    if xbuild "$example" "$hart"; then
      elf="$(ls "$ROOT/examples/$example/bin-$hart/"istack_peak_*.elf | head -1)"
      stack_size_is "$elf" "$want" "$example $hart by default"
    fi
    rm -rf "$ROOT/examples/$example/obj-$hart" "$ROOT/examples/$example/bin-$hart"
  done
done

# -- no unit that needs the stack, no stack ------------------------------------------------------------------------
for hart in e51 u54; do
  if xbuild trap_test "$hart" --interrupt-stack-size 32768; then
    elf="$ROOT/examples/trap_test/bin-$hart/trap_test.elf"
    stack_size_is "$elf" 0 "trap_test $hart (light) with a large --interrupt-stack-size"
  fi
  rm -rf "$ROOT/examples/trap_test/obj-$hart" "$ROOT/examples/trap_test/bin-$hart"
done

# -- the guard word: code in the images that have a stack, none in the others ------------------------------------
# guard_code <image> <what>: the arming function is the only entry of .preinit_array, the trap entry compares
# the word and ends a failed check in the overflow procedure
guard_code () {
  local elf="$1" what="$2" arm ps pe entry want dis
  arm="$(sym "$elf" __mpfs_interrupt_guard_arm)"
  ps="$(sym "$elf" __preinit_array_start)"; pe="$(sym "$elf" __preinit_array_end)"
  if [ -z "$arm" ] || [ -z "$(sym "$elf" __mpfs_interrupt_stack_overflow)" ]; then
    fail "$what: no arming function or no overflow procedure"; return
  fi
  if [ -n "$ps" ] && [ $((pe - ps)) -eq 8 ]; then
    entry="$(riscv64-elf-objdump -s -j .preinit_array "$elf" | awk '/^ [0-9a-f]+ / { print $2 $3 }' | head -1)"
    # the entry is the address of the arming function, as a little-endian word
    want="$(printf '%016x' $((arm)) | fold -w2 | tac | tr -d '\n')"
    [ "$entry" = "$want" ] && pass "$what: the only entry of .preinit_array is the arming function" \
      || fail "$what: .preinit_array holds $entry, not the address of the arming function ($want)"
  else
    fail "$what: .preinit_array has $((pe - ps)) bytes, expected one entry"
  fi
  dis="$(riscv64-elf-objdump -d "$elf" | awk '/<__gnat_trap_entry>:/,/mret/')"
  if printf '%s\n' "$dis" | grep -qE 'ld[[:space:]]+t1,0\(t0\)' && printf '%s\n' "$dis" | grep -qE 'bne[[:space:]]+t0,t1,'; then
    pass "$what: the trap entry compares the guard word (ld t1,0(t0); bne t0,t1)"
  else
    fail "$what: the trap entry has no comparison of the guard word"
  fi
  if riscv64-elf-objdump -d "$elf" | grep -q 'jal.*<__mpfs_interrupt_stack_overflow>'; then
    pass "$what: a failed check ends in __mpfs_interrupt_stack_overflow"
  else
    fail "$what: nothing calls __mpfs_interrupt_stack_overflow"
  fi
}
# no_guard <image> <what>: no trace of the guard
no_guard () {
  local elf="$1" what="$2" found
  found="$(riscv64-elf-nm "$elf" | grep -E '__mpfs_interrupt_guard_arm|__mpfs_interrupt_stack_overflow' || true)"
  if [ -z "$found" ] && [ "$(sym "$elf" __preinit_array_start)" = "$(sym "$elf" __preinit_array_end)" ]; then
    pass "$what: no guard code, empty .preinit_array"
  else
    fail "$what: guard code in an image without interrupt stack ($found)"
  fi
}

for hart in e51 u54; do
  for example in interrupt_test interrupt_embedded_test; do
    if xbuild "$example" "$hart"; then
      guard_code "$ROOT/examples/$example/bin-$hart/$example.elf" "$example $hart"
    fi
    rm -rf "$ROOT/examples/$example/obj-$hart" "$ROOT/examples/$example/bin-$hart"
  done
  for example in trap_test trap_tasking_test; do
    if xbuild "$example" "$hart"; then
      no_guard "$ROOT/examples/$example/bin-$hart/$example.elf" "$example $hart (no interrupt stack)"
    fi
    rm -rf "$ROOT/examples/$example/obj-$hart" "$ROOT/examples/$example/bin-$hart"
  done
done

[ $fails -eq 0 ] || { echo "$fails failure(s)" >&2; exit 1; }
echo "all ok"
