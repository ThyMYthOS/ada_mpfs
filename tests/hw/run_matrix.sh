#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
# Run the cells of the test set (tests/qemu/tests.list) on the Icicle Kit and print one line per cell.
#
#   tests/hw/run_matrix.sh [-s SECS] [-o DIR] [-m lim|scratchpad] [NAME ...]
#
# Needs OpenOCD and the serial ports as for `./x hw run` (hw/lab.conf) and the board in boot mode 0 after
# `./x hw initialize --minimal` (CLINT.MTIME must count); the script resets and initializes the board before every cell. NAME is a name of the list (delay_accuracy_test_e51,
# ...); -m scratchpad builds the images for the L2 scratchpad (--memory scratchpad) and runs hw/l2_scratchpad.py after
# each initialize (heap_test needs a heap of 512 KiB, so it fails there; name the rows you want); without a NAME every row whose image is the one of its example runs. Rows whose MMUART has no port
# (MMUART4: console_mmuart4_test) and itim_reject_test (QEMU has no ITIM, the board has) are listed as "skip". The images of delay_accuracy_test
# are built with DELAY_ACCURACY=hardware, those of interrupt_test with RX_SOURCE=loopback. The log of each cell is DIR/NAME.log (default build/hw-results).
#
# A cell passes if "TEST <name>: PASS" is on the port of the list and no "FAIL" line is. The console is first
# set up by --uart-standin (images with Bare_Console); if nothing at all is printed, the cell is run again with
# --uart-clocks (images whose console driver sets the MMUART up itself).
#
# Exit status: 0 if every cell that ran passed, 1 if one failed, 2 on a set-up error.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
secs=20 out="$root/build/hw-results" memory=lim
while getopts "s:o:m:" opt; do
  case "$opt" in
    s) secs="$OPTARG" ;;
    o) out="$OPTARG" ;;
    m) memory="$OPTARG" ;;
    *) exit 2 ;;
  esac
done
shift $((OPTIND - 1))
case "$memory" in lim|scratchpad) ;; *) echo "run_matrix: -m is lim or scratchpad" >&2; exit 2 ;; esac
mkdir -p "$out"
export DELAY_ACCURACY=hardware RX_SOURCE=loopback

pass=0 fail=0 skip=0
uarts=4   # MMUART0..3 are on the ports of the lab; the CP2108 has four interfaces, MMUART4 has none
while IFS=$'\t' read -r name dir serial expect _; do
  case "$name" in ''|'#'*|name) continue ;; esac
  [ "$expect" = pass ] || continue
  if [ $# -gt 0 ]; then
    want=0; for n in "$@"; do [ "$n" = "$name" ] && want=1; done
    [ "$want" = 1 ] || continue
  fi
  case "$name" in
    *_e51)    hart=0; rest="${name%_e51}" ;;
    *_u54)    hart=1; rest="${name%_u54}" ;;
    *_u54h[2-4]) hart="${name: -1}"; rest="${name%_u54h?}" ;;
    *) printf '%-40s skip (no hart class in the name)\n' "$name"; skip=$((skip + 1)); continue ;;
  esac
  example="${dir#examples/}"
  case "$name" in
    itim_reject_test_*)   # the E51's ITIM is enabled on the board, so there is no rejection to see (itim_test covers the ITIM)
      printf '%-40s skip (QEMU only: the ITIM is there on the board)\n' "$name"
      skip=$((skip + 1)); continue ;;
  esac
  if [ "$serial" -ge "$uarts" ]; then
    printf '%-40s skip (MMUART%s is not wired to a port here)\n' "$name" "$serial"
    skip=$((skip + 1)); continue
  fi
  case "$hart" in
    0)   cls=e51; bindir=bin-e51; bargs=(--hart e51) ;;
    1)   cls=u54; bindir=bin-u54; bargs=(--hart u54) ;;
    *)   cls=u54; bindir="bin-u54-h$hart"; bargs=(--hart u54 --harts "$hart") ;;
  esac
  [ "$memory" = lim ] || bargs+=(--memory "$memory")
  elf="$root/$dir/$bindir/$rest.elf"
  log="$out/$name.log"
  verdict=FAIL
  if ! "$root/x" build "$example" "${bargs[@]}" >"$log" 2>&1 || [ ! -f "$elf" ]; then
    printf '%-40s ERROR  (build failed or no %s, see %s)\n' "$name" "${elf#"$root"/}" "$log"
    fail=$((fail + 1)); continue
  fi
  for mode in --uart-standin --uart-clocks; do
    # every cell starts from the power-on state: a test can leave the board in a state (a hart that
    # kept running, a pending interrupt) in which the next image does not start
    # (a primary image resets the MSS when it ends, which also undoes the set-up of the scratchpad)
    if ! { "$root/x" hw reset && "$root/x" hw initialize --minimal \
           && { [ "$memory" = lim ] || python3 -I "$root/hw/l2_scratchpad.py"; }; } >"$log" 2>&1; then
      printf '%-40s ERROR  (reset or initialize failed, see %s)\n' "$name" "$log"
      fail=$((fail + 1)); continue 2
    fi
    "$root/x" hw run "$elf" --hart "$hart" "$mode" --secs "$secs" --view blocks \
      --expect 'TEST [A-Za-z0-9_]+: PASS' --expect-port "$serial" >"$log" 2>&1
    rc=$?
    if [ "$rc" -eq 0 ] && ! grep -q 'FAIL' "$log"; then verdict=PASS; break; fi
    [ "$rc" -eq 2 ] && break
    grep -q 'no serial output' "$log" || break   # a console that printed something is not set up wrongly
  done
  [ "$rc" -eq 2 ] && verdict=ERROR
  printf '%-40s %s   (%s, hart %s, port %s)\n' "$name" "$verdict" "${mode#--uart-}" "$hart" "$serial"
  case "$verdict" in PASS) pass=$((pass + 1)) ;; *) fail=$((fail + 1)) ;; esac
done <"$root/tests/qemu/tests.list"

echo "pass $pass, fail $fail, skip $skip"
[ "$fail" -eq 0 ]
