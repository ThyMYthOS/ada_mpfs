#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# ./x hw -- a PolarFire SoC (MPFS) board from the command line: a shell (tools/hw.sh) around hw/*.py and hw/start_openocd.sh.
#
#   ./x hw [help|-h|--help]    this text
#   ./x hw COMMAND --help      the options of one command (the Python tools print theirs; openocd hands --help to OpenOCD)
#
# Commands
#
#   flashpros    list the connected FlashPro adapters: serial number, USB ID, name, model and USB location
#   openocd      start Microchip's OpenOCD, the debug server that reset, initialize, run and probe talk to
#   reset        reset the board to its power-on state through OpenOCD
#   initialize   do what the first-stage boot software does to the MSS (clocks, PLL), so that CLINT.MTIME counts
#   run          build an example (or take an ELF), load it onto a hart, run it and show the serial ports
#   debug        start the GDB of the toolchain on an example or ELF, connected to the OpenOCD of the board
#   probe        run a probe program of hw/ on a hart and print its result block
#   monitor      show what the serial ports print, as it arrives
#   bootmode     switch the boot mode (0..3) with fpgenprog: PERMANENT, it reprograms the FPGA part
#   program      program the FPGA from a STAPL or PPD file with FlashPro Express, or list programmers and chains (--scan)
#
# The usual order is flashpros (what is connected), openocd (in a terminal of its own), then reset and initialize --minimal,
# then run or monitor. OpenOCD and the two programmers (bootmode, program) all use the FlashPro: stop OpenOCD before you run
# bootmode or program, which refuse while OpenOCD answers on its port.
#
# Any MPFS board with a FlashPro works, not only the Icicle Kit. What is the Icicle Kit's is the defaults: the serial ports
# (UART_PATTERN), BOOTMODE_DIE and BOOTMODE_PACKAGE of hw/lab.conf.example, and the register values that initialize writes
# (hw/mss_init.py holds those of the Icicle Kit design: check them before you use initialize on another board).
#
# The commands and their options
#
#   ./x hw flashpros [--vendor ID] [--all]
#                              lists what is connected, from the USB descriptors in sysfs (nothing is opened): serial number
#                              ("-" if the descriptor has none), ID, name, model, USB location. --all lists every USB device.
#                              The serial number or the location picks an adapter out for OpenOCD (FLASHPRO_SERIAL,
#                              FLASHPRO_USB_LOCATION). bootmode and program name a FlashPro as the Microchip tools do
#                              (FLASHPRO_ID), which is not in general the serial number; ./x hw program --scan lists those names.
#                              bootmode asks FlashPro Express for them. With several connected it stops and lists them unless one is
#                              named, and then programs that one only (through FlashPro Express: fpgenprog would program all).
#   ./x hw openocd [--lab F] [args]
#                              start Microchip's OpenOCD (hw/start_openocd.sh); args go to OpenOCD, --lab F names the lab.conf.
#                              Which FlashPro, which JTAG clock and which port it uses come from lab.conf (FLASHPRO_*, OCD_TCK_MHZ, OCD_PORT).
#   ./x hw bootmode N [ELF] [--yes] [--dry-run] [--prepare-only] [--workdir DIR] [--flashpro ID] [--lab F]
#                              switch the boot mode (0..3) with fpgenprog (hw/bootmode.py, a Python port of the programmer of
#                              Microchip; --help lists the options of the boot modes 2 and 3). ELF is the boot program
#                              (default: the example bare_hello, built). --flashpro chooses one of several FlashPros (the name
#                              ./x hw program --scan shows). Errors come with the help text, which
#                              describes the boot modes. PERMANENT: it reprograms the FPGA part; nothing is written without --yes or a
#                              typed "yes". --dry-run says what it would do; --prepare-only stops before the programming. Stop OpenOCD first: it and the
#                              programmer both use the FlashPro, and the script refuses while OpenOCD answers
#                              on the port of lab.conf.
#   ./x hw run <ex|file.elf> [--hart N] [--secs S] [--expect RE] [--expect-port N] [--uart-clocks|--uart-standin]
#                           [--baud N=RATE] [--view MODE] [--color WHEN] [--lab F]
#                              build the example (or take the ELF), load it onto hart N
#                              (0 = E51, 1-4 = U54; default: the HART of example.conf, hart 0
#                              for E51, hart 1 for U54), run it, show what the serial ports print as it arrives.
#                              With --expect the exit status says whether the console matched RE.
#   ./x hw debug [<ex|file.elf>] [--hart N] [--load] [--port P] [--gdb F] [--dry-run] [--lab F] [-- GDB-ARGS]
#                              start riscv64-elf-gdb of the toolchain on the example (built first) or ELF, connected to the
#                              gdb port of the OpenOCD of ./x hw openocd (OCD_HOST, OCD_GDB_PORT of lab.conf; one port for
#                              all harts, --hart N switches GDB to the thread of hart N; --port names another). Without --load the board
#                              keeps the image it has (the ELF is for symbols). --load halts the hart, writes the image in
#                              whole 64-byte lines like run does, sets pc to the entry and checks it with compare-sections.
#                              Without an example, GDB starts without symbols. OpenOCD is not started by it.
#   ./x hw probe <probe.S> <hart> [--words N] [--secs S] [--expect RE] [--lab F]
#                              run a probe of hw/ and print its result block
#   ./x hw monitor [--secs N] [--port N] [--expect RE] [--baud N=RATE] [--view MODE] [--color WHEN] [--lab F]
#                              show what the serial ports print, as it arrives
#   --baud N=RATE (run, monitor)  the baud rate of the device of MMUART N (repeatable); default UART<n>_BAUD or
#                              UART_BAUD of lab.conf, 115200. TCP ports have the rate of their socat
#   --view MODE (run, monitor) how the serial text is shown: live (a window of 8 lines per port, in which the
#                              text scrolls; the default on a terminal), interleaved (complete lines in the
#                              order they arrive, behind MMUART<n>:; the default otherwise) or blocks (one
#                              block per port at the end: a header with the byte count, the lines behind a |).
#                              --color auto|always|never
#                              (default auto: on a terminal, off with NO_COLOR, on with FORCE_COLOR): the colours
#                              of the target pass through when on and are removed when off; other escape
#                              sequences of the target are always removed. --expect matches the text as the
#                              target printed it, whatever the view and the colours.
#   ./x hw initialize [--xml FILE] [--svd FILE] [--minimal] [--skip-io] [--dry-run] [--target T] [--lab F]
#                              do what the first-stage boot software does to the MSS before the clock switch
#                              (hw/initialize.py, hw/mss_init.py): RTC divisor, dynamic enables, IO set-up, SGMII channel
#                              set-up and the MSS PLL up to its lock; CLINT.MTIME counts afterwards. The CPU keeps its boot
#                              clock. The values come from the MSS Configurator XML of the board, which is required: --xml
#                              FILE or MSS_XML of lab.conf (exit status 2 without one). --minimal does only what MTIME
#                              needs; --dry-run prints the XML, its SHA-256 and the steps and writes nothing.
#   ./x hw reset [--svd FILE] [--target T] [--lab F]
#                              reset the board to its power-on state through OpenOCD (dmi_read/dmi_write of
#                              abstractcs, reset halt, check SUBBLK_CLOCK_CR and SOFT_RESET_CR), also after a
#                              hung debug module; exit 0 only if the check passed, 2 otherwise
#   ./x hw program FILE [--device NAME] [--programmer ID] [--action ACTION] [--tck MHZ] [--workdir DIR] [--yes] [--dry-run] [--lab F]
#   ./x hw program --scan [--programmer ID] [--tck MHZ] [--workdir DIR] [--dry-run] [--lab F]
#                              program the FPGA from a STAPL (.stp) or PPD (.ppd) file with FlashPro Express (hw/program.py): it writes a Tcl script
#                              (job project, TCK frequency, scan of the chain, device, file, action) and runs FPExpress on it.
#                              Programmer and device are found by FlashPro Express unless named. PROGRAM and ERASE change the FPGA, so
#                              they write only with --yes or a typed "yes"; DEVICE_INFO, READ_IDCODE and VERIFY only read. --scan only
#                              lists the programmers and the devices of their JTAG chains. The TCK frequency is --tck or
#                              TCK_MHZ of lab.conf (OCD_TCK_MHZ is OpenOCD's). --dry-run prints the scripts. Stop OpenOCD first (the FlashPro is shared).
#
# Settings
#
# Everything that differs between machines is in hw/lab.conf, a copy of hw/lab.conf.example (which lists every key with what
# it is for); --lab FILE, or the environment variable LAB_CONF, names another file. The keys, by what they are for:
#   OpenOCD       OPENOCD (install directory), OCD_HOST, OCD_PORT, OCD_ROOT (OpenOCD on another machine)
#   serial ports  UART_PATTERN, UART_COUNT, UART<n> (devices, or TCP ports that socat tunnels from another machine: tcp://HOST:PORT)
#   FlashPro      FLASHPRO_TYPE (model), FLASHPRO_SERIAL, FLASHPRO_USB_LOCATION (which adapter OpenOCD uses), FLASHPRO_ID (which one
#                 the Microchip tools use), OCD_TCK_MHZ (JTAG clock of OpenOCD), TCK_MHZ (JTAG clock of
#                 hw/program.py)
#   tools         FPGENPROG, FPEXPRESS (full paths of fpgenprog and FPExpress)
#   bootmode      BOOTMODE_DIE, BOOTMODE_PACKAGE
# More: hw/README.md, docs/lab/openocd.md.
#
# Exit status: 0 success, 1 the expectation was not met,
# 2 set-up error (no OpenOCD, no serial port, bad arguments), 130 ended with Ctrl+C.

