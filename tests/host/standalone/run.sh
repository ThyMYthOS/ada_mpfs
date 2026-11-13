#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Tests for the standalone partition data (config/gen/standalone.py):
#
#   - test_standalone.py: the generator on fixtures (the package and the list of link symbols byte for
#     byte), the defaults (the console is the MMUART of the lowest hart, LIM 15 ways), the harts, the
#     console table, the memory profiles, the local memories, the contract with the linker scripts
#     (every value symbol is read, every layout symbol is defined), --check, determinism, every input
#     it refuses (status 2) and every rule violation it must not refuse (the Ada checks do that).
#     It needs no toolchain.
#   - a negative build for EACH check of the package MPFS_Partition: ./x build of examples/trap_test
#     with a partition that violates the rule fails before the link, with the message of the check and
#     no image: a mask that mixes the E51 and U54, a mask that names no hart, a boot role above 1, a
#     stack, interrupt stack or secondary stack size that is not a multiple of 16, the console ram_fifo
#     before SMP exists, L2 ways that do not add up to 16, more than 15 LIM ways, a DTIM on a U54 or
#     above 8 KB, an ITIM larger than that of its hart. And the controls: the same build without a
#     fault, and the parameters of ./x build reaching the image.
#
# The builds are skipped when the pinned GNAT, zstd or GNU tar is missing. Exits non-zero on any failure.
#
# @verifies RTS-019

set -u
export LC_ALL=C
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HERE="$ROOT/tests/host/standalone"
fails=0

