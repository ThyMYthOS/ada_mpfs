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
#   - An image that does not link System.BB.Interrupts has no interrupt stack at all: the light profile
#     (no tasking, no trap handler of its own) and a tasking-profile image of a program without tasks.
#
# The builds are skipped when the pinned GNAT, zstd or GNU tar is missing. Exits non-zero on any failure.

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
        elf="$(ls "$ROOT/examples/$example/bin-$hart/"*.elf | head -1)"
        stack_size_is "$elf" "$size" "$example $hart --interrupt-stack-size $size"
        [ "$(sym "$elf" __interrupt_stack_size)" = "$(printf '0x%016x' "$size")" ] \
          && pass "$example $hart: __interrupt_stack_size is $size" \
          || fail "$example $hart: __interrupt_stack_size is $(sym "$elf" __interrupt_stack_size)"
      fi
    done
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

[ $fails -eq 0 ] || { echo "$fails failure(s)" >&2; exit 1; }
echo "all ok"
