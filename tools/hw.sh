#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# hw.sh -- the Icicle Kit from the command line; a shell around hw/*.py. Driven by `./x hw`.
#
#   hw.sh bootmode N [ELF] [--yes] [--dry-run] [--workdir DIR] [--lab F]
#                              switch the boot mode (0..3) with the programmer of SoftConsole (hw/bootmode.py). ELF is the boot program
#                              (default: the example bare_hello, built). Errors come with the help text, which
#                              describes the boot modes. PERMANENT: it reprograms the FPGA part; nothing is written without --yes or a
#                              typed "yes". --dry-run prints the command only. Stop OpenOCD first: it and the
#                              programmer both use the FlashPro, and the script refuses while OpenOCD answers
#                              on the port of lab.conf.
#   hw.sh openocd [args]       start the SoftConsole OpenOCD (hw/start_openocd.sh)
#   hw.sh run <ex|file.elf> [--hart N] [--secs S] [--expect RE] [--expect-port N] [--uart-standin] [--lab F]
#                              build the example (or take the ELF), load it onto hart N
#                              (0 = E51, 1-4 = U54; default: the HART of example.conf, hart 0
#                              for E51, hart 1 for U54), run it, print what the serial ports show.
#                              With --expect the exit status says whether the console matched RE.
#   hw.sh probe <probe.S> <hart> [--words N] [--secs S] [--expect RE] [--lab F]
#                              run a probe of hw/ and print its result block
#   hw.sh monitor [--secs N] [--port N] [--expect RE] [--lab F]
#                              show what the serial ports print
#   hw.sh reset [--svd FILE] [--target T] [--lab F]
#                              reset the board to its power-on state through OpenOCD (dmi_read/dmi_write of
#                              abstractcs, reset halt, check SUBBLK_CLOCK_CR and SOFT_RESET_CR), also after a
#                              hung debug module; exit 0 only if the check passed, 2 otherwise
#
# Ports, SoftConsole path and the serial devices come from hw/lab.conf (a copy of hw/lab.conf.example; --lab FILE or
# LAB_CONF names another one). Exit status: 0 success, 1 the expectation was not met,
# 2 set-up error (no OpenOCD, no serial port, bad arguments), 130 ended with Ctrl+C.

set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

die () { echo "hw: $*" >&2; exit 2; }

verb="${1:-}"; shift || true
case "$verb" in
  openocd) exec sh "$root/hw/start_openocd.sh" "$@" ;;
  bootmode|run|probe|monitor|reset) ;;
  *) die "usage: ./x hw bootmode|openocd|run|probe|monitor|reset" ;;
esac

# shellcheck source=tools/mpfs-env.sh
. "$root/tools/mpfs-env.sh"
mpfs_find_python

case "$verb" in
  probe)   exec "$MPFS_PYTHON" "$root/hw/run_probe.py" "$@" ;;
  monitor) exec "$MPFS_PYTHON" "$root/hw/monitor.py" "$@" ;;
  reset)   exec "$MPFS_PYTHON" "$root/hw/reset.py" "$@" ;;
  bootmode) exec "$MPFS_PYTHON" "$root/hw/bootmode.py" "$@" ;;
esac

# run
[ $# -ge 1 ] || die "usage: ./x hw run <example|file.elf> [--hart N] [--secs S] [--expect RE] [--uart-standin]"
target="$1"; shift
hart=""; rest=()
while [ $# -gt 0 ]; do
  case "$1" in
    --hart) [ $# -ge 2 ] || die "--hart needs a value"; hart="$2"; shift 2 ;;
    *) rest+=("$1"); shift ;;
  esac
done
if [ -f "$target" ]; then
  elf="$target"
  [ -n "$hart" ] || hart=0
else
  [ -d "$root/examples/$target" ] || die "no such example or file: $target"
  conf="$root/examples/$target/example.conf"
  if [ -z "$hart" ]; then
    class="$(sed -n 's/^HART=//p' "$conf" 2>/dev/null | tail -n 1)"
    case "${class:-e51}" in e51) hart=0 ;; u54) hart=1 ;; *) die "invalid HART '$class' in $conf" ;; esac
  fi
  case "$hart" in
    0)     build=(--hart e51); cls=e51 ;;
    [1-4]) build=(--hart u54 --harts "$hart"); cls=u54 ;;
    *)     die "invalid --hart '$hart' (0 = E51, 1-4 = U54)" ;;
  esac
  rc=0
  "$root/x" build "$target" "${build[@]}" || rc=$?
  [ "$rc" -eq 0 ] || { [ "$rc" -ge 128 ] && exit "$rc"; exit 2; }   # Ctrl+C in the build ends with its 130
  elf="$(find "$root/examples/$target/bin-$cls" -maxdepth 1 -name '*.elf' 2>/dev/null | sort | head -n 1)"
  [ -n "$elf" ] || die "building $target produced no bin-$cls/*.elf"
fi
exec "$MPFS_PYTHON" "$root/hw/run_image.py" "$elf" "$hart" "${rest[@]}"