pass () { echo "ok:   $1"; }
fail () { echo "FAIL: $1" >&2; fails=$((fails + 1)); }
skip () { echo "skip: $1"; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

. "$ROOT/tools/mpfs-env.sh"
mpfs_find_python

echo "-- test_standalone.py"
"$MPFS_PYTHON" -I "$HERE/test_standalone.py" || fail "test_standalone.py"

if ! mpfs_toolchain_on_path >/dev/null 2>&1; then
  skip "the builds: the pinned toolchain is not installed (./x toolchain install gnat)"
  [ $fails -eq 0 ] || { echo "$fails failure(s)" >&2; exit 1; }
  echo "all ok"; exit 0
fi
if ! command -v zstd >/dev/null 2>&1 || ! tar --version 2>&1 | grep -q 'GNU tar'; then
  skip "the builds: zstd or GNU tar is not installed"
  [ $fails -eq 0 ] || { echo "$fails failure(s)" >&2; exit 1; }
  echo "all ok"; exit 0
fi

ex="$ROOT/examples/trap_test"

# xbuild <log> <hart> <./x build option>...: ./x build of trap_test, no image left from an earlier build
xbuild () {
  local log="$1" hart="$2"; shift 2
  rm -rf "$ex/obj-$hart" "$ex/bin-$hart"
  "$ROOT/x" build trap_test --hart "$hart" "$@" >"$log" 2>&1
}
sym () { riscv64-elf-nm "$1" | awk -v n="$2" '$3 == n { print $1 }'; }

# -- the control: the build without a fault links, and its partition is what the generator gives ----------
if xbuild "$work/control.log" e51; then
  pass "control: ./x build trap_test --hart e51 builds"
  part="$ROOT/build/partition/trap_test-e51"
  "$MPFS_PYTHON" -I "$ROOT/config/gen/standalone.py" --hart e51 --profile light --console mmuart0 --memory lim \
    --check --output "$part/mpfs_partition.ads" >"$work/check.log" 2>&1 \
    && pass "control: build/partition/trap_test-e51 is what the generator gives for those parameters" \
    || fail "control: build/partition/trap_test-e51 is current ($(tail -3 "$work/check.log"))"
else
  fail "control: ./x build trap_test --hart e51 builds ($(tail -5 "$work/control.log"))"
fi

# -- the parameters of ./x build reach the image --------------------------------------------------------------
if xbuild "$work/params.log" e51 --console mmuart3 --console-init 0 --stack-size 32768 --interrupt-stack-size 4096 \
     --memory scratchpad --role secondary; then
  elf="$ex/bin-e51/trap_test.elf"
  got="$(sym "$elf" __mpfs_console_base) $(sym "$elf" __mpfs_console_init) $(sym "$elf" __stack_size) $(sym "$elf" __mpfs_boot_role) $(sym "$elf" _start)"
  [ "$got" = "0000000020104000 0000000000000000 0000000000008000 0000000000000000 000000000a000000" ] \
    && pass "--console, --console-init, --stack-size, --memory and --role reach the image" \
    || fail "--console, --console-init, --stack-size, --memory and --role reach the image ($got)"
  [ "$(sym "$elf" __interrupt_stack_size)" = 0000000000001000 ] \
    && pass "--interrupt-stack-size reaches the image" || fail "--interrupt-stack-size reaches the image"
else
  fail "./x build with all parameters ($(tail -5 "$work/params.log"))"
fi
if xbuild "$work/u54.log" u54 --harts 2 --role secondary --memory scratchpad; then
  elf="$ex/bin-u54-h2/trap_test.elf"; [ -f "$elf" ] || elf="$ex/bin-u54/trap_test.elf"
  got="$(sym "$elf" __mpfs_harts_mask) $(sym "$elf" __mpfs_console_base)"
  [ "$got" = "0000000000000004 0000000020102000" ] && pass "--harts 2 gives the mask 4 and the default console MMUART2" \
    || fail "--harts 2 gives the mask 4 and the default console MMUART2 ($got)"
else
  fail "./x build --hart u54 --harts 2 ($(tail -5 "$work/u54.log"))"
fi
rm -rf "$ex"/obj-* "$ex"/bin-*

# -- negative builds: one for each check ------------------------------------------------------------------------
# negative <name> <hart> <message> <generator option>...: the build fails with the message of the check,
# before gprbuild runs, and leaves no image
negative () {
  local name="$1" hart="$2" text="$3"; shift 3
  local log="$work/neg-$name.log"
  if xbuild "$log" "$hart" -- "$@"; then
    fail "$name: it built, it must fail"
  elif [ -f "$ex/bin-$hart/trap_test.elf" ]; then
    fail "$name: it failed but left an image"
  elif ! grep -qF -- "$text" "$log"; then
    fail "$name failed, but not with \"$text\": $(tail -4 "$log")"
  elif grep -q 'gprbuild' "$log"; then
    fail "$name: gprbuild ran, the check must stop the build before it"
  else
    pass "$name fails (\"$text\")"
  fi
}

negative mask_mixes_e51_and_u54 e51 "a partition mask must not mix the E51 and U54 harts" --harts 0,1
negative mask_names_no_hart e51 "the harts mask names no hart or a hart above 4" --mask 0x20
negative mask_empty e51 "the harts mask names no hart or a hart above 4" --mask 0
negative boot_role_above_1 e51 "__mpfs_boot_role must be 1 (primary) or 0 (secondary)" --role 2
negative stack_size_not_16 e51 "the stack size must be a non-zero multiple of 16" --stack-size 16392
negative interrupt_stack_size_not_16 e51 "the interrupt stack size must be a non-zero multiple of 16" --interrupt-stack-size 8200
negative secondary_stack_size_not_16 e51 "the secondary stack size must be a non-zero multiple of 16" --secondary-stack-size 1000
negative console_ram_fifo_before_smp e51 "the console ram_fifo needs a second hart; SMP does not exist yet" --console ram_fifo
negative l2_way_sum_not_16 e51 "the L2 ways (cache, LIM, scratchpad) must add up to 16" --cache-ways 2
negative lim_ways_above_15 e51 "at most 15 L2 ways can be LIM: one way stays cache" --cache-ways 0 --lim-ways 16
negative dtim_on_u54 u54 "the DTIM exists on the E51 only" --dtim-length 0x1000
negative dtim_too_large e51 "the DTIM of the E51 is 8 KB at most" --dtim-length 0x4000
negative itim_too_large_e51 e51 "the ITIM of E51 is larger than the ITIM of that hart" --itim-length 0x4000
negative itim_too_large_u54 u54 "the ITIM of U54 hart 1 is larger than the ITIM of that hart" --itim-length 0x8000

# only the check that names the fault fires: the way sum is 16 for lim_ways_above_15
grep -q 'must add up to 16' "$work/neg-lim_ways_above_15.log" \
  && fail "lim_ways_above_15: the way sum is 16, only the LIM check may fire" \
  || pass "lim_ways_above_15: only the LIM check fires"

# a value the generator cannot write is refused by it, with its own message
if xbuild "$work/refused.log" e51 --console mmuart9; then
  fail "an unknown console: it built, it must fail"
elif grep -q "invalid choice" "$work/refused.log" && grep -q "config/gen/standalone.py refused" "$work/refused.log" \
     && ! grep -q gprbuild "$work/refused.log"; then
  pass "an unknown console is refused by the generator before anything is built"
else
  fail "an unknown console is refused by the generator ($(tail -4 "$work/refused.log"))"
fi

# the checks run for every hart class: a partition without a fault passes all of them for the U54, too
if xbuild "$work/u54ok.log" u54 --console mmuart1 -- --itim-length 0x7000; then
  pass "a U54 partition with an ITIM of 28 KB passes the checks"
else
  fail "a U54 partition with an ITIM of 28 KB passes the checks ($(tail -4 "$work/u54ok.log"))"
fi
rm -rf "$ex"/obj-* "$ex"/bin-*

[ $fails -eq 0 ] || { echo "$fails failure(s)" >&2; exit 1; }
echo "all ok"