set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

die () { echo "hw: $*" >&2; exit 2; }

# the help is the comment at the top of this file, without its "# ", up to the code: one text for the reader of the file
# and for ./x hw help
usage () { sed -n -e '/^set -u/q' -e '5,$p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

verb="${1:-}"; shift || true
case "$verb" in
  ""|help|-h|--help) usage; exit 0 ;;
  openocd) exec sh "$root/hw/start_openocd.sh" "$@" ;;
  bootmode|flashpros|run|debug|probe|monitor|reset|initialize|program) ;;
  *) die "unknown command '$verb' (./x hw help lists them)" ;;
esac

# shellcheck source=tools/mpfs-env.sh
. "$root/tools/mpfs-env.sh"
mpfs_find_python

case "$verb" in
  probe)   exec "$MPFS_PYTHON" "$root/hw/run_probe.py" "$@" ;;
  monitor) exec "$MPFS_PYTHON" "$root/hw/monitor.py" "$@" ;;
  reset)   exec "$MPFS_PYTHON" "$root/hw/reset.py" "$@" ;;
  initialize) exec "$MPFS_PYTHON" "$root/hw/initialize.py" "$@" ;;
  bootmode) exec "$MPFS_PYTHON" "$root/hw/bootmode.py" "$@" ;;
  program) exec "$MPFS_PYTHON" "$root/hw/program.py" "$@" ;;
  flashpros) exec "$MPFS_PYTHON" "$root/hw/flashpros.py" "$@" ;;
