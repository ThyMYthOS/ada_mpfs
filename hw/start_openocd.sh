#!/bin/sh
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Start Microchip's OpenOCD against the FlashPro of a PolarFire SoC board (embedded FlashPro6 by
# default, see FLASHPRO_TYPE). The distribution's own OpenOCD (0.12) lacks the driver for it.
#
#   start_openocd.sh [--lab FILE] [openocd arguments]
#
# The install directory of that OpenOCD (bin/openocd, openocd/scripts) is OPENOCD of hw/lab.conf
# (hw/lab.conf.example if there is none, or the file named by --lab or, without it, by LAB_CONF); the environment variable OPENOCD
# overrides both. If it is empty, the release pinned in tools/toolchain.env is used, from its prefix
# ($MPFS_TOOLS_PREFIX/openocd-<version>) where ./x toolchain install openocd puts it. Telnet is on :4444,
# gdb on :3333 (telnet is OCD_PORT of lab.conf, 4444 by default). FLASHPRO_SERIAL of lab.conf (or the
# environment) selects one of several connected FlashPro by its serial number; empty: the one OpenOCD finds.
# FLASHPRO_USB_LOCATION (also lab.conf or the environment; such as 1-2.3, the name of the adapter's directory in
# /sys/bus/usb/devices, which ./x hw flashpros shows) names an adapter by its place on the USB bus instead, for one whose
# descriptor has no serial number: it is given to OpenOCD as "adapter usb location". Whether a driver of OpenOCD honours that
# was not tried on a board; it changes if the adapter is plugged into another port.
# OCD_TCK_MHZ of lab.conf (or the environment) is the JTAG clock in whole MHz, given to OpenOCD as adapter speed in kHz
# after the interface file, which sets 6000 kHz; empty: that default. hw/program.py takes the same key for FlashPro Express.
# FLASHPRO_TYPE (efp6, fp6, efp5 or fp5) says which model it is, and so which interface file and which command for the
# serial number OpenOCD gets; empty: hw/flashpros.py --model tells it from the USB product ID (efp6 if none is
# connected; an error if there are several models, or one that it does not know). FLASHPRO_SYSFS names another
# USB sysfs, for the tests. A missing OpenOCD is an error with the path that was tried.
#
# OpenOCD runs as a child of this script, which makes sure that Ctrl+C ends it: OpenOCD only looks at
# SIGINT between two passes of its event loop, so while it is stuck in a JTAG or abstract-command
# timeout (a hung bus) it does not react, and after hung accesses it may ignore repeated Ctrl+C. On
# SIGINT, SIGTERM or SIGHUP (closed terminal) the script sends SIGTERM (which OpenOCD handles like
# SIGINT; SIGINT is ignored by a background child of a shell without job control), waits up to
# START_OPENOCD_GRACE seconds (default 3) and then kills it with SIGKILL. A second signal kills it at
# once. Exit status: 130 after SIGINT, 143 after SIGTERM, 129 after SIGHUP, otherwise the status of
# OpenOCD. Only a SIGKILL of this script itself leaves OpenOCD behind.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
# --lab FILE (as with the other tools of hw/; also --lab=FILE, anywhere among the arguments) names the lab.conf to use instead of
# hw/lab.conf; it wins over LAB_CONF, must exist, and is not handed to OpenOCD. Everything else is, in its order.
n=$#
while [ "$n" -gt 0 ]; do
  arg=$1; shift; n=$((n - 1))
  case $arg in
    --lab) if [ "$n" -eq 0 ]; then echo "start_openocd: --lab needs a file" >&2; exit 2; fi
           LAB_CONF=$1; shift; n=$((n - 1)); lab_named=1 ;;
    --lab=*) LAB_CONF=${arg#--lab=}; lab_named=1 ;;
    *) set -- "$@" "$arg" ;;
  esac
done
if [ -n "${lab_named:-}" ] && [ ! -f "$LAB_CONF" ]; then echo "start_openocd: lab.conf '$LAB_CONF' does not exist" >&2; exit 2; fi
conf=${LAB_CONF:-$here/lab.conf}
if [ -z "${OPENOCD:-}" ]; then
  if [ ! -f "$conf" ] && [ -z "${LAB_CONF:-}" ]; then conf=$here/lab.conf.example; fi   # no hw/lab.conf: the defaults
  [ -f "$conf" ] || { echo "start_openocd: lab.conf '$conf' does not exist" >&2; exit 2; }
  OPENOCD=$(sed -n 's/^OPENOCD=//p' "$conf" | tail -n 1)
