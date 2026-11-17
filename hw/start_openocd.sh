#!/bin/sh
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Start Microchip's OpenOCD against the embedded FlashPro6 of an Icicle Kit. The distribution's own
# OpenOCD (0.12) lacks the driver for it.
#
#   start_openocd.sh [openocd arguments]
#
# The install directory of that OpenOCD (bin/openocd, openocd/scripts) is OPENOCD of hw/lab.conf
# (hw/lab.conf.example if there is none, or the file named by LAB_CONF); the environment variable OPENOCD
# overrides both. If it is empty, the release pinned in tools/toolchain.env is used, from its prefix
# ($MPFS_TOOLS_PREFIX/openocd-<version>) where ./x toolchain install openocd puts it. Telnet is on :4444,
# gdb on :3333. A missing OpenOCD is an error with the path that was tried.
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
grace=${START_OPENOCD_GRACE:-3}
case $grace in ''|*[!0-9]*) echo "start_openocd: START_OPENOCD_GRACE must be a number of seconds, got '$grace'" >&2; exit 2 ;; esac

signalled=""   # the exit status for the signal that arrived, set by the traps
again=""       # set by a second signal while OpenOCD is being stopped
stopping=""
trap 'if [ -n "$stopping" ]; then again=1; fi; signalled=130' INT
trap 'if [ -n "$stopping" ]; then again=1; fi; signalled=143' TERM
trap 'if [ -n "$stopping" ]; then again=1; fi; signalled=129' HUP

# The board file of OpenOCD is this interface file and the target file, and the target script runs init (to read
# the IDCODE): what has to come before init (the arguments of the caller) goes between the two.
"$bin" -s "$OPENOCD/openocd/scripts" \
       --command "set DEVICE MPFS" --file interface/embedded_flashpro6.cfg "$@" \
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