esac

# run and debug: <example|file.elf> [--hart N] and the options of the tool; an example is built first
target=""
if [ "$verb" = run ]; then
  [ $# -ge 1 ] || die "usage: ./x hw run <example|file.elf> [--hart N] [--secs S] [--expect RE] [--uart-clocks|--uart-standin] [--view MODE] [--color WHEN]"
fi
if [ $# -ge 1 ] && [ "${1#-}" = "$1" ]; then target="$1"; shift; fi
hart=""; rest=()
while [ $# -gt 0 ]; do
  case "$1" in
    --hart) [ $# -ge 2 ] || die "--hart needs a value"; hart="$2"; shift 2 ;;
    --) rest+=("$@"); break ;;
    *) rest+=("$1"); shift ;;
  esac
done
elf=""
if [ -z "$target" ]; then
  [ -n "$hart" ] || hart=0
elif [ -f "$target" ]; then
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
  bindir="bin-$cls"
  case "$hart" in [2-4]) bindir="bin-u54-h$hart" ;; esac   # the images of U54 harts 2 to 4 are kept apart from hart 1's
  #  an example that builds several images (textio_test, exceptions_test) runs the one named like it
  elf="$root/examples/$target/$bindir/$target.elf"
  [ -f "$elf" ] || elf="$(find "$root/examples/$target/$bindir" -maxdepth 1 -name '*.elf' 2>/dev/null | sort | head -n 1)"
  [ -n "$elf" ] || die "building $target produced no $bindir/*.elf"
fi
if [ "$verb" = debug ]; then
  exec "$MPFS_PYTHON" "$root/hw/debug.py" ${elf:+"$elf"} --hart "$hart" "${rest[@]}"
fi
exec "$MPFS_PYTHON" "$root/hw/run_image.py" "$elf" "$hart" "${rest[@]}"