fi
if [ -z "$OPENOCD" ]; then   # the pinned release; its prefix is the one of tools/mpfs-env.sh
  version=$(sed -n 's/^OPENOCD_VERSION=//p' "$here/../tools/toolchain.env")
  prefix=${MPFS_TOOLS_PREFIX:-}
  if [ -z "$prefix" ]; then
    if [ -n "${ADA_MPFS_SDK:-}" ] && [ -d "$ADA_MPFS_SDK/tools-prefix" ]; then prefix=$ADA_MPFS_SDK/tools-prefix
    else prefix=$HOME/.local/share/ada_mpfs/tools; fi
  fi
  OPENOCD=$prefix/openocd-$version
  hint="run ./x toolchain install openocd, or set OPENOCD in $conf"
else
  hint="check OPENOCD in $conf"
fi
bin=$OPENOCD/bin/openocd
[ -x "$bin" ] || { echo "start_openocd: $bin not found or not executable ($hint)" >&2; exit 2; }

# the key $1 of lab.conf.example, overridden by lab.conf where that sets it (a missing file is skipped)
lab_get () {
  v=""
  for f in "$here/lab.conf.example" "$conf"; do
    if [ -f "$f" ] && grep -q "^$1=" "$f"; then v=$(sed -n "s/^$1=//p" "$f" | tail -n 1); fi
  done
  printf '%s' "$v"
}
# the telnet port of OpenOCD is OCD_PORT, the port the scripts of hw/ talk to; with FLASHPRO_SERIAL (lab.conf, or
# the environment variable of that name) OpenOCD takes the embedded FlashPro6 with that serial number, so
# that several boards can be connected. Both come before the arguments of the caller, who has the last word.
port=$(lab_get OCD_PORT)
case $port in ''|*[!0-9]*) echo "start_openocd: OCD_PORT must be a number, got '$port'" >&2; exit 2 ;; esac
serial=${FLASHPRO_SERIAL:-$(lab_get FLASHPRO_SERIAL)}
case $serial in *[!A-Za-z0-9]*) echo "start_openocd: FLASHPRO_SERIAL '$serial' is not a serial number (letters and digits)" >&2; exit 2 ;; esac
location=${FLASHPRO_USB_LOCATION:-$(lab_get FLASHPRO_USB_LOCATION)}
if [ -n "$location" ] && ! printf '%s' "$location" | grep -Eq '^[0-9]+-[0-9]+(\.[0-9]+)*$'; then
  echo "start_openocd: FLASHPRO_USB_LOCATION '$location' is not a USB location (bus, '-', port and further ports after dots, such as 1-2.3)" >&2
  exit 2
fi
tck=${OCD_TCK_MHZ:-$(lab_get OCD_TCK_MHZ)}
case $tck in *[!0-9]*|0*) echo "start_openocd: OCD_TCK_MHZ '$tck' is not a JTAG clock in whole MHz (such as 4)" >&2; exit 2 ;; esac
model=${FLASHPRO_TYPE:-$(lab_get FLASHPRO_TYPE)}
how="FLASHPRO_TYPE"
if [ -z "$model" ]; then
  seen=$("${MPFS_PYTHON:-python3}" "$here/flashpros.py" --model ${serial:+--serial "$serial"} ${location:+--location "$location"} \
           --sysfs "${FLASHPRO_SYSFS:-/sys/bus/usb/devices}" 2>/dev/null) || seen=""
  if [ -z "$seen" ] && { [ -n "$serial" ] || [ -n "$location" ]; }; then   # what was asked for is not there: the model of what is
    seen=$("${MPFS_PYTHON:-python3}" "$here/flashpros.py" --model --sysfs "${FLASHPRO_SYSFS:-/sys/bus/usb/devices}" 2>/dev/null) || seen=""
  fi
  case $seen in
    "") model=efp6; how="assumed: none seen in the USB sysfs" ;;   # OpenOCD may run elsewhere, or the adapter is not connected yet
    *[!a-z0-9]*) echo "start_openocd: several models of FlashPro are connected ($(echo $seen)): set FLASHPRO_SERIAL, FLASHPRO_USB_LOCATION or FLASHPRO_TYPE" >&2; exit 2 ;;
    unknown) echo "start_openocd: the FlashPro has a USB product ID that hw/flashpros.py does not know: set FLASHPRO_TYPE to efp6, fp6, efp5 or fp5 (./x hw flashpros shows what is connected)" >&2; exit 2 ;;
    *) model=$seen; how="told from the USB product ID" ;;
  esac
fi
case $model in   # the interface file, and the command that takes the serial number
  efp6) iface=embedded_flashpro6.cfg; serial_cmd="mchp_efp6 serial" ;;
  fp6)  iface=flashpro6.cfg;  serial_cmd="mchp_fp6 serial" ;;
  efp5) iface=embedded_flashpro5.cfg; serial_cmd="adapter serial" ;;
  fp5)  iface=flashpro5.cfg;  serial_cmd="adapter serial" ;;
  *) echo "start_openocd: FLASHPRO_TYPE '$model' is none of efp6, fp6, efp5, fp5" >&2; exit 2 ;;
esac
# say which FlashPro this is: the model, and the serial number and USB location it was told, or else what is connected
# (flashpros.py --adapters: "SERIAL LOCATION" per adapter of the model, "-" where the descriptor has no serial number)
adapters=$("${MPFS_PYTHON:-python3}" "$here/flashpros.py" --adapters "$model" \
             --sysfs "${FLASHPRO_SYSFS:-/sys/bus/usb/devices}" 2>/dev/null) || adapters=""
count=$(printf '%s\n' "$adapters" | awk 'NF { n++ } END { print n + 0 }')
connected=$(printf '%s\n' "$adapters" | awk 'NF && $1 != "-" { print $1 }')
where=$(printf '%s\n' "$adapters" | awk 'NF { print $2 }')
list=$(printf '%s\n' "$adapters" | awk 'NF { s = s (s == "" ? "" : ", ") ($1 == "-" ? $2 " (no serial number)" : $1) } END { print s }')
about=""
if [ -n "$serial" ]; then
  about="serial $serial"
  case " $(echo $connected) " in *" $serial "*) ;; *) [ "$count" -eq 0 ] || about="$about (not among the connected $model: $list)" ;; esac
fi
if [ -n "$location" ]; then
  about="${about:+$about, }USB location $location"
  case " $(echo $where) " in *" $location "*) ;; *) [ "$count" -eq 0 ] || about="$about (not among the connected $model at $(echo $where | sed 's/ /, /g'))" ;; esac
fi
if [ -z "$serial" ] && [ -z "$location" ]; then
  if [ "$count" -eq 0 ]; then about="no serial number set, none seen in the USB sysfs: OpenOCD takes the one it finds"
  elif [ "$count" -eq 1 ] && [ -n "$connected" ]; then about="serial $connected (the only one connected)"
  elif [ "$count" -eq 1 ]; then about="no serial number in its USB descriptor, USB location $where (the only one connected)"
  else about="no serial number set, $count connected ($list): OpenOCD takes the first it finds (set FLASHPRO_SERIAL or FLASHPRO_USB_LOCATION)"
  fi
fi
echo "start_openocd: FlashPro model $model ($how), $about" >&2
set -- -c "telnet_port $port" "$@"
if [ -n "$serial" ]; then set -- -c "$serial_cmd $serial" "$@"; fi
if [ -n "$location" ]; then set -- -c "adapter usb location $location" "$@"; fi
if [ -n "$tck" ]; then   # after the interface file (adapter speed 6000), so it wins; before the target file, which runs init
  set -- -c "adapter speed $((tck * 1000))" "$@"
  echo "start_openocd: JTAG clock $tck MHz (adapter speed $((tck * 1000)) kHz, OCD_TCK_MHZ)" >&2
fi
grace=${START_OPENOCD_GRACE:-3}
case $grace in ''|*[!0-9]*) echo "start_openocd: START_OPENOCD_GRACE must be a number of seconds, got '$grace'" >&2; exit 2 ;; esac

signalled=""   # the exit status for the signal that arrived, set by the traps
again=""       # set by a second signal while OpenOCD is being stopped
stopping=""
trap 'if [ -n "$stopping" ]; then again=1; fi; signalled=130' INT
trap 'if [ -n "$stopping" ]; then again=1; fi; signalled=143' TERM
trap 'if [ -n "$stopping" ]; then again=1; fi; signalled=129' HUP

# The board file of OpenOCD is this interface file and the target file, and the target script runs init (to read
# the IDCODE): what has to come before init (the arguments of the caller, with the telnet port and the serial number
# in front of them) goes between the two.
"$bin" -s "$OPENOCD/openocd/scripts" \
       --command "set DEVICE MPFS" --file "interface/$iface" "$@" \
       --file target/microchip_riscv.cfg &
child=$!

status=0
wait "$child" || status=$?   # returns early (status > 128) when a trapped signal arrives

if [ -n "$signalled" ]; then
  stopping=1
  echo "start_openocd: stopping OpenOCD (killing it after ${grace} s)" >&2
  kill -TERM "$child" 2>/dev/null || true
  # the timer kills OpenOCD when it has not ended after the grace period; it is cancelled with SIGKILL,
  # which cannot be lost the way a trapped signal can (its sleep ends by itself, a few seconds at most)
  sh -c 'sleep "$1"; kill -KILL "$2" 2>/dev/null' timer "$grace" "$child" >/dev/null 2>&1 </dev/null &
  timer=$!
  wait "$child" 2>/dev/null || true
  if [ -n "$again" ]; then   # a second signal: do not wait any longer
    echo "start_openocd: second signal, killing OpenOCD" >&2
    kill -KILL "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
  fi
  kill -KILL "$timer" 2>/dev/null || true   # OpenOCD ended (or was killed): the timer is not needed
  wait "$timer" 2>/dev/null || true
  exit "$signalled"
fi
exit "$status"
