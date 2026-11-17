#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Tests for the scripts of hw/ and ./x hw without a board: a stand-in for the OpenOCD
# telnet port (fake_ocd.py), files in place of the serial ports, a stand-in for
# OpenOCD installation, a stand-in for fpgenprog (fake_fpgenprog.py), and the pinned RISC-V
# toolchain for the images and probes. Every
# --expect that does not match must exit 1, every set-up error 2, and the cases that
# match show that the stand-ins are not what makes the others fail. What this cannot
# show: that a real OpenOCD, FlashPro6 and CP2108 behave like the stand-ins. Exits
# non-zero on any failure.
# @verifies BLD-001

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HW="$ROOT/hw"
fails=0

pass () { echo "ok:   $1"; }
fail () { echo "FAIL: $1" >&2; fails=$((fails + 1)); }

# expect_rc <description> <exit status|nonzero> <command...>
expect_rc () {
  local desc="$1" want="$2"; shift 2
  "$@" >/dev/null 2>&1
  local rc=$?
  if { [ "$want" = nonzero ] && [ $rc -ne 0 ]; } || [ "$rc" = "$want" ]; then
    pass "$desc"
  else
    fail "$desc (exit $rc, wanted $want)"
  fi
}

expect_out () {
  local desc="$1" needle="$2"; shift 2
  local out
  out="$("$@" 2>&1)"
  case "$out" in *"$needle"*) pass "$desc" ;; *) fail "$desc (no '$needle' in: $out)" ;; esac
}

. "$ROOT/tools/mpfs-env.sh"
mpfs_toolchain_on_path >/dev/null 2>&1 || true
mpfs_find_python
PY="$MPFS_PYTHON"
tc="$(ls -d "$MPFS_ADA_TOOLCHAINS"/gnat_riscv64_elf_"$GNAT_RISCV64_VERSION"_*/bin 2>/dev/null | head -n 1)"
[ -n "$tc" ] || { echo "FAIL: the pinned gnat_riscv64_elf $GNAT_RISCV64_VERSION is not installed (./x toolchain install gnat)" >&2; exit 1; }

tmp="$(mktemp -d)"
pids=()
cleanup () { for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done; rm -r "$tmp"; }
trap cleanup EXIT
mkdir -p "$tmp/uart" "$tmp/ocd"

# a sysfs with FlashPros (FLASHPRO_SYSFS) for the tests that derive the name of a FlashPro5 from its serial number
mkusb () { mkdir -p "$1/$2"; echo "$3" > "$1/$2/idVendor"; echo "$4" > "$1/$2/idProduct"; echo "$5" > "$1/$2/product"; echo "$6" > "$1/$2/serial"; }
mkusb "$tmp/usb-efp6" 1-1 1514 200b "Embedded FP6b" EFP6A1
mkusb "$tmp/usb-fp5" 1-1 1514 2008 "FlashPro5" FP5A1

# The image: an endless loop at the start of the LIM.
printf '\t.globl _start\n_start:\n\tj _start\n' > "$tmp/loop.S"
"$tc/riscv64-elf-gcc" -march=rv64imac_zicsr -mabi=lp64 -nostdlib -Wl,-Ttext=0x80000000 -o "$tmp/loop.elf" "$tmp/loop.S" \
  || { echo "FAIL: cannot build the test image" >&2; exit 1; }

# serve <name> [fake_ocd options...]: a stand-in OpenOCD; sets $<name>_port. The UART
# files are tmp/uart/<name>/mmuart<n>.log; lab-<name>.conf points at both.
serve () {
  local name="$1"; shift
  mkdir -p "$tmp/uart/$name"
  for n in 0 1 2 3; do : > "$tmp/uart/$name/mmuart$n.log"; done
  : > "$tmp/$name.log"
  "$PY" "$ROOT/tests/host/hw/fake_ocd.py" "$tmp/$name.port" "$tmp/$name.log" "$@" &
  pids+=($!)
  local i
  for i in $(seq 1 50); do [ -s "$tmp/$name.port" ] && break; sleep 0.1; done
  [ -s "$tmp/$name.port" ] || { echo "FAIL: the stand-in OpenOCD did not start" >&2; exit 1; }
  printf 'OPENOCD=%s\nOCD_PORT=%s\nUART_PATTERN=%s\nUART_COUNT=4\n' "$tmp/ocd" "$(cat "$tmp/$name.port")" "$tmp/uart/$name/mmuart{n}.log" > "$tmp/lab-$name.conf"
}

run_image () { "$PY" "$HW/run_image.py" "$@"; }

# --- run_image.py -----------------------------------------------------------------
# the serial text is shown as a block: one gutter line per line printed, CR LF ends a line, odd bytes are escaped
fmt () { "$PY" -c 'import sys; sys.path.insert(0, sys.argv[1]); import serialview; print(serialview.format_block(int(sys.argv[2]), eval(sys.argv[3])))' "$HW" "$@"; }
want=$'MMUART0 (38 bytes):\n  | TEST t: START\n  |   ok: x\n  | TEST t: PASS'
[ "$(fmt 0 "b'TEST t: START\\r\\n  ok: x\\r\\nTEST t: PASS\\r\\n'")" = "$want" ] && pass "serialview: shows the serial text as a block, one line per line printed" || fail "run_image: shows the serial text as a block, one line per line printed"
[ "$(fmt 1 "b'no end'")" = $'MMUART1 (6 bytes):\n  | no end   [no line end]' ] && pass "serialview: marks a last line without a line end" || fail "run_image: marks a last line without a line end"
[ "$(fmt 2 "b'a\\x00\\xffb\\rc'")" = $'MMUART2 (6 bytes):\n  | a\\x00\\xffb\n  | c   [no line end]' ] && pass "serialview: escapes bytes that are not printable and ends a line at a lone CR" || fail "run_image: escapes bytes that are not printable and ends a line at a lone CR"
serve hello --uart "$tmp/uart/hello/mmuart0.log" --print "bare hello E51 hart 0"
L="$tmp/lab-hello.conf"
expect_rc  "run_image: runs an image and exits 0 without --expect" 0 run_image "$tmp/loop.elf" 0 --secs 0.4 --lab "$L"
out="$(run_image "$tmp/loop.elf" 0 --secs 0.4 --lab "$L" 2>&1)"
case "$out" in *"bare hello E51 hart 0"*) pass "run_image: prints what the serial port showed" ;; *) fail "run_image: prints what the serial port showed ($out)" ;; esac
case "$out" in *"first trap: none"*) pass "run_image: reports no trap" ;; *) fail "run_image: reports no trap ($out)" ;; esac
grep -q '^targets mpfs.hart0_e51$' "$tmp/hello.log" && pass "run_image: selects the E51 for hart 0" || fail "run_image: selects the E51 for hart 0"
grep -q '^load_image .* 0x7ffff000 bin$' "$tmp/hello.log" && pass "run_image: loads the segment at its address (the one that holds the code, headers included)" || fail "run_image: loads the segment at its address"
grep -q '^load_image .* 0x8100000 bin$' "$tmp/hello.log" && pass "run_image: loads the trap recorder" || fail "run_image: loads the trap recorder"
grep -q '^reg pc 0x80000000$' "$tmp/hello.log" && pass "run_image: sets pc to the entry point" || fail "run_image: sets pc to the entry point"
grep -q '^resume$' "$tmp/hello.log" && pass "run_image: resumes the hart" || fail "run_image: resumes the hart"
if grep -q '^mww 0x2000' "$tmp/hello.log"; then fail "run_image: leaves the UARTs alone without --uart-standin"; else pass "run_image: leaves the UARTs alone without --uart-standin"; fi
run_image "$tmp/loop.elf" 3 --secs 0.2 --lab "$L" >/dev/null 2>&1
grep -q '^targets mpfs.hart3_u54_3$' "$tmp/hello.log" && pass "run_image: selects U54 hart 3 for hart 3" || fail "run_image: selects U54 hart 3 for hart 3"

expect_rc  "run_image: --expect that matches exits 0" 0 run_image "$tmp/loop.elf" 0 --secs 0.4 --lab "$L" --expect 'bare hello E51 hart [0-9]'
expect_out "run_image: says what matched" "matched /bare hello E51 hart [0-9]/ on MMUART0" run_image "$tmp/loop.elf" 0 --secs 0.4 --lab "$L" --expect 'bare hello E51 hart [0-9]'
expect_rc  "run_image: --expect that does not match exits 1" 1 run_image "$tmp/loop.elf" 0 --secs 0.4 --lab "$L" --expect 'bare hello U54'
expect_out "run_image: says it did not match" "NOT matched /bare hello U54/" run_image "$tmp/loop.elf" 0 --secs 0.4 --lab "$L" --expect 'bare hello U54'
expect_rc  "run_image: --expect-port with the right port matches" 0 run_image "$tmp/loop.elf" 0 --secs 0.4 --lab "$L" --expect 'bare hello' --expect-port 0
expect_rc  "run_image: --expect-port with another port exits 1" 1 run_image "$tmp/loop.elf" 0 --secs 0.4 --lab "$L" --expect 'bare hello' --expect-port 1
expect_rc  "run_image: an invalid --expect regular expression exits 2" 2 run_image "$tmp/loop.elf" 0 --lab "$L" --expect '('
expect_rc  "run_image: an invalid hart exits 2" 2 run_image "$tmp/loop.elf" 5 --lab "$L"
expect_rc  "run_image: a missing ELF exits 2" 2 run_image "$tmp/none.elf" 0 --lab "$L"
printf 'not an ELF file' > "$tmp/bad.elf"
expect_rc  "run_image: a file that is no ELF exits 2" 2 run_image "$tmp/bad.elf" 0 --lab "$L"
expect_rc  "run_image: a missing lab.conf exits 2" 2 run_image "$tmp/loop.elf" 0 --lab "$tmp/none.conf"
printf 'OCD_PORT=abc\n' > "$tmp/lab-badport.conf"
expect_rc  "run_image: a lab.conf with a bad port exits 2" 2 run_image "$tmp/loop.elf" 0 --lab "$tmp/lab-badport.conf"
printf 'UART_PATTERN=/dev/ttyUSB0\n' > "$tmp/lab-nopattern.conf"
expect_rc  "run_image: a UART_PATTERN without {n} exits 2" 2 run_image "$tmp/loop.elf" 0 --lab "$tmp/lab-nopattern.conf"
printf 'OCD_PORT=1\nUART_PATTERN=%s\n' "$tmp/uart/hello/mmuart{n}.log" > "$tmp/lab-noocd.conf"
expect_rc  "run_image: no OpenOCD on the port exits 2" 2 run_image "$tmp/loop.elf" 0 --lab "$tmp/lab-noocd.conf"
expect_out "run_image: says how to start OpenOCD" "./x hw openocd" run_image "$tmp/loop.elf" 0 --lab "$tmp/lab-noocd.conf"
printf 'OCD_PORT=%s\nUART_PATTERN=%s\n' "$(cat "$tmp/hello.port")" "$tmp/uart/hello/none{n}.log" > "$tmp/lab-noport.conf"
expect_rc  "run_image: a serial port that does not exist exits 2" 2 run_image "$tmp/loop.elf" 0 --lab "$tmp/lab-noport.conf"
mkdir -p "$tmp/emptytc"
expect_rc  "run_image: without the pinned toolchain it exits 2" 2 env MPFS_ADA_TOOLCHAINS="$tmp/emptytc" "$PY" "$HW/run_image.py" "$tmp/loop.elf" 0 --lab "$L"
expect_out "run_image: names the pinned version" "gnat_riscv64_elf $GNAT_RISCV64_VERSION" env MPFS_ADA_TOOLCHAINS="$tmp/emptytc" "$PY" "$HW/run_image.py" "$tmp/loop.elf" 0 --lab "$L"
# Another version of the compiler installed does not stand in for the pinned one.
mkdir -p "$tmp/othertc/gnat_riscv64_elf_1.0.0_deadbeef/bin"
expect_rc  "run_image: another version of the compiler is not accepted" 2 env MPFS_ADA_TOOLCHAINS="$tmp/othertc" "$PY" "$HW/run_image.py" "$tmp/loop.elf" 0 --lab "$L"

# --uart-standin programs the UARTs
: > "$tmp/hello.log"
run_image "$tmp/loop.elf" 0 --secs 0.2 --lab "$L" --uart-standin --div 20 >/dev/null 2>&1
grep -q '^mww 0x20000000 20;\|mww 0x20000000 20' "$tmp/hello.log" && grep -q '^mww 0x20002084 ' "$tmp/hello.log" \
  && pass "run_image: --uart-standin clocks the UARTs and programs the divisor" \
  || fail "run_image: --uart-standin clocks the UARTs and programs the divisor"

# --uart-clocks clocks and releases the UARTs and writes no register of one of them
: > "$tmp/hello.log"
run_image "$tmp/loop.elf" 0 --secs 0.2 --lab "$L" --uart-clocks >/dev/null 2>&1
if grep -q '^mww 0x20002084 ' "$tmp/hello.log" && grep -q '^mww 0x20002088 ' "$tmp/hello.log" && ! grep -q 'mww 0x2000000c\|mww 0x20000000 ' "$tmp/hello.log"; then
  pass "run_image: --uart-clocks clocks and releases the UARTs and leaves their registers alone"
else
  fail "run_image: --uart-clocks clocks and releases the UARTs and leaves their registers alone"
fi

# nothing printed at all, and a trap
serve silent
expect_rc  "run_image: --expect without any serial output exits 1" 1 run_image "$tmp/loop.elf" 0 --secs 0.3 --lab "$tmp/lab-silent.conf" --expect 'bare hello'
expect_out "run_image: says there was no serial output" "no serial output" run_image "$tmp/loop.elf" 0 --secs 0.3 --lab "$tmp/lab-silent.conf" --expect 'bare hello'
expect_out "run_image: hints at --uart-standin when silent" "needs --uart-standin" run_image "$tmp/loop.elf" 0 --secs 0.3 --lab "$tmp/lab-silent.conf"
expect_rc  "run_image: no serial output and no --expect exits 0" 0 run_image "$tmp/loop.elf" 0 --secs 0.3 --lab "$tmp/lab-silent.conf"
serve trapped --trap --uart "$tmp/uart/trapped/mmuart0.log" --print "partial output"
expect_out "run_image: reports the first trap" "first trap: mcause=0x2 mepc=0x1234" run_image "$tmp/loop.elf" 0 --secs 0.3 --lab "$tmp/lab-trapped.conf"

# --- run_probe.py -----------------------------------------------------------------
serve probe --result 0x1234
LP="$tmp/lab-probe.conf"
run_probe () { "$PY" "$HW/run_probe.py" "$@"; }
expect_rc  "run_probe: runs a probe and exits 0 without --expect" 0 run_probe probe_time.S 1 --secs 0.2 --words 2 --lab "$LP"
expect_out "run_probe: prints the result block" "[ 0] = 0x1234" run_probe probe_time.S 1 --secs 0.2 --words 2 --lab "$LP"
expect_rc  "run_probe: --expect that matches exits 0" 0 run_probe probe_time.S 1 --secs 0.2 --lab "$LP" --expect '\[ 0\] = 0x1234'
expect_rc  "run_probe: --expect that does not match exits 1" 1 run_probe probe_time.S 1 --secs 0.2 --lab "$LP" --expect '\[ 0\] = 0x9999'
grep -q '^targets mpfs.hart1_u54_1$' "$tmp/probe.log" && grep -q '^riscv set_prefer_sba off$' "$tmp/probe.log" \
  && pass "run_probe: selects the hart and the program buffer" || fail "run_probe: selects the hart and the program buffer"
expect_rc  "run_probe: an unknown probe exits 2" 2 run_probe probe_none.S 1 --lab "$LP"
expect_rc  "run_probe: an invalid hart exits 2" 2 run_probe probe_time.S 7 --lab "$LP"
expect_rc  "run_probe: an invalid --expect exits 2" 2 run_probe probe_time.S 1 --lab "$LP" --expect '['
expect_rc  "run_probe: no OpenOCD exits 2" 2 run_probe probe_time.S 1 --lab "$tmp/lab-noocd.conf"
expect_rc  "run_probe: without the pinned toolchain it exits 2" 2 env MPFS_ADA_TOOLCHAINS="$tmp/emptytc" "$PY" "$HW/run_probe.py" probe_time.S 1 --lab "$LP"

# every probe and the trap recorder assemble with the pinned compiler
for s in trap probe_irq probe_plic probe_time; do
  expect_rc "$s.S assembles" 0 "$tc/riscv64-elf-gcc" -march=rv64imac_zicsr -mabi=lp64 -nostdlib -c "$HW/$s.S" -o "$tmp/$s.o"
done

# --- monitor.py -------------------------------------------------------------------
mkdir -p "$tmp/uart/mon"
for n in 0 1 2 3; do : > "$tmp/uart/mon/mmuart$n.log"; done
printf 'hello from MMUART1\r\n' > "$tmp/uart/mon/mmuart1.log"
printf 'OPENOCD=%s\nOCD_PORT=1\nUART_PATTERN=%s\nUART_COUNT=4\n' "$tmp/ocd" "$tmp/uart/mon/mmuart{n}.log" > "$tmp/lab-mon.conf"
monitor () { "$PY" "$HW/monitor.py" "$@"; }
expect_rc  "monitor: shows the ports and exits 0 without --expect" 0 monitor --secs 0.3 --lab "$tmp/lab-mon.conf"
expect_out "monitor: names the port that printed" "MMUART1:" monitor --secs 0.3 --lab "$tmp/lab-mon.conf"
expect_rc  "monitor: --expect that matches exits 0" 0 monitor --secs 0.3 --lab "$tmp/lab-mon.conf" --expect 'hello from MMUART[0-9]'
expect_rc  "monitor: --expect that does not match exits 1" 1 monitor --secs 0.3 --lab "$tmp/lab-mon.conf" --expect 'goodbye'
expect_rc  "monitor: --port selects one port (nothing on port 0: no match)" 1 monitor --secs 0.3 --lab "$tmp/lab-mon.conf" --port 0 --expect 'hello'
expect_rc  "monitor: --port with the port that printed matches" 0 monitor --secs 0.3 --lab "$tmp/lab-mon.conf" --port 1 --expect 'hello'
expect_rc  "monitor: a port outside the range exits 2" 2 monitor --secs 0.3 --lab "$tmp/lab-mon.conf" --port 9
expect_rc  "monitor: a serial port that does not exist exits 2" 2 monitor --secs 0.3 --lab "$tmp/lab-noport.conf"

# --- TCP UARTs (a socat on another machine tunnels the UART to a TCP port) ---------------
# tcp_serve <name> <steps...>: a stand-in UART (fake_uart.py) on a free port, which is then $tmp/<name>.tport
tcp_serve () {
  local name="$1"; shift
  "$PY" "$ROOT/tests/host/hw/fake_uart.py" "$tmp/$name.tport" "$@" &
  pids+=($!)
  local i
  for i in $(seq 1 50); do [ -s "$tmp/$name.tport" ] && break; sleep 0.1; done
  [ -s "$tmp/$name.tport" ] || { echo "FAIL: the stand-in UART did not start" >&2; exit 1; }
}
# tconf <file> <lines...>: a lab.conf with the stand-in OpenOCD of "hello" and the given lines
tconf () { local f="$1"; shift; { printf 'OPENOCD=%s\nOCD_PORT=%s\n' "$tmp/ocd" "$(cat "$tmp/hello.port")"; printf '%s\n' "$@"; } > "$f"; }
# has_all <text> <needle>...: every needle is a line of the text, whatever the order
has_all () { local t="$1" n; shift; for n in "$@"; do printf '%s\n' "$t" | grep -qxF -- "$n" || return 1; done; }
# errlines <command...>: the standard error of the command: the text in $err, its number of lines in $nerr
errlines () { err="$("$@" 2>&1 >/dev/null)"; nerr=$(printf '%s\n' "$err" | grep -c .); }

tcp_serve one 'send=b"hello over tcp\r\n"' 'sleep=0.3'
tcp_serve two 'send=b"second port\r\n"' 'hold'
P1="$(cat "$tmp/one.tport")"; P2="$(cat "$tmp/two.tport")"
tconf "$tmp/lab-tcp1.conf" 'UART_COUNT=1' "UART0=tcp:127.0.0.1:$P1"
expect_rc  "monitor: reads a UART from a TCP port" 0 monitor --secs 0.6 --lab "$tmp/lab-tcp1.conf" --expect 'hello over tcp'
expect_rc  "monitor: the text of a TCP port that does not match exits 1" 1 monitor --secs 0.6 --lab "$tmp/lab-tcp1.conf" --expect 'not printed'
expect_out "monitor: shows the text of the TCP port" "hello over tcp" monitor --secs 0.6 --lab "$tmp/lab-tcp1.conf"
tconf "$tmp/lab-tcp2.conf" 'UART_COUNT=1' "UART0=tcp://127.0.0.1:$P1"
expect_rc  "monitor: the tcp:// form of the endpoint works too" 0 monitor --secs 0.6 --lab "$tmp/lab-tcp2.conf" --expect 'hello over tcp'
expect_rc  "run_image: reads a UART from a TCP port" 0 run_image "$tmp/loop.elf" 0 --secs 0.5 --lab "$tmp/lab-tcp1.conf" --expect 'hello over tcp'
# mixed: MMUART1 is a file, MMUART0 and MMUART2 are TCP ports (one of them silent but open, which must not hold up the others)
tconf "$tmp/lab-mixed.conf" 'UART_COUNT=3' "UART_PATTERN=$tmp/uart/mon/mmuart{n}.log" "UART0=tcp:127.0.0.1:$P1" "UART2=tcp:127.0.0.1:$P2"
out="$(monitor --secs 0.6 --lab "$tmp/lab-mixed.conf" 2>&1)"
has_all "$out" 'MMUART0: hello over tcp' 'MMUART1: hello from MMUART1' 'MMUART2: second port' && pass "monitor: a mixed configuration shows device and TCP ports" || fail "monitor: a mixed configuration shows device and TCP ports ($out)"
expect_rc  "monitor: --port selects a TCP port of a mixed configuration" 0 monitor --secs 0.6 --lab "$tmp/lab-mixed.conf" --port 2 --expect 'second port'
expect_rc  "monitor: --port selects one port of a mixed configuration only" 1 monitor --secs 0.6 --lab "$tmp/lab-mixed.conf" --port 2 --expect 'hello from MMUART1'
# a pattern with {n} in the port number: 500{n}
base="$("$PY" -c '
import socket, random
while True:
    b = random.randrange(20000, 60000, 10)
    ss = []
    try:
        for k in range(4):
            s = socket.socket(); s.bind(("127.0.0.1", b + k)); ss.append(s)
    except OSError:
        continue
    print(b); break')"
for n in 0 1 2 3; do
  "$PY" "$ROOT/tests/host/hw/fake_uart.py" "$tmp/pat$n.tport" --listen $((base + n)) "send=b\"port $n\\r\\n\"" 'sleep=0.3' &
  pids+=($!)
done
for n in 0 1 2 3; do for i in $(seq 1 50); do [ -s "$tmp/pat$n.tport" ] && break; sleep 0.1; done; done
tconf "$tmp/lab-pat.conf" 'UART_COUNT=4' "UART_PATTERN=tcp://127.0.0.1:${base%?}{n}"
out="$(monitor --secs 0.6 --lab "$tmp/lab-pat.conf" 2>&1)"
has_all "$out" 'MMUART0: port 0' 'MMUART1: port 1' 'MMUART2: port 2' 'MMUART3: port 3' && pass "monitor: {n} in the port of UART_PATTERN gives one port per MMUART" || fail "monitor: {n} in the port of UART_PATTERN gives one port per MMUART ($out)"
expect_rc  "monitor: --port 3 with a TCP pattern reads only that port" 1 monitor --secs 0.6 --lab "$tmp/lab-pat.conf" --port 3 --expect 'port 2'
# the connection ends in the middle of the run: reported once, the other port goes on, no traceback
tcp_serve early 'send=b"before the end\r\n"' 'sleep=0.2'
tcp_serve late 'sleep=0.8' 'send=b"after the end\r\n"' 'hold'
tconf "$tmp/lab-drop.conf" 'UART_COUNT=2' "UART0=tcp:127.0.0.1:$(cat "$tmp/early.tport")" "UART1=tcp:127.0.0.1:$(cat "$tmp/late.tport")"
out="$(monitor --secs 1.3 --lab "$tmp/lab-drop.conf" --expect '(?s)before the end.*after the end' 2>"$tmp/drop.err")"; rc=$?
nerr=$(grep -c . "$tmp/drop.err"); err="$(cat "$tmp/drop.err")"
[ "$nerr" = 1 ] && case "$err" in *"MMUART0"*"tcp://127.0.0.1:$(cat "$tmp/early.tport")"*"closed the connection"*) true ;; *) false ;; esac \
  && pass "monitor: a connection that ends during the run is reported once, with the port and the endpoint" \
  || fail "monitor: a connection that ends during the run is reported once, with the port and the endpoint ($nerr lines: $err)"
[ $rc = 0 ] && pass "monitor: the text of a connection that ended still counts, and the other port goes on after it (--expect over both, exit 0)" || fail "monitor: the text of a connection that ended still counts, and the other port goes on ($rc: $out)"
tcp_serve rst 'send=b"part\r\n"' 'sleep=0.2' 'reset'
tconf "$tmp/lab-rst.conf" 'UART_COUNT=1' "UART0=tcp:127.0.0.1:$(cat "$tmp/rst.tport")"
errlines monitor --secs 0.8 --lab "$tmp/lab-rst.conf" --expect 'part'
[ "$nerr" = 1 ] && case "$err" in *Traceback*) false ;; *"MMUART0"*"lost"*) true ;; *) false ;; esac \
  && pass "monitor: a reset connection is reported once as lost, not as a traceback" \
  || fail "monitor: a reset connection is reported once as lost, not as a traceback ($nerr lines: $err)"
# set-up errors: one line each that names the port and the endpoint, exit status 2
tconf "$tmp/lab-refused.conf" 'UART_COUNT=2' "UART_PATTERN=$tmp/uart/mon/mmuart{n}.log" 'UART1=tcp:127.0.0.1:1'
expect_rc  "monitor: a refused TCP connection exits 2" 2 monitor --secs 0.3 --lab "$tmp/lab-refused.conf"
errlines monitor --secs 0.3 --lab "$tmp/lab-refused.conf"
[ "$nerr" = 1 ] && case "$err" in *"MMUART1"*"tcp://127.0.0.1:1"*"refused"*) true ;; *) false ;; esac \
  && pass "monitor: a refused connection is one line that names the port, the endpoint and the reason" \
  || fail "monitor: a refused connection is one line that names the port, the endpoint and the reason ($nerr lines: $err)"
errlines run_image "$tmp/loop.elf" 0 --secs 0.2 --lab "$tmp/lab-refused.conf"
[ "$nerr" = 1 ] && case "$err" in *"MMUART1"*"tcp://127.0.0.1:1"*) true ;; *) false ;; esac \
  && pass "run_image: a refused connection is one line that names the port and the endpoint" \
  || fail "run_image: a refused connection is one line that names the port and the endpoint ($nerr lines: $err)"
expect_rc  "run_image: a refused TCP connection exits 2" 2 run_image "$tmp/loop.elf" 0 --secs 0.2 --lab "$tmp/lab-refused.conf"
tconf "$tmp/lab-dns.conf" 'UART_COUNT=1' 'UART0=tcp://no-such-host.invalid:5000'
expect_rc  "monitor: a host name that does not resolve exits 2" 2 monitor --secs 0.3 --lab "$tmp/lab-dns.conf"
errlines monitor --secs 0.3 --lab "$tmp/lab-dns.conf"
[ "$nerr" = 1 ] && case "$err" in *Traceback*) false ;; *"MMUART0"*"tcp://no-such-host.invalid:5000"*) true ;; *) false ;; esac \
  && pass "monitor: an unresolvable host is one line that names the port and the endpoint" \
  || fail "monitor: an unresolvable host is one line that names the port and the endpoint ($nerr lines: $err)"
# lab.conf: the keys
tconf "$tmp/lab-badtcp.conf" 'UART_COUNT=1' 'UART0=tcp:localhost'
expect_rc  "lab.conf: a TCP endpoint without a port exits 2" 2 monitor --secs 0.3 --lab "$tmp/lab-badtcp.conf"
tconf "$tmp/lab-badtcp.conf" 'UART_COUNT=1' 'UART0=tcp:localhost:70000'
expect_rc  "lab.conf: a TCP port above 65535 exits 2" 2 monitor --secs 0.3 --lab "$tmp/lab-badtcp.conf"
tconf "$tmp/lab-badtcp.conf" 'UART_COUNT=2' 'UART5=tcp:localhost:5000'
expect_rc  "lab.conf: a UART<n> outside UART_COUNT exits 2" 2 monitor --secs 0.3 --lab "$tmp/lab-badtcp.conf"
tconf "$tmp/lab-badtcp.conf" 'UART_COUNT=2' 'UART_PATTERN=/dev/ttyUSB0' "UART0=tcp:127.0.0.1:$P1"
expect_rc  "lab.conf: UART_PATTERN without {n} exits 2 while a port still needs it" 2 monitor --secs 0.3 --lab "$tmp/lab-badtcp.conf"
tconf "$tmp/lab-badtcp.conf" 'UART_COUNT=2' 'UART_PATTERN=/dev/ttyUSB0' "UART0=tcp:127.0.0.1:$P1" "UART1=tcp:127.0.0.1:$P2"
expect_rc  "lab.conf: UART_PATTERN needs no {n} when every port has its UART<n>" 0 monitor --secs 0.3 --lab "$tmp/lab-badtcp.conf"
"$PY" - "$HW" <<'PYEOF' && pass "lab.py: the endpoint forms (tcp:, tcp://, [IPv6], {n}, device) and what it rejects" || fail "lab.py: the endpoint forms (tcp:, tcp://, [IPv6], {n}, device) and what it rejects"
import sys
sys.path.insert(0, sys.argv[1])
import lab
E = lab.Endpoint
assert lab.parse_endpoint("tcp:h:5000", 0) == E("tcp", host="h", port=5000)
assert lab.parse_endpoint("tcp://h:5000", 0) == E("tcp", host="h", port=5000)
assert lab.parse_endpoint("tcp://[::1]:5000", 0) == E("tcp", host="::1", port=5000)
assert str(lab.parse_endpoint("tcp://[::1]:5000", 0)) == "tcp://[::1]:5000"
assert lab.parse_endpoint("tcp://lab-pc:500{n}", 3) == E("tcp", host="lab-pc", port=5003)
assert lab.parse_endpoint("tcp://lab-{n}:5000", 2) == E("tcp", host="lab-2", port=5000)
assert lab.parse_endpoint("/dev/ttyUSB{n}", 1) == E("device", path="/dev/ttyUSB1")
for bad in ("tcp:", "tcp:h", "tcp://h:", "tcp://:5000", "tcp://h:0", "tcp://h:65536", "tcp://h:5x", "tcp://h/x:5", "  "):
    try:
        lab.parse_endpoint(bad, 0)
    except SystemExit as e:
        assert isinstance(e.code, str) and e.code.startswith("lab:"), e.code
    else:
        raise AssertionError(f"accepted {bad!r}")
conf = {"UART_PATTERN": "/nonexistent/{n}", "UART2": "tcp:h:5002", "UART_COUNT": "3"}
try:
    lab.uart_endpoints(conf, [0, 2])
except SystemExit as e:
    assert "MMUART0" in e.code, e.code
else:
    raise AssertionError("a missing device was accepted")
assert lab.uart_endpoints(conf, [2]) == {2: E("tcp", host="h", port=5002)}
PYEOF

# --- serial views: interleaved and blocks, UTF-8, colours, escape sequences -------------------
# The stdout of these runs is a pipe, so the default view is interleaved. vconf <name> <printf format>: a lab.conf with
# one port whose "UART" is a file that holds the bytes (printf format, \ooo octal escapes); vmon <name> <args...>: monitor on it.
ESC=$'\033'
mkdir -p "$tmp/uart/v"
vconf () { printf -- "$2" > "$tmp/uart/v/$1.log"; printf 'OPENOCD=%s\nOCD_PORT=1\nUART_COUNT=1\nUART0=%s\n' "$tmp/ocd" "$tmp/uart/v/$1.log" > "$tmp/lab-v-$1.conf"; }
vmon () { local n="$1"; shift; monitor --secs 0.3 --lab "$tmp/lab-v-$n.conf" "$@" 2>&1; }
same () { [ "$1" = "$2" ]; }   # same <got> <want>

vconf utf '- gr\303\274\303\237e \342\202\254 \346\227\245\r\n'
same "$(vmon utf)" 'MMUART0: - grüße € 日' && pass "monitor: shows UTF-8 text" || fail "monitor: shows UTF-8 text ($(vmon utf))"
expect_rc  "monitor: --expect matches UTF-8 text" 0 monitor --secs 0.3 --lab "$tmp/lab-v-utf.conf" --expect 'grüße €'
vconf bad 'a\377b\200c\r\nabc\342\202'
out="$(vmon bad --view interleaved)"
same "$out" "$(printf 'MMUART0: a\\xffb\\x80c\nMMUART0: abc\\xe2\\x82')" && pass "monitor: invalid UTF-8 bytes show as \\xNN, also a sequence cut off at the end" || fail "monitor: invalid UTF-8 bytes show as \\xNN ($out)"
case "$out" in *$'\357\277\275'*) fail "monitor: no U+FFFD for invalid bytes" ;; *) pass "monitor: no U+FFFD for invalid bytes" ;; esac
vconf tab 'a\tb\r\n'
same "$(vmon tab)" "$(printf 'MMUART0: a\tb')" && pass "monitor: a tab stays" || fail "monitor: a tab stays"
# a multibyte character that arrives in two pieces, an escape sequence that arrives in two pieces
tcp_serve split 'send=b"caf\xc3"' 'sleep=0.2' 'send=b"\xa9 ok \xe6\x97"' 'sleep=0.2' 'send=b"\xa5 \x1b[3"' 'sleep=0.2' 'send=b"1mred\x1b[0m\r\n"' 'hold'
tconf "$tmp/lab-split.conf" 'UART_COUNT=1' "UART0=tcp:127.0.0.1:$(cat "$tmp/split.tport")"
out="$(monitor --secs 0.9 --lab "$tmp/lab-split.conf" --color never 2>&1)"
same "$out" "MMUART0: café ok 日 red" && pass "monitor: a character and an escape sequence that arrive in two pieces are whole" || fail "monitor: a character and an escape sequence that arrive in two pieces are whole ($out)"
out="$(monitor --secs 0.9 --lab "$tmp/lab-split.conf" --color always 2>&1)"
same "$out" "$ESC[36mMMUART0:$ESC[0m café ok 日 $ESC[31mred$ESC[0m" && pass "monitor: the colour of a split sequence passes through, reset at the end" || fail "monitor: the colour of a split sequence passes through ($(printf '%s' "$out" | cat -v))"
# colours: through when on, removed when off, reset at the line end
vconf sgr '\033[31mred\033[0m plain\r\n\033[1;32mbold green\r\nnext\r\n'
same "$(vmon sgr --color never)" "$(printf 'MMUART0: red plain\nMMUART0: bold green\nMMUART0: next')" && pass "monitor: --color never removes the colours of the target" || fail "monitor: --color never removes the colours of the target ($(vmon sgr --color never | cat -v))"
want="$ESC[36mMMUART0:$ESC[0m $ESC[31mred$ESC[0m plain"$'\n'"$ESC[36mMMUART0:$ESC[0m $ESC[1;32mbold green$ESC[0m"$'\n'"$ESC[36mMMUART0:$ESC[0m next"
same "$(vmon sgr --color always)" "$want" && pass "monitor: --color always passes the colours through and resets them at the end of the line" || fail "monitor: --color always passes the colours through and resets them at the end of the line ($(vmon sgr --color always | cat -v))"
case "$(vmon sgr)" in *"$ESC"*) fail "monitor: no colour on a pipe by default" ;; *) pass "monitor: no colour on a pipe by default" ;; esac
case "$(FORCE_COLOR=1 vmon sgr)" in *"$ESC[31mred"*) pass "monitor: FORCE_COLOR turns the colours on" ;; *) fail "monitor: FORCE_COLOR turns the colours on" ;; esac
case "$(NO_COLOR=1 FORCE_COLOR=1 vmon sgr)" in *"$ESC"*) fail "monitor: NO_COLOR wins over FORCE_COLOR" ;; *) pass "monitor: NO_COLOR wins over FORCE_COLOR" ;; esac
case "$(NO_COLOR=1 vmon sgr --color always)" in *"$ESC[31mred"*) pass "monitor: --color always wins over NO_COLOR" ;; *) fail "monitor: --color always wins over NO_COLOR" ;; esac
# every other escape sequence and control character is removed or shown, nothing reaches the terminal
vconf esc 'a\033[2Jb\033[1;1Hc\033]0;title\007d\033]8;;http://x\033\\e\033(Bf\033[?25lg\007h\033[31;1H\033[3\033[Kx\033Pdcs\033\\y\002\r\n\033[3'
for c in always never; do
  out="$(vmon esc --color $c)"
  case $c in never) want='MMUART0: abcdefg\x07hxy\x02' ;; *) want="$ESC[36mMMUART0:$ESC[0m abcdefg\\x07hxy\\x02" ;; esac
  same "$out" "$want" && pass "monitor: --color $c removes cursor, screen, OSC, DCS and charset sequences and shows other control characters" || fail "monitor: --color $c removes cursor, screen, OSC, DCS and charset sequences ($(printf '%s' "$out" | cat -v))"
  case "$(printf '%s' "$out" | sed "s/$ESC\[[0-9;]*m//g")" in *"$ESC"*) fail "monitor: --color $c leaves no escape sequence of the target" ;; *) pass "monitor: --color $c leaves no escape sequence of the target" ;; esac
done
# interleaved: the order the lines arrive in, the prefix, a partial line held back until its end
tcp_serve ilv0 'send=b"A1\r\n"' 'send=b"half"' 'sleep=0.4' 'send=b"-done\r\n"' 'sleep=0.4' 'send=b"A3\r\n"' 'hold'
tcp_serve ilv1 'sleep=0.2' 'send=b"B1\r\n"' 'sleep=1.0' 'send=b"B2\r\n"' 'send=b"tail"' 'hold'
tconf "$tmp/lab-ilv.conf" 'UART_COUNT=2' "UART0=tcp:127.0.0.1:$(cat "$tmp/ilv0.tport")" "UART1=tcp:127.0.0.1:$(cat "$tmp/ilv1.tport")"
out="$(monitor --secs 1.8 --lab "$tmp/lab-ilv.conf" --view interleaved 2>&1)"
same "$out" $'MMUART0: A1\nMMUART1: B1\nMMUART0: half-done\nMMUART0: A3\nMMUART1: B2\nMMUART1: tail' \
  && pass "monitor: interleaved shows complete lines in the order they arrive, a partial line after its end, the last one at the end of the run" \
  || fail "monitor: interleaved shows complete lines in the order they arrive ($out)"
out="$(monitor --secs 1.8 --lab "$tmp/lab-ilv.conf" --view interleaved --color always 2>&1)"
case "$out" in "$ESC[36mMMUART0:$ESC[0m A1"$'\n'"$ESC[33mMMUART1:$ESC[0m B1"*) pass "monitor: every port has its own colour in the prefix" ;; *) fail "monitor: every port has its own colour in the prefix ($(printf '%s' "$out" | cat -v))" ;; esac
# blocks: the block per port, unchanged
out="$(monitor --secs 0.3 --lab "$tmp/lab-mon.conf" --view blocks 2>&1)"
same "$out" $'MMUART1 (20 bytes):\n  | hello from MMUART1' && pass "monitor: the blocks view shows the block of the port that printed" || fail "monitor: the blocks view shows the block of the port that printed ($out)"
out="$(monitor --secs 1.8 --lab "$tmp/lab-ilv.conf" --view blocks 2>&1)"
same "$out" $'MMUART0 (19 bytes):\n  | A1\n  | half-done\n  | A3\nMMUART1 (12 bytes):\n  | B1\n  | B2\n  | tail   [no line end]' && pass "monitor: blocks keep the ports apart, in order, and mark an unfinished line" || fail "monitor: blocks keep the ports apart ($out)"
vconf blk '\033[31mred\033[0m\r\nx\002\342\202\254\r\n'
same "$(vmon blk --view blocks --color never)" $'MMUART0 (21 bytes):\n  | red\n  | x\\x02€' && pass "monitor: blocks remove the colours with --color never and show control characters" || fail "monitor: blocks remove the colours with --color never ($(vmon blk --view blocks --color never))"
same "$(vmon blk --view blocks --color always)" "MMUART0 (21 bytes):"$'\n'"  | $ESC[31mred$ESC[0m"$'\n'"  | x\\x02€" && pass "monitor: blocks pass the colours through with --color always" || fail "monitor: blocks pass the colours through with --color always"
# options
for v in live interleaved blocks auto; do
  expect_rc "monitor: --view $v is accepted" 0 monitor --secs 0.2 --lab "$tmp/lab-mon.conf" --view "$v"
done
for c in auto always never; do
  expect_rc "monitor: --color $c is accepted" 0 monitor --secs 0.2 --lab "$tmp/lab-mon.conf" --color "$c"
done
expect_rc  "monitor: a bad --view exits 2" 2 monitor --secs 0.2 --lab "$tmp/lab-mon.conf" --view bogus
expect_rc  "monitor: a bad --color exits 2" 2 monitor --secs 0.2 --lab "$tmp/lab-mon.conf" --color bogus
expect_rc  "run_image: a bad --view exits 2" 2 run_image "$tmp/loop.elf" 0 --lab "$L" --view bogus
expect_rc  "run_image: a bad --color exits 2" 2 run_image "$tmp/loop.elf" 0 --lab "$L" --color bogus
expect_out "monitor: a bad --view names the choices" "interleaved" monitor --lab "$tmp/lab-mon.conf" --view bogus
# --expect does not depend on the view or the colours (it matches the text as the target printed it)
vconf exp '\033[31mERR\033[0m: boom \303\251\r\n'
for v in interleaved blocks live; do
  for c in always never; do
    expect_rc "monitor: --expect matches the same text with --view $v --color $c" 0 monitor --secs 0.3 --lab "$tmp/lab-v-exp.conf" --view $v --color $c --expect "ERR.\[0m: boom é"
    expect_rc "monitor: --expect does not match what the view would show, with --view $v --color $c" 1 monitor --secs 0.3 --lab "$tmp/lab-v-exp.conf" --view $v --color $c --expect "ERR: boom"
  done
done
# the output encoding: no UTF-8, no UTF-8 decorations, and what it cannot show is escaped, not an exception
vconf enc 'caf\303\251 \346\227\245\r\n'
same "$(PYTHONIOENCODING=ascii vmon enc)" 'MMUART0: caf\xe9 \u65e5' && pass "monitor: text that the output encoding lacks is escaped, not an error" || fail "monitor: text that the output encoding lacks is escaped ($(PYTHONIOENCODING=ascii vmon enc))"
same "$(PYTHONIOENCODING=ascii vmon enc --view blocks)" $'MMUART0 (11 bytes):\n  | caf\\xe9 \\u65e5' && pass "monitor: the blocks view escapes it too" || fail "monitor: the blocks view escapes it too"
# run_image: the serial text comes first, in whatever view; then the trap and the verdict
out="$(run_image "$tmp/loop.elf" 0 --secs 0.4 --lab "$L" --view interleaved --expect 'bare hello' 2>&1)"
case "$out" in *"MMUART0: bare hello E51 hart 0"*"after: pc="*"expect: matched"*) pass "run_image: interleaved shows the serial lines, then the trap and the verdict" ;; *) fail "run_image: interleaved shows the serial lines, then the trap and the verdict ($out)" ;; esac
out="$(run_image "$tmp/loop.elf" 0 --secs 0.4 --lab "$L" --view blocks 2>&1)"
case "$out" in *"MMUART0 ("*" bytes):"*"  | bare hello E51 hart 0"*"after: pc="*) pass "run_image: the blocks view shows the block, then the trap" ;; *) fail "run_image: the blocks view shows the block, then the trap ($out)" ;; esac
for v in interleaved blocks; do
  expect_rc "run_image: --expect matches with --view $v" 0 run_image "$tmp/loop.elf" 0 --secs 0.4 --lab "$L" --view $v --expect 'bare hello E51 hart 0'
  expect_rc "run_image: --expect that does not match exits 1 with --view $v" 1 run_image "$tmp/loop.elf" 0 --secs 0.4 --lab "$L" --view $v --expect 'something else'
done
# widths and the text of a port, as functions
"$PY" - "$HW" <<'PYEOF' && pass "serialview: widths (wide 2, combining 0), tabs, cutting with colours, line ends across reads, long lines" || fail "serialview: widths (wide 2, combining 0), tabs, cutting with colours, line ends across reads, long lines"
import sys
sys.path.insert(0, sys.argv[1])
import serialview as v
assert v.char_width("a") == 1 and v.char_width("日") == 2 and v.char_width("Ａ") == 2 and v.char_width("́") == 0 and v.char_width("‍") == 0
assert v.visible_width("a\x1b[31m日\x1b[0ḿb") == 4
assert v.expand_tabs("a\tb") == "a       b" and v.expand_tabs("\x1b[1mab\x1b[0m\tc") == "\x1b[1mab\x1b[0m      c"
assert v.fit("abcdef", 6, ">") == "abcdef" and v.fit("abcdefg", 6, ">") == "abcde>"
assert v.fit("日本語", 5, ">") == "日本>" and v.fit("日本語", 6, ">") == "日本語"
assert v.fit("\x1b[31mabcdefg\x1b[0m", 4, ">") == "\x1b[31mabc>\x1b[0m"
p = v.PortText(True)
assert p.feed(b"ab\r") == ["ab"] and p.feed(b"\ncd\n\r\n") == ["cd", ""], "CR LF over two reads is one line end"
p = v.PortText(False)
assert p.feed(b"x\x1b[31my\x1b[0m\n") == ["xy"] and p.feed(b"\xe6\x97") == [] and p.feed(b"\xa5\n") == ["日"]
assert p.feed(b"\xe6\x97", final=True) == [] and p.take_partial() == "\\xe6\\x97"
p = v.PortText(False)
assert len(p.feed(b"x" * 10000)) == 2 and len(p.partial()) == 10000 - 2 * v.MAX_LINE
p = v.PortText(False)
p.feed(b"\xe2\x80\xae\xe2\x80\xa8\xc2\x9b\x7f")
assert p.take_partial() == "\\u202e\\u2028\\x9b\\x7f" and v.show_char(chr(0x202e)) == "\\u202e"
assert v.raw_text(b"a\r\nb\xff\x1b[0m") == "a\nb\\xff\x1b[0m"
PYEOF

# --- the live view, on a pseudo-terminal -------------------------------------------------------
# ptyrun.py runs a command on a pty of a given size and prints the screen that its output leaves (a small terminal
# emulator that lists every escape sequence it does not know). pty <ptyrun options> -- <command>; field <output> <name>;
# rows <output>: the rows of the screen; hdr <n> <label> <bytes> [state] [width]: the header row of a window; gut <n>: n empty rows.
PTY="$ROOT/tests/host/hw/ptyrun.py"
pty () { "$PY" "$PTY" "$@"; }
field () { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }
rows () { printf '%s\n' "$1" | sed '1,/^screen:$/d'; }
hdr () { local t="MMUART$1  $2  $3 B${4:-} "; local n=$(( ${5:-59} - 3 - ${#t} )); printf '── %s' "$t"; [ "$n" -le 0 ] || printf '─%.0s' $(seq 1 "$n"); printf '\n'; }
gut () { local i; for i in $(seq 1 "$1"); do printf '│\n'; done; }
lmon () { local o=(); while [ "$1" != -- ]; do o+=("$1"); shift; done; shift; pty "${o[@]}" -- "$PY" "$HW/monitor.py" "$@"; }
sane () { [ "$(field "$1" rc)" = "${2:-0}" ] && [ "$(field "$1" cursor_visible)" = 1 ] && [ "$(field "$1" unknown)" = none ]; }   # sane <output> [rc]

tcp_serve lva 'send=b"alpha\r\n"' 'send=b"beta\r\n"' 'send=b"gamma\r\n"' 'hold'
tcp_serve lvb 'hold'
PA="$(cat "$tmp/lva.tport")"; PB="$(cat "$tmp/lvb.tport")"
tconf "$tmp/lab-live.conf" 'UART_COUNT=2' "UART0=tcp:127.0.0.1:$PA" "UART1=tcp:127.0.0.1:$PB"
out="$(lmon --rows 30 --cols 60 --raw "$tmp/live.raw" -- --secs 1.0 --lab "$tmp/lab-live.conf")"
want="$(hdr 0 "tcp://127.0.0.1:$PA" 20; printf '│ alpha\n│ beta\n│ gamma\n'; gut 5; hdr 1 "tcp://127.0.0.1:$PB" 0; gut 8)"
same "$(rows "$out")" "$want" && pass "live: a window of 8 lines per port, a header with the endpoint and the byte count (the default on a terminal)" || fail "live: a window of 8 lines per port ($out)"
sane "$out" && [ "$(field "$out" cursor)" = 18,0 ] && pass "live: the cursor is visible again and below the last window, the terminal reported no sequence it does not know" || fail "live: the cursor ends below the last window ($out)"
"$PY" - "$tmp/live.raw" "$PA" "$PB" <<'PYEOF' && pass "live: the cursor is hidden while it runs and shown once at the end; only the rows that changed are written" || fail "live: the cursor is hidden while it runs and shown once at the end; only the rows that changed are written"
import sys
raw = open(sys.argv[1], "rb").read().decode()
hide, show = raw.find("\x1b[?25l"), raw.rfind("\x1b[?25h")
assert raw.count("\x1b[?25l") == 1 and raw.count("\x1b[?25h") == 1 and 0 <= hide < show, "cursor"
assert raw.count("alpha") == 1 and raw.count("beta") == 1, "a row that did not change was written again"
assert raw.count("MMUART1") == 1, "the window of the silent port was redrawn"
assert raw.count("MMUART0") >= 2, "the byte count of the first window did not change"
PYEOF
# the text scrolls in a window of 8 lines
s=""; for i in 01 02 03 04 05 06 07 08 09 10 11 12; do s="$s""L$i\\r\\n"; done
tcp_serve lvs "send=b\"$s\"" 'hold'
tconf "$tmp/lab-live1.conf" 'UART_COUNT=1' "UART0=tcp:127.0.0.1:$(cat "$tmp/lvs.tport")"
out="$(lmon --rows 24 --cols 50 -- --secs 0.8 --lab "$tmp/lab-live1.conf")"
want="$(hdr 0 "tcp://127.0.0.1:$(cat "$tmp/lvs.tport")" 60 '' 49; printf '│ L%s\n' 05 06 07 08 09 10 11 12)"
same "$(rows "$out")" "$want" && sane "$out" && [ "$(field "$out" cursor)" = 9,0 ] && pass "live: after more than 8 lines the window shows the last 8" || fail "live: after more than 8 lines the window shows the last 8 ($out)"
# the text is shown while the run goes on, not after it
out="$(lmon --rows 30 --cols 60 --first-seen alpha -- --secs 2.0 --lab "$tmp/lab-live.conf")"
ms="$(field "$out" first_seen_ms)"
[ "$ms" -ge 0 ] && [ "$ms" -lt 1200 ] && pass "live: the text shows while the run goes on (after $ms ms of a 2000 ms run)" || fail "live: the text shows while the run goes on ($ms ms of a 2000 ms run)"
monitor --secs 2.5 --lab "$tmp/lab-ilv.conf" --view interleaved > "$tmp/stream.out" 2>&1 &
spid=$!
sleep 1.0
{ kill -0 "$spid" 2>/dev/null && grep -qx 'MMUART0: A1' "$tmp/stream.out" && ! grep -q 'MMUART1: B2' "$tmp/stream.out"; } \
  && pass "interleaved: the lines show while the run goes on, in a file too, not after it" || fail "interleaved: the lines show while the run goes on ($(cat "$tmp/stream.out"))"
wait "$spid"
# a partial line is shown as it is typed
tcp_serve lvp 'send=b"login: "' 'hold'
tconf "$tmp/lab-livep.conf" 'UART_COUNT=1' "UART0=tcp:127.0.0.1:$(cat "$tmp/lvp.tport")"
out="$(lmon --rows 24 --cols 50 -- --secs 0.6 --lab "$tmp/lab-livep.conf")"
same "$(rows "$out" | sed -n 2p)" '│ login:' && pass "live: a line without a line end is shown at once" || fail "live: a line without a line end is shown at once ($out)"
# a narrow terminal: long lines and wide characters are cut to the width, with a marker, and nothing wraps
tcp_serve lvw 'send=b"0123456789abcdefghijklmnop\r\n"' 'send=b"\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e\r\n"' 'hold'
tconf "$tmp/lab-livew.conf" 'UART_COUNT=1' "UART0=tcp:127.0.0.1:$(cat "$tmp/lvw.tport")"
out="$(lmon --rows 24 --cols 20 -- --secs 0.6 --lab "$tmp/lab-livew.conf")"
r="$(rows "$out")"
same "$(printf '%s\n' "$r" | sed -n 2,3p)" $'│ 0123456789abcdef…\n│ 日本語日本語日本…' && [ "$(field "$out" cursor)" = 9,0 ] && sane "$out" && pass "live: on a narrow terminal long lines and wide characters are cut to the width, nothing wraps" || fail "live: on a narrow terminal long lines and wide characters are cut to the width ($out)"
printf '%s\n' "$r" | "$PY" -c '
import sys, unicodedata
for line in sys.stdin.read().splitlines():
    w = sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in line)
    assert w <= 19, (w, line)
' && pass "live: no row is wider than the terminal minus one column" || fail "live: no row is wider than the terminal minus one column ($r)"
case "$(printf '%s\n' "$r" | sed -n 1p)" in "── MMUART0"*"…") pass "live: a header that is too long is cut with a marker" ;; *) fail "live: a header that is too long is cut with a marker ($r)" ;; esac
# a short terminal: fewer lines per window; one that cannot hold a line per window: the interleaved view
tcp_serve lv6 'send=b"L01\r\nL02\r\nL03\r\nL04\r\nL05\r\nL06\r\n"' 'hold'
tconf "$tmp/lab-live6.conf" 'UART_COUNT=2' "UART0=tcp:127.0.0.1:$(cat "$tmp/lv6.tport")" "UART1=tcp:127.0.0.1:$PB"
out="$(lmon --rows 12 --cols 50 -- --secs 0.6 --lab "$tmp/lab-live6.conf")"
want="$(hdr 0 "tcp://127.0.0.1:$(cat "$tmp/lv6.tport")" 30 '' 49; printf '│ L%s\n' 03 04 05 06; hdr 1 "tcp://127.0.0.1:$PB" 0 '' 49; gut 4)"
same "$(rows "$out")" "$want" && sane "$out" && [ "$(field "$out" cursor)" = 10,0 ] && pass "live: a terminal of 12 rows gets windows of 4 lines for 2 ports, the frame and the cursor line fit" || fail "live: a terminal of 12 rows gets windows of 4 lines ($out)"
out="$(lmon --rows 4 --cols 40 --raw "$tmp/live-small.raw" -- --secs 0.6 --lab "$tmp/lab-live6.conf" --color never)"
out="$out $(tr -d '\r' < "$tmp/live-small.raw")"
case "$out" in *"a terminal of 4 rows is too small for 2 windows"*"MMUART0: L01"*"MMUART0: L06"*) sane "$out" && pass "live: a terminal with too few rows for the windows falls back to the interleaved view and says so" ;; *) fail "live: a terminal with too few rows falls back to the interleaved view ($out)" ;; esac
out="$(lmon --rows 24 --cols 40 --env TERM=dumb -- --secs 0.6 --lab "$tmp/lab-live6.conf")"
case "$out" in *"MMUART0: L01"*) sane "$out" && pass "live: TERM=dumb picks the interleaved view" ;; *) fail "live: TERM=dumb picks the interleaved view ($out)" ;; esac
out="$(lmon --rows 24 --cols 40 -- --secs 0.6 --lab "$tmp/lab-live6.conf" --view interleaved)"
case "$out" in *"MMUART0: L01"*) sane "$out" && pass "live: --view interleaved on a terminal is interleaved" ;; *) fail "live: --view interleaved on a terminal is interleaved ($out)" ;; esac
# colours of the target: through, reset at the line end, not into the next line or window; the other sequences do not reach the terminal
tcp_serve lvc 'send=b"\x1b[31mred\x1b[0m ok\r\n\x1b[1;32mgreen\r\nnext\r\n\x1b[2J\x1b[1;1Hboom\x1b[?25l\x1b]0;t\x07\x1b[5;5Hx\r\n"' 'hold'
tconf "$tmp/lab-livec.conf" 'UART_COUNT=2' "UART0=tcp:127.0.0.1:$(cat "$tmp/lvc.tport")" "UART1=tcp:127.0.0.1:$PB"
out="$(lmon --rows 30 --cols 60 --attrs -- --secs 0.6 --lab "$tmp/lab-livec.conf" --color always)"
r="$(rows "$out")"
want="$(printf '%s\n' '<36>│</> <31>red</> ok' '<36>│</> <1;32>green</>' '<36>│</> next' '<36>│</> boomx')"
same "$(printf '%s\n' "$r" | sed -n 2,5p)" "$want" && sane "$out" && pass "live: the colours of the target pass through, end with the line and do not leak; a clear-screen, a cursor position and a cursor-hide of the target do nothing" || fail "live: the colours of the target pass through ($out)"
case "$(printf '%s\n' "$r" | sed -n 1p)" in "<1;36>── MMUART0"*) pass "live: the header has the colour of the port" ;; *) fail "live: the header has the colour of the port ($r)" ;; esac
case "$(printf '%s\n' "$r" | sed -n 10p)" in "<2>── MMUART1"*) pass "live: the window of a port that printed nothing is dim" ;; *) fail "live: the window of a port that printed nothing is dim ($r)" ;; esac
[ "$(printf '%s\n' "$r" | sed -n 11,18p | grep -c '^<2>│</>$')" = 8 ] && pass "live: and so is its empty gutter" || fail "live: and so is its empty gutter ($r)"
out="$(lmon --rows 30 --cols 60 --attrs -- --secs 0.6 --lab "$tmp/lab-livec.conf" --color never)"
r="$(rows "$out")"
same "$(printf '%s\n' "$r" | sed -n 2,5p)" $'│ red ok\n│ green\n│ next\n│ boomx' && sane "$out" && ! printf '%s' "$r" | grep -q '<' && pass "live: --color never has no colour at all, also not in the header and the gutters" || fail "live: --color never has no colour at all ($out)"
out="$(lmon --rows 30 --cols 60 --raw "$tmp/live-nc.raw" --env NO_COLOR=1 -- --secs 0.6 --lab "$tmp/lab-livec.conf")"
"$PY" -c 'import re, sys; raw = open(sys.argv[1], "rb").read().decode(); assert not re.search("\x1b\\[[0-9;:]*m", raw) and "\x1b[?25l" in raw' "$tmp/live-nc.raw" && sane "$out" && pass "live: NO_COLOR gives the live view without colours" || fail "live: NO_COLOR gives the live view without colours"
# a port that ends: the window says so, the line about it comes once below the frame
tcp_serve lvd 'send=b"bye\r\n"' 'sleep=0.3'
tconf "$tmp/lab-lived.conf" 'UART_COUNT=1' "UART0=tcp:127.0.0.1:$(cat "$tmp/lvd.tport")"
out="$(lmon --rows 24 --cols 80 -- --secs 1.0 --lab "$tmp/lab-lived.conf")"
want="$(hdr 0 "tcp://127.0.0.1:$(cat "$tmp/lvd.tport")" 5 '  [ended]' 79; printf '│ bye\n'; gut 7; printf 'monitor.py: MMUART0: tcp://127.0.0.1:%s closed the connection after 5 bytes\n' "$(cat "$tmp/lvd.tport")")"
same "$(rows "$out")" "$want" && sane "$out" && pass "live: a connection that ends is marked in its header and reported once below the frame" || fail "live: a connection that ends is marked in its header ($out)"
# Ctrl+C: the terminal is restored, the frame stays, exit status 130 at once
t0=$(date +%s%N)
out="$(lmon --rows 30 --cols 60 --int-after 1.0 -- --secs 30 --lab "$tmp/lab-live.conf")"
ms=$(( ($(date +%s%N) - t0) / 1000000 ))
r="$(rows "$out")"
sane "$out" 130 && [ "$ms" -lt 5000 ] && [ "$(printf '%s\n' "$r" | sed -n 2p)" = '│ alpha' ] && [ "$(printf '%s\n' "$r" | sed -n 19p)" = '^Cmonitor.py: interrupted (Ctrl+C)' ] && [ "$(field "$out" cursor)" = 19,0 ] \
  && pass "live: Ctrl+C restores the cursor, leaves the frame and ends with 130 and one line below it" \
  || fail "live: Ctrl+C restores the cursor, leaves the frame and ends with 130 ($ms ms: $out)"
case "$out" in *Traceback*) fail "live: Ctrl+C is not a traceback" ;; *) pass "live: Ctrl+C is not a traceback" ;; esac
# an exception while the view runs
out="$(pty --rows 20 --cols 40 -- "$PY" -c '
import sys
sys.path.insert(0, sys.argv[1])
import serialview
v = serialview.make_view("live", "never", {0: "port"})
with v:
    v.feed(0, b"hi\r\n")
    raise RuntimeError("boom")' "$HW")"
case "$out" in *"RuntimeError: boom"*) sane "$out" 1 && same "$(rows "$out" | sed -n 2p)" '│ hi' && pass "live: an exception restores the cursor and the frame stays" || fail "live: an exception restores the cursor ($out)" ;; *) fail "live: an exception restores the cursor ($out)" ;; esac
# the terminal is resized: the frame is drawn again for the new size, nothing of the old one stays
tcp_serve lvr 'send=b"first\r\n"' 'sleep=1.0' 'send=b"second\r\n"' 'hold'
tconf "$tmp/lab-liver.conf" 'UART_COUNT=1' "UART0=tcp:127.0.0.1:$(cat "$tmp/lvr.tport")"
out="$(lmon --rows 20 --cols 70 --resize 0.6:20x30 -- --secs 1.6 --lab "$tmp/lab-liver.conf")"
r="$(rows "$out")"
same "$(printf '%s\n' "$r" | sed -n 2,3p)" $'│ first\n│ second' && [ "$(printf '%s\n' "$r" | wc -l)" = 9 ] && [ "$(field "$out" cursor)" = 9,0 ] && sane "$out" \
  && pass "live: after a resize the frame is drawn again at the new width, nothing of the old one stays" || fail "live: after a resize the frame is drawn again ($out)"
# no UTF-8 output: the frame is ASCII, what the terminal cannot show is escaped (and so counted at its escaped width)
tcp_serve lva2 'send=b"caf\xc3\xa9 \xe6\x97\xa5\r\n01234567890123456789012345678901234567890123456789\r\n"' 'hold'
tconf "$tmp/lab-liveac.conf" 'UART_COUNT=1' "UART0=tcp:127.0.0.1:$(cat "$tmp/lva2.tport")"
out="$(lmon --rows 24 --cols 45 --env PYTHONIOENCODING=ascii -- --secs 0.6 --lab "$tmp/lab-liveac.conf")"
r="$(rows "$out")"
same "$(printf '%s\n' "$r" | sed -n 2,3p)" "$(printf '| caf\\xe9 \\u65e5\n| %s0>' "$(printf '0123456789%.0s' 1 2 3 4)")" && sane "$out" && ! printf '%s' "$r" | LC_ALL=C grep -q '[^ -~]' && pass "live: without UTF-8 output the frame is ASCII, escaped characters are counted at their escaped width" || fail "live: without UTF-8 output the frame is ASCII ($out)"
case "$(printf '%s\n' "$r" | sed -n 1p)" in "-- MMUART0  tcp://"*" B -"*) pass "live: the header has an ASCII fill" ;; *) fail "live: the header has an ASCII fill ($r)" ;; esac
# run_image: the frame stays, the trap and the verdict come below it, the text is not printed twice
serve livehello --uart "$tmp/uart/livehello/mmuart0.log" --print "bare hello E51 hart 0"
out="$(pty --rows 50 --cols 80 -- "$PY" "$HW/run_image.py" "$tmp/loop.elf" 0 --secs 0.6 --lab "$tmp/lab-livehello.conf" --expect 'bare hello')"
r="$(rows "$out")"
last="$(printf '%s\n' "$r" | grep -n '^│' | tail -1 | cut -d: -f1)"; after="$(printf '%s\n' "$r" | grep -n '^after:' | cut -d: -f1)"
sane "$out" && [ "$(printf '%s\n' "$r" | grep -c 'bare hello E51 hart 0')" = 1 ] && [ "$after" -gt "$last" ] && [ "$(printf '%s\n' "$r" | tail -1)" = 'expect: matched /bare hello/ on MMUART0' ] \
  && pass "run_image: the live frame stays on the screen, the trap and the verdict follow it, and the text is not printed twice" \
  || fail "run_image: the live frame stays, the trap and the verdict follow it ($out)"
out="$(pty --rows 50 --cols 80 -- "$PY" "$HW/run_image.py" "$tmp/loop.elf" 0 --secs 0.4 --lab "$tmp/lab-livehello.conf" --view live --color never --expect 'nothing like it')"
sane "$out" 1 && pass "run_image: --expect that does not match exits 1 after a live view" || fail "run_image: --expect that does not match exits 1 after a live view ($out)"

# --- start_openocd.sh ---------------------------------------------------------------
mkdir -p "$tmp/ocd/bin"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/openocd.args"\n' "$tmp" > "$tmp/ocd/bin/openocd"
chmod +x "$tmp/ocd/bin/openocd"
expect_rc  "start_openocd: starts the OpenOCD of lab.conf" 0 env LAB_CONF="$L" sh "$HW/start_openocd.sh" -c "extra"
grep -qx -- "$tmp/ocd/openocd/scripts" "$tmp/openocd.args" && grep -qx 'interface/embedded_flashpro6.cfg' "$tmp/openocd.args" \
  && grep -qx 'target/microchip_riscv.cfg' "$tmp/openocd.args" \
  && grep -qx 'set DEVICE MPFS' "$tmp/openocd.args" && grep -qx 'extra' "$tmp/openocd.args" \
  && pass "start_openocd: passes the script path, the interface and target files, the device and further arguments" \
  || fail "start_openocd: passes the script path, the interface and target files, the device and further arguments"
ocdline () { grep -n -x -- "$1" "$tmp/openocd.args" | head -1 | cut -d: -f1; }   # the number of the line of an argument
[ "$(ocdline interface/embedded_flashpro6.cfg)" -lt "$(ocdline extra)" ] && [ "$(ocdline extra)" -lt "$(ocdline target/microchip_riscv.cfg)" ] \
  && pass "start_openocd: the arguments of the caller come between the interface file and the target file (which runs init)" \
  || fail "start_openocd: the arguments of the caller come between the interface file and the target file (which runs init)"
printf 'OPENOCD=%s\n' "$tmp/noopenocd" > "$tmp/lab-noocd.conf"
expect_rc  "start_openocd: a missing OpenOCD exits 2" 2 env LAB_CONF="$tmp/lab-noocd.conf" sh "$HW/start_openocd.sh"
expect_out "start_openocd: names the path it tried" "$tmp/noopenocd/bin/openocd" env LAB_CONF="$tmp/lab-noocd.conf" sh "$HW/start_openocd.sh"
expect_rc  "start_openocd: OPENOCD in the environment overrides lab.conf" 0 env LAB_CONF="$tmp/lab-noocd.conf" OPENOCD="$tmp/ocd" sh "$HW/start_openocd.sh"
# an empty OPENOCD is the pinned release in its prefix (./x toolchain install openocd)
ocdver="$(sed -n 's/^OPENOCD_VERSION=//p' "$ROOT/tools/toolchain.env")"
mkdir -p "$tmp/tools/openocd-$ocdver/bin"
cp "$tmp/ocd/bin/openocd" "$tmp/tools/openocd-$ocdver/bin/openocd"
printf 'OPENOCD=\n' > "$tmp/lab-pinned.conf"
expect_rc  "start_openocd: an empty OPENOCD starts the pinned release from MPFS_TOOLS_PREFIX" 0 env LAB_CONF="$tmp/lab-pinned.conf" MPFS_TOOLS_PREFIX="$tmp/tools" sh "$HW/start_openocd.sh"
grep -qx -- "$tmp/tools/openocd-$ocdver/openocd/scripts" "$tmp/openocd.args" \
  && pass "start_openocd: the pinned release brings its own scripts" || fail "start_openocd: the pinned release brings its own scripts"
expect_rc  "start_openocd: an empty OPENOCD without the pinned release exits 2" 2 env LAB_CONF="$tmp/lab-pinned.conf" MPFS_TOOLS_PREFIX="$tmp/no-tools" sh "$HW/start_openocd.sh"
expect_out "start_openocd: and says how to install it" "./x toolchain install openocd" env LAB_CONF="$tmp/lab-pinned.conf" MPFS_TOOLS_PREFIX="$tmp/no-tools" sh "$HW/start_openocd.sh"
expect_rc  "start_openocd: a missing lab.conf exits 2" 2 env LAB_CONF="$tmp/none.conf" sh "$HW/start_openocd.sh"

# --- ./x hw -----------------------------------------------------------------------
X="$ROOT/x"
expect_rc  "x hw: an unknown verb fails" nonzero "$X" hw bogus
expect_rc  "x hw: without a verb fails" nonzero "$X" hw
expect_rc  "x hw run: an unknown example exits 2" 2 "$X" hw run no_such_example
expect_rc  "x hw run: an ELF file is run, the exit status passes through (match)" 0 "$X" hw run "$tmp/loop.elf" --secs 0.3 --lab "$L" --expect 'bare hello'
expect_rc  "x hw run: and the exit status of a missed expectation passes through" 1 "$X" hw run "$tmp/loop.elf" --secs 0.3 --lab "$L" --expect 'something else'
expect_rc  "x hw run: an invalid hart for an example exits 2" 2 "$X" hw run report_test --hart 9
expect_rc  "x hw monitor: --expect passes through" 1 "$X" hw monitor --secs 0.3 --lab "$tmp/lab-mon.conf" --expect 'goodbye'
expect_rc  "x hw probe: --expect passes through" 0 "$X" hw probe probe_time.S 1 --secs 0.2 --lab "$LP" --expect '0x1234'
expect_rc  "x hw openocd: starts OpenOCD" 0 env LAB_CONF="$L" "$X" hw openocd

# --- bootmode.py --------------------------------------------------------------------
# The programmer runs fpgenprog (a stand-in, fake_fpgenprog.py, that records its calls and makes the project folder
# as fpgenprog does) and objcopy and readelf of the pinned toolchain (real) on boot programs that are assembled here.
# What the images and the fpgenprog calls must be is tested against the Java tool in bootprog_test.py. The real
# fpgenprog and a FlashPro were not used.
mkdir -p "$tmp/bm"
export FAKE_FP_LOG="$tmp/bm/fp.log"
printf '#!/bin/sh\nexec "%s" "%s/tests/host/hw/fake_fpgenprog.py" "$@"\n' "$PY" "$ROOT" > "$tmp/bm/fpgenprog"
chmod +x "$tmp/bm/fpgenprog"
printf '\t.option norvc\n\t.globl _start\n_start:\n\tj _start\n\t.rept 75\n\t.word 0x00000013\n\t.endr\n' > "$tmp/bm/img.S"
BME="$tmp/bm/envm/app.elf"; BML="$tmp/bm/lim/app.elf"   # boot programs for the eNVM (modes 1, 3) and for the LIM (mode 2)
BMW="$tmp/bm/work"                                       # the working directory of the programmer
mkdir -p "$tmp/bm/envm" "$tmp/bm/lim"
for t in "envm 0x20220100 $BME" "lim 0x08000000 $BML"; do
  set -- $t
  "$tc/riscv64-elf-gcc" -march=rv64imac -mabi=lp64 -nostdlib -Wl,-N -Wl,-Ttext="$2" -o "$3" "$tmp/bm/img.S" 2>/dev/null \
    || { echo "FAIL: cannot build the boot program for $1" >&2; exit 1; }
done
printf 'FPGENPROG=%s/bm/fpgenprog\nOCD_PORT=1\n' "$tmp" > "$tmp/lab-bm.conf"
LB="$tmp/lab-bm.conf"
bmelf () { case "$1" in 0) ;; 2) echo "$BML" ;; *) echo "$BME" ;; esac; }
bootmode () {  # the boot mode, then its boot program and the working directory, then the rest
  case "${1:-}" in -*|"") "$PY" "$HW/bootmode.py" "$@" ;; *) local n="$1"; shift; "$PY" "$HW/bootmode.py" "$n" $(bmelf "$n") --workdir "$BMW" "$@" ;; esac
}
fpcalls () { cat "$FAKE_FP_LOG" 2>/dev/null; }
fpreset () { rm -f "$FAKE_FP_LOG"; }
fpgrep () { fpcalls | grep -q -- "$1"; }   # a call of fpgenprog with <regex>
programmed () { fpgrep '^run_action .*--action PROGRAM'; }

fpreset
expect_rc  "bootmode: --yes prepares, programs and exits 0" 0 bootmode 2 --yes --lab "$LB"
calls="$(fpcalls | cut -d' ' -f1 | tr '\n' ' ')"
[ "$calls" = "new_project mss_boot_info snvm_client generate_bitstream run_action " ] \
  && pass "bootmode: the fpgenprog calls are new_project, boot mode, client, bitstream, PROGRAM" \
  || fail "bootmode: the fpgenprog calls are new_project, boot mode, client, bitstream, PROGRAM (got: $calls)"
fpgrep "^new_project --location $BMW/bootmode2/fpgenprogProject --target_die MPFS250T_ES --target_package FCVG484\$" \
  && pass "bootmode: the project is in <workdir>/bootmode<N>, die and package are the defaults of lab.conf.example" \
  || fail "bootmode: the project is in <workdir>/bootmode<N>, die and package are the defaults of lab.conf.example (got: $(fpcalls | head -1))"
[ -f "$BMW/bootmode2/app-bm2-p0-ap.hex" ] && pass "bootmode: the image of the boot mode is made from the ELF where the ELF is" || fail "bootmode: the image of the boot mode is made from the ELF where the ELF is"
[ ! -e "$BMW/app.elf" ] && pass "bootmode: the ELF is not copied to the working directory" || fail "bootmode: the ELF is not copied to the working directory"
expect_out "bootmode: shows the output of fpgenprog" "Executing action PROGRAM" bootmode 0 --yes --lab "$LB"
expect_out "bootmode: prints the duration" "the programmer took" bootmode 0 --yes --lab "$LB"
expect_out "bootmode: says what to do next" "Power-cycle the board" bootmode 0 --yes --lab "$LB"
expect_out "bootmode: names the PC to check" "0x2000312E" bootmode 0 --yes --lab "$LB"
expect_out "bootmode: reports the FlashPro that fpgenprog used" "FlashPro used: STANDIN1" bootmode 0 --yes --lab "$LB"
# die and package from lab.conf, and from the options
printf 'BOOTMODE_DIE=MPFS250T\nBOOTMODE_PACKAGE=FCG1152\n' | cat "$LB" - > "$tmp/lab-bm2.conf"
fpreset; bootmode 3 --yes --lab "$tmp/lab-bm2.conf" >/dev/null 2>&1
fpgrep "target_die MPFS250T --target_package FCG1152\$" && pass "bootmode: die and package come from lab.conf" || fail "bootmode: die and package come from lab.conf (got: $(fpcalls | head -1))"
fpreset; bootmode 3 --yes --die mpfs095t_es --package fcsg536 --lab "$tmp/lab-bm2.conf" >/dev/null 2>&1
fpgrep "target_die MPFS095T_ES --target_package FCSG536\$" && pass "bootmode: --die and --package win over lab.conf (in any case)" || fail "bootmode: --die and --package win over lab.conf (got: $(fpcalls | head -1))"
expect_rc  "bootmode: a die that does not exist exits 2" 2 bootmode 1 --yes --die MPFS999T --lab "$LB"
expect_out "bootmode: a die that does not exist is named, with the help text" "Invalid die" bootmode 1 --yes --die MPFS999T --lab "$LB"
# --dry-run
fpreset; rm -rf "$BMW"
expect_rc  "bootmode: --dry-run exits 0" 0 bootmode 1 --dry-run --lab "$LB"
expect_out "bootmode: --dry-run says what it would do" "boot mode 1 - non-secure boot from eNVM, die MPFS250T_ES, package FCVG484" bootmode 1 --dry-run --lab "$LB"
expect_out "bootmode: --dry-run prints the programming command" "run_action --location $BMW/bootmode1/fpgenprogProject --action PROGRAM" bootmode 1 --dry-run --lab "$LB"
[ ! -e "$FAKE_FP_LOG" ] && [ ! -e "$BMW" ] && pass "bootmode: --dry-run runs nothing and writes nothing" || fail "bootmode: --dry-run runs nothing and writes nothing"
# refusal without --yes (no terminal here)
expect_rc  "bootmode: without --yes and without a terminal exits 2" 2 bootmode 1 --lab "$LB" </dev/null
expect_out "bootmode: the refusal says nothing was done" "nothing was done" bootmode 1 --lab "$LB" </dev/null
[ ! -e "$FAKE_FP_LOG" ] && [ ! -e "$BMW" ] && pass "bootmode: the refusal runs nothing and writes nothing" || fail "bootmode: the refusal runs nothing and writes nothing"
# the prompt, on a pseudo terminal: "yes" programs, anything else does not
ptyrun () {  # ptyrun <answer> <args...>: bootmode with a terminal on stdin that types <answer>
  local answer="$1"; shift
  "$PY" -I -c 'import os, pty, sys, time
answer, argv = sys.argv[1], sys.argv[2:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(argv[0], argv)
time.sleep(4)
os.write(fd, (answer + "\n").encode())
while True:
    try:
        if not os.read(fd, 4096): break
    except OSError: break
_, st = os.waitpid(pid, 0)
sys.exit(os.waitstatus_to_exitcode(st))' "$answer" "$PY" "$HW/${PTY_SCRIPT:-bootmode.py}" "$@"
}
fpreset
expect_rc  "bootmode: the answer 'no' exits 1" 1 ptyrun no 2 "$BML" --workdir "$BMW" --lab "$LB"
{ fpgrep '^generate_bitstream' && ! programmed; } && pass "bootmode: the answer 'no' leaves the image and the bitstream made, and does not program" || fail "bootmode: the answer 'no' leaves the image and the bitstream made, and does not program"
fpreset
expect_rc  "bootmode: the answer 'yes' programs and exits 0" 0 ptyrun yes 2 "$BML" --workdir "$BMW" --lab "$LB"
programmed && pass "bootmode: the answer 'yes' programmed" || fail "bootmode: the answer 'yes' programmed"
# --prepare-only: everything but the programming, no prompt, no OpenOCD check
fpreset
expect_rc  "bootmode: --prepare-only exits 0 without --yes and without a terminal" 0 bootmode 1 --prepare-only --lab "$LB" </dev/null
{ fpgrep '^generate_bitstream' && ! programmed; } && pass "bootmode: --prepare-only makes the bitstream and does not program" || fail "bootmode: --prepare-only makes the bitstream and does not program"
# OpenOCD holds the FlashPro
serve bmocd
printf 'FPGENPROG=%s/bm/fpgenprog\n' "$tmp" | cat "$tmp/lab-bmocd.conf" - > "$tmp/lab-bmocd2.conf"
fpreset
expect_rc  "bootmode: a running OpenOCD exits 2" 2 bootmode 1 --yes --lab "$tmp/lab-bmocd2.conf"
expect_out "bootmode: a running OpenOCD is named, nothing was done" "OpenOCD is running" bootmode 1 --yes --lab "$tmp/lab-bmocd2.conf"
[ ! -e "$FAKE_FP_LOG" ] && pass "bootmode: a running OpenOCD stops it before anything runs" || fail "bootmode: a running OpenOCD stops it before anything runs"
expect_rc  "bootmode: --prepare-only does not mind a running OpenOCD" 0 bootmode 1 --prepare-only --lab "$tmp/lab-bmocd2.conf"
expect_rc  "bootmode: --dry-run does not mind a running OpenOCD" 0 bootmode 1 --dry-run --lab "$tmp/lab-bmocd2.conf"
# failures
expect_rc  "bootmode: boot mode 4 exits 2" 2 bootmode 4 --yes --lab "$LB"
expect_rc  "bootmode: boot mode -1 exits 2" 2 bootmode -1 --yes --lab "$LB"
expect_rc  "bootmode: boot mode 'x' exits 2" 2 bootmode x --yes --lab "$LB"
expect_rc  "bootmode: no boot mode exits 2" 2 bootmode --yes --lab "$LB"
printf 'FPGENPROG=%s/bm/none\n' "$tmp" > "$tmp/lab-bm-nofp.conf"
expect_rc  "bootmode: a missing fpgenprog exits 2" 2 bootmode 0 --yes --lab "$tmp/lab-bm-nofp.conf"
expect_out "bootmode: a missing fpgenprog says what to do" "set FPGENPROG" bootmode 0 --yes --lab "$tmp/lab-bm-nofp.conf"
expect_rc  "bootmode: a lab.conf that does not exist exits 2" 2 bootmode 0 --yes --lab "$tmp/none.conf"
printf 'FPGENPROG=fpgenprog\n' > "$tmp/lab-bm-fpname.conf"
expect_rc  "bootmode: a bare fpgenprog name exits 2 even when it is on PATH" 2 env PATH="$tmp/bm:$PATH" "$PY" "$HW/bootmode.py" 0 --yes --lab "$tmp/lab-bm-fpname.conf"
expect_out "bootmode: a bare fpgenprog name says it needs the full path" "full path of the fpgenprog executable" env PATH="$tmp/bm:$PATH" "$PY" "$HW/bootmode.py" 0 --yes --lab "$tmp/lab-bm-fpname.conf"
printf 'FPGENPROG=%s/bm\n' "$tmp" > "$tmp/lab-bm-fpdir.conf"
expect_rc  "bootmode: a directory as FPGENPROG exits 2" 2 "$PY" "$HW/bootmode.py" 0 --yes --lab "$tmp/lab-bm-fpdir.conf"
expect_rc  "bootmode: an fpgenprog step that fails exits 1" 1 env FAKE_FP_FAIL=mss_boot_info "$PY" "$HW/bootmode.py" 1 "$BME" --workdir "$BMW" --yes --lab "$LB"
expect_out "bootmode: a failed step is named" "Unable to select the boot mode" env FAKE_FP_FAIL=mss_boot_info "$PY" "$HW/bootmode.py" 1 "$BME" --workdir "$BMW" --yes --lab "$LB"
fpreset
expect_rc  "bootmode: a failing PROGRAM exits 1" 1 env FAKE_FP_FAIL=run_action:3 "$PY" "$HW/bootmode.py" 0 --workdir "$BMW" --yes --lab "$LB"
expect_out "bootmode: a failing PROGRAM is named" "PROGRAM action failed" env FAKE_FP_FAIL=run_action:3 "$PY" "$HW/bootmode.py" 0 --workdir "$BMW" --yes --lab "$LB"
if FAKE_FP_FAIL=run_action:3 "$PY" "$HW/bootmode.py" 0 --workdir "$BMW" --yes --lab "$LB" 2>&1 | grep -q "Power-cycle the board"; then fail "bootmode: a failed PROGRAM does not say 'power-cycle'"; else pass "bootmode: a failed PROGRAM does not say 'power-cycle'"; fi
expect_rc  "bootmode: fpgenprog without any output exits 1" 1 env FAKE_FP_SILENT=1 "$PY" "$HW/bootmode.py" 0 --workdir "$BMW" --yes --lab "$LB"
expect_out "bootmode: no output is named" "printed nothing" env FAKE_FP_SILENT=1 "$PY" "$HW/bootmode.py" 0 --workdir "$BMW" --yes --lab "$LB"
expect_rc  "bootmode: a boot program of another boot mode's address exits 1 and says so" 1 "$PY" "$HW/bootmode.py" 1 "$BML" --workdir "$BMW" --yes --lab "$LB"
expect_out "bootmode: ... the boot vector of the eNVM is named" "boot vector for the eNVM" "$PY" "$HW/bootmode.py" 1 "$BML" --workdir "$BMW" --yes --lab "$LB"
# every set-up error comes with the help text and its description of the boot modes
expect_out "bootmode: a bad boot mode prints the error and the help text" "non-secure boot from eNVM" bootmode 4 --yes --lab "$LB"
expect_out "bootmode: a bad boot mode names the error" "is not a boot mode" bootmode 4 --yes --lab "$LB"
expect_out "bootmode: no arguments print the error and the help text" "user secure boot from sNVM" "$PY" "$HW/bootmode.py"
expect_out "bootmode: a missing fpgenprog prints the help text too" "factory secure boot from eNVM" bootmode 0 --yes --lab "$tmp/lab-bm-nofp.conf"
expect_out "bootmode: the refusal without --yes prints the help text too" "idle boot" bootmode 1 --lab "$LB" </dev/null
expect_rc  "bootmode: --help exits 0" 0 "$PY" "$HW/bootmode.py" --help
expect_out "bootmode: --help says PERMANENT" "PERMANENT" "$PY" "$HW/bootmode.py" --help
# the options of the boot modes 2 and 3
fpreset
bootmode 2 --yes --snvm-page 5 --usk 0xAABBCCDDEEFF001122334455 --encrypt --lab "$LB" >/dev/null 2>&1
fpgrep "snvm_client .*--start_page 5 --client_name bootmode2 --usk_key AABBCCDDEEFF001122334455 --encrypted_authenticated" \
  && pass "bootmode: --snvm-page, --usk (without its 0x) and --encrypt reach the sNVM client" || fail "bootmode: --snvm-page, --usk and --encrypt reach the sNVM client (got: $(fpcalls | grep snvm_client))"
fpgrep "mss_boot_info .*--u_mss_bootcfg 00000000AABBCCDDEEFF00112233445500000005\$" && pass "bootmode: the boot configuration holds the USK and the page" || fail "bootmode: the boot configuration holds the USK and the page (got: $(fpcalls | grep mss_boot_info))"
fpreset; bootmode 2 --yes --snvm_page 6 --usk 0 --lab "$LB" >/dev/null 2>&1
fpgrep "snvm_client .*--start_page 6 " && pass "bootmode: --snvm_page is an alias of --snvm-page" || fail "bootmode: --snvm_page is an alias of --snvm-page"
expect_out "bootmode: a generated USK is announced" "randomly generated USK" bootmode 2 --yes --usk 0 --lab "$LB"
[ -f "$BMW/bootmode2/app-bm2-usk.txt" ] && pass "bootmode: the generated USK is saved next to the image" || fail "bootmode: the generated USK is saved next to the image"
expect_rc  "bootmode: --usk outside boot mode 2 exits 2" 2 bootmode 1 --yes --usk 0 --lab "$LB"
expect_out "bootmode: --usk outside boot mode 2 says so" "only valid for boot mode 2" bootmode 1 --yes --usk 0 --lab "$LB"
expect_rc  "bootmode: an sNVM page out of range exits 2" 2 bootmode 2 --yes --snvm-page 221 --lab "$LB"
"$PY" -I -c '
import sys
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
k = ec.generate_private_key(ec.SECP384R1())
open(sys.argv[1] + "/key.pem", "wb").write(k.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
open(sys.argv[1] + "/pub.pem", "wb").write(k.public_key().public_bytes(serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo))' "$tmp/bm" \
  || { echo "FAIL: cannot make a test key pair (python package cryptography: ./x toolchain install)" >&2; exit 1; }
fpreset
expect_rc  "bootmode: boot mode 3 with --keys programs and exits 0" 0 bootmode 3 --yes --keys "$tmp/bm/key.pem" "$tmp/bm/pub.pem" --lab "$LB"
fpgrep "mss_boot_info .*--ucskx " && programmed && pass "bootmode: the public key reaches the boot mode" || fail "bootmode: the public key reaches the boot mode"
fpgrep -e "--action VERIFY" && fail "bootmode: --keys does not turn on --verify (the Java tool does, by a missing break)" || pass "bootmode: --keys does not turn on --verify (the Java tool does, by a missing break)"
expect_out "bootmode: without --keys the private key is reported as not saved" "private key is not saved" bootmode 3 --yes --lab "$LB"
expect_rc  "bootmode: --keys outside boot mode 3 exits 2" 2 bootmode 1 --yes --keys "$tmp/bm/key.pem" "$tmp/bm/pub.pem" --lab "$LB"
expect_rc  "bootmode: --keys with a missing file exits 2" 2 bootmode 3 --yes --keys "$tmp/bm/none.pem" "$tmp/bm/pub.pem" --lab "$LB"
fpreset; bootmode 1 --yes --verify --lab "$LB" >/dev/null 2>&1
[ "$(fpcalls | grep '^run_action' | sed 's/.*--action //' | tr '\n' ' ')" = "PROGRAM VERIFY " ] && pass "bootmode: --verify verifies after programming" || fail "bootmode: --verify verifies after programming"
# the FlashPro
fpreset
expect_rc  "bootmode: a FlashPro that fpgenprog does not honour exits 1" 1 bootmode 1 --yes --flashpro SN4242 --lab "$LB"
expect_out "bootmode: ... and says which FlashPro it used instead" "instead of only on SN4242" bootmode 1 --yes --flashpro SN4242 --lab "$LB"
fpreset; bootmode 1 --yes --flashpro SN4242 --lab "$LB" >/dev/null 2>&1
programmed && fail "bootmode: a FlashPro that was not honoured is not programmed through" || pass "bootmode: a FlashPro that was not honoured is not programmed through"
fpreset
expect_rc  "bootmode: a FlashPro that fpgenprog honours programs and exits 0" 0 env FAKE_FP_HONOUR=1 "$PY" "$HW/bootmode.py" 1 "$BME" --workdir "$BMW" --yes --flashpro SN4242 --lab "$LB"
expect_out "bootmode: ... and reports it" "FlashPro used: SN4242" env FAKE_FP_HONOUR=1 "$PY" "$HW/bootmode.py" 1 "$BME" --workdir "$BMW" --yes --flashpro SN4242 --lab "$LB"
printf 'FLASHPRO_SERIAL=LABSN7\n' | cat "$LB" - > "$tmp/lab-bm-fp.conf"
expect_out "bootmode: FLASHPRO_SERIAL of lab.conf names the FlashPro" "FlashPro used: LABSN7" env FAKE_FP_HONOUR=1 "$PY" "$HW/bootmode.py" 1 "$BME" --workdir "$BMW" --yes --lab "$tmp/lab-bm-fp.conf"
expect_out "bootmode: --flashpro wins over FLASHPRO_SERIAL" "FlashPro used: SN9" env FAKE_FP_HONOUR=1 "$PY" "$HW/bootmode.py" 1 "$BME" --workdir "$BMW" --yes --flashpro SN9 --lab "$tmp/lab-bm-fp.conf"
expect_rc  "bootmode: a FlashPro serial with a space exits 2" 2 bootmode 1 --yes --flashpro "a b" --lab "$LB"
# FLASHPRO_ID: the name the programming tools give the FlashPro, which is what a FlashPro without a USB serial number has
printf 'FLASHPRO_ID=LABID9\nFLASHPRO_SERIAL=LABSN7\n' | cat "$LB" - > "$tmp/lab-bm-id.conf"
expect_out "bootmode: FLASHPRO_ID of lab.conf names the FlashPro" "FlashPro used: LABID9" env FAKE_FP_HONOUR=1 "$PY" "$HW/bootmode.py" 1 "$BME" --workdir "$BMW" --yes --lab "$tmp/lab-bm-id.conf"
case "$(env FAKE_FP_HONOUR=1 "$PY" "$HW/bootmode.py" 1 "$BME" --workdir "$BMW" --yes --lab "$tmp/lab-bm-id.conf" 2>&1)" in *LABSN7*) fail "bootmode: FLASHPRO_ID wins over FLASHPRO_SERIAL" ;; *) pass "bootmode: FLASHPRO_ID wins over FLASHPRO_SERIAL" ;; esac
expect_out "bootmode: --flashpro wins over FLASHPRO_ID" "FlashPro used: SN9" env FAKE_FP_HONOUR=1 "$PY" "$HW/bootmode.py" 1 "$BME" --workdir "$BMW" --yes --flashpro SN9 --lab "$tmp/lab-bm-id.conf"
expect_out "bootmode: the name FlashPro Express shows for a FlashPro without a USB serial number is taken" "FlashPro used: B347B62F" env FAKE_FP_HONOUR=1 "$PY" "$HW/bootmode.py" 1 "$BME" --workdir "$BMW" --yes --flashpro B347B62F --lab "$LB"
# a FlashPro5 that FLASHPRO_SERIAL names is assumed to be S2 and the serial number; another model is taken as it is
printf 'FLASHPRO_SERIAL=FP5A1\n' | cat "$LB" - > "$tmp/lab-bm-fp5.conf"
expect_out "bootmode: a FlashPro5 that FLASHPRO_SERIAL names is S2 and the serial number" "FlashPro used: S2FP5A1" env FLASHPRO_SYSFS="$tmp/usb-fp5" FAKE_FP_HONOUR=1 "$PY" "$HW/bootmode.py" 1 "$BME" --workdir "$BMW" --yes --lab "$tmp/lab-bm-fp5.conf"
printf 'FLASHPRO_SERIAL=EFP6A1\n' | cat "$LB" - > "$tmp/lab-bm-efp6.conf"
expect_out "bootmode: an embedded FlashPro6 that FLASHPRO_SERIAL names is taken as it is" "FlashPro used: EFP6A1" env FLASHPRO_SYSFS="$tmp/usb-efp6" FAKE_FP_HONOUR=1 "$PY" "$HW/bootmode.py" 1 "$BME" --workdir "$BMW" --yes --lab "$tmp/lab-bm-efp6.conf"
expect_rc  "bootmode: a FlashPro5 name that fpgenprog does not honour exits 1 and nothing is programmed" 1 env FLASHPRO_SYSFS="$tmp/usb-fp5" "$PY" "$HW/bootmode.py" 1 "$BME" --workdir "$BMW" --yes --lab "$tmp/lab-bm-fp5.conf"
# the boot program
expect_rc  "bootmode: a missing ELF exits 2" 2 "$PY" "$HW/bootmode.py" 1 "$tmp/none.elf" --yes --lab "$LB"
expect_out "bootmode: a missing ELF names it and prints the help text" "none.elf' does not exist" "$PY" "$HW/bootmode.py" 1 "$tmp/none.elf" --yes --lab "$LB"
expect_out "bootmode: --dry-run without an ELF names bare_hello" "bare_hello.elf" "$PY" "$HW/bootmode.py" 1 --dry-run --lab "$LB"
expect_out "bootmode: mode 0 ignores an ELF and says so" "ignoring" "$PY" "$HW/bootmode.py" 0 "$BME" --workdir "$BMW" --yes --lab "$LB"
# without an ELF the example bare_hello is built (./x build bare_hello --hart e51): a tree with a stand-in x
mkdir -p "$tmp/bmroot/hw" "$tmp/bmroot/tools" "$tmp/bmroot/examples/bare_hello/bin-e51"
cp "$HW/bootmode.py" "$HW/bootprog.py" "$HW/flashpros.py" "$HW/fpexpress.py" "$HW/lab.py" "$HW/lab.conf.example" "$tmp/bmroot/hw/"
cp "$ROOT/tools/toolchain.env" "$tmp/bmroot/tools/"
printf '#!/bin/sh\necho "$@" > "%s/bmroot/x.args"\n' "$tmp" > "$tmp/bmroot/x"; chmod +x "$tmp/bmroot/x"
cp "$BME" "$tmp/bmroot/examples/bare_hello/bin-e51/bare_hello.elf"
fpreset
"$PY" "$tmp/bmroot/hw/bootmode.py" 1 --yes --lab "$LB" >/dev/null 2>&1
[ "$(cat "$tmp/bmroot/x.args" 2>/dev/null)" = "build bare_hello --hart e51" ] && pass "bootmode: without an ELF it builds bare_hello for the E51" || fail "bootmode: without an ELF it builds bare_hello for the E51"
fpgrep "envm_client .*$tmp/bmroot/build/bootmode/bootmode1/bare_hello-bm1-p0.hex" && programmed \
  && pass "bootmode: the default working directory is build/bootmode, the image is made from bare_hello.elf, and it is programmed" \
  || fail "bootmode: the default working directory is build/bootmode, the image is made from bare_hello.elf, and it is programmed (got: $(fpcalls | grep envm_client))"
printf '#!/bin/sh\nexit 3\n' > "$tmp/bmroot/x"
expect_rc  "bootmode: a failing build of bare_hello exits 2" 2 "$PY" "$tmp/bmroot/hw/bootmode.py" 1 --yes --lab "$LB"
# boot mode 0 needs no boot program: none is built, none is used
printf '#!/bin/sh\necho "$@" > "%s/bmroot/x.args"\n' "$tmp" > "$tmp/bmroot/x"
rm -f "$tmp/bmroot/x.args"; fpreset
"$PY" "$tmp/bmroot/hw/bootmode.py" 0 --yes --lab "$LB" >/dev/null 2>&1
[ ! -e "$tmp/bmroot/x.args" ] && fpgrep "envm_client .*--number_of_bytes 1 " && pass "bootmode: mode 0 without an ELF builds nothing and makes the one byte client" || fail "bootmode: mode 0 without an ELF builds nothing and makes the one byte client"
# without --lab, LAB_CONF and hw/lab.conf, hw/lab.conf.example is copied to hw/lab.conf
rm -f "$tmp/bmroot/hw/lab.conf"
env -u LAB_CONF "$PY" "$tmp/bmroot/hw/bootmode.py" 0 --dry-run >"$tmp/bmroot/copy.out" 2>&1
grep -q '^OCD_PORT=4444$' "$tmp/bmroot/hw/lab.conf" 2>/dev/null && grep -q '^BOOTMODE_PACKAGE=FCVG484$' "$tmp/bmroot/hw/lab.conf" && pass "bootmode: creates lab.conf from lab.conf.example when there is none" || fail "bootmode: creates lab.conf from lab.conf.example when there is none"
grep -q "created it from lab.conf.example" "$tmp/bmroot/copy.out" && pass "bootmode: says that it copied the example" || fail "bootmode: says that it copied the example"
printf 'OCD_PORT=1234\n' > "$tmp/bmroot/hw/lab.conf"
env -u LAB_CONF "$PY" "$tmp/bmroot/hw/bootmode.py" 0 --dry-run >/dev/null 2>&1
grep -q '^OCD_PORT=1234$' "$tmp/bmroot/hw/lab.conf" && pass "bootmode: leaves an existing lab.conf alone" || fail "bootmode: leaves an existing lab.conf alone"
rm -f "$tmp/bmroot/hw/lab.conf"
"$PY" "$tmp/bmroot/hw/bootmode.py" 0 --dry-run --lab "$LB" >/dev/null 2>&1
[ ! -e "$tmp/bmroot/hw/lab.conf" ] && pass "bootmode: --lab does not create lab.conf" || fail "bootmode: --lab does not create lab.conf"
LAB_CONF="$LB" "$PY" "$tmp/bmroot/hw/bootmode.py" 0 --dry-run >/dev/null 2>&1
[ ! -e "$tmp/bmroot/hw/lab.conf" ] && pass "bootmode: LAB_CONF does not create lab.conf" || fail "bootmode: LAB_CONF does not create lab.conf"
# the copy of lab.conf.example has no header lines; the keys and their notes stay
rm -f "$tmp/bmroot/hw/lab.conf"
env -u LAB_CONF "$PY" "$tmp/bmroot/hw/bootmode.py" 0 --dry-run >/dev/null 2>&1
if [ -f "$tmp/bmroot/hw/lab.conf" ] && ! grep -q 'lab.conf.example --' "$tmp/bmroot/hw/lab.conf" && ! grep -q 'Copy it to' "$tmp/bmroot/hw/lab.conf" \
   && grep -q '^OPENOCD=' "$tmp/bmroot/hw/lab.conf" && grep -q '^#   FPGENPROG ' "$tmp/bmroot/hw/lab.conf"; then
  pass "bootmode: the new lab.conf has no header lines, but the keys and the notes on them"
else fail "bootmode: the new lab.conf has no header lines, but the keys and the notes on them"; fi
rm -f "$tmp/bmroot/hw/lab.conf"
# colour only where the terminal supports it
out="$("$PY" "$HW/bootmode.py" 0 --dry-run --lab "$LB" 2>&1)"
case "$out" in *$'\033'*) fail "bootmode: no colour when the output is not a terminal" ;; *) pass "bootmode: no colour when the output is not a terminal" ;; esac
out="$(FORCE_COLOR=1 "$PY" "$HW/bootmode.py" 0 --dry-run --lab "$LB" 2>&1)"
case "$out" in *$'\033['*) pass "bootmode: FORCE_COLOR colours the messages" ;; *) fail "bootmode: FORCE_COLOR colours the messages" ;; esac
out="$(NO_COLOR=1 FORCE_COLOR=1 "$PY" "$HW/bootmode.py" 0 --dry-run --lab "$LB" 2>&1)"
case "$out" in *$'\033'*) fail "bootmode: NO_COLOR wins over FORCE_COLOR" ;; *) pass "bootmode: NO_COLOR wins over FORCE_COLOR" ;; esac
# the payloads and the fpgenprog calls against what the Java tool made (hw/bootprog.py, tests/host/hw/bootprog_test.py)
out="$("$PY" -I "$ROOT/tests/host/hw/bootprog_test.py" "$tc" "$tmp/bp" 2>&1)"; rc=$?
echo "$out" | grep -v '^ok:' | sed 's/^/  bootprog_test: /'
[ $rc -eq 0 ] && pass "bootprog: $(echo "$out" | grep -c '^ok:') checks of the images, the certificate, the options and the FlashPro" || fail "bootprog: the checks of bootprog_test.py failed (see above)"

# --- Ctrl+C -------------------------------------------------------------------------
# run_signal <signal> <delay> <limit> <out> <command...>: start the command (default signal dispositions) in a session of its own, send
# the signal to its whole process group (as the terminal does for Ctrl+C) <delay> seconds after the file
# $ready exists (at once if it is not set), then again after $again seconds (if set), and wait at most
# <limit> seconds for the command to end. Sets rc (137: it had to be killed) and ms (from the last signal to
# the end).
ready=""; again=""
run_signal () {
  local sig="$1" delay="$2" limit="$3" out="$4" p t0 t1 i
  shift 4
  # A background job of a script ignores SIGINT, and the ignoring is inherited; the terminal's Ctrl+C
  # reaches processes that do not ignore it, so the launcher restores the defaults and starts a session.
  "$PY" -I -c 'import os, signal, sys
for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(s, signal.SIG_DFL)
os.setsid()
os.execvp(sys.argv[1], sys.argv[1:])' "$@" >"$out" 2>&1 &
  p=$!
  if [ -n "$ready" ]; then for i in $(seq 1 100); do [ -s "$ready" ] && break; sleep 0.05; done; fi
  sleep "$delay"
  kill -"$sig" -- "-$p" 2>/dev/null
  if [ -n "$again" ]; then sleep "$again"; kill -"$sig" -- "-$p" 2>/dev/null; fi
  t0=$(date +%s%N)
  while kill -0 "$p" 2>/dev/null; do
    t1=$(date +%s%N)
    if [ $(( (t1 - t0) / 1000000 )) -gt $(( limit * 1000 )) ]; then
      kill -KILL -- "-$p" 2>/dev/null; wait "$p" 2>/dev/null; rc=137; ms=$(( (t1 - t0) / 1000000 )); return
    fi
    sleep 0.05
  done
  wait "$p"; rc=$?
  ms=$(( ($(date +%s%N) - t0) / 1000000 ))
}
gone () { ! kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }   # the process whose pid is in the file does not run any more

# The python scripts against an OpenOCD that stops answering: Ctrl+C ends them at once, with exit status 130
# and one line, not after the 30 s socket timeout and not with a traceback.
serve hung --hang-on halt
LH="$tmp/lab-hung.conf"
run_signal INT 1 6 "$tmp/sig.out" "$PY" "$HW/run_image.py" "$tmp/loop.elf" 0 --lab "$LH"
[ $rc -eq 130 ] && [ $ms -lt 3000 ] && grep -q 'interrupted (Ctrl+C)' "$tmp/sig.out" && ! grep -q Traceback "$tmp/sig.out" \
  && pass "run_image: Ctrl+C while OpenOCD does not answer exits 130 at once, with one line" \
  || fail "run_image: Ctrl+C while OpenOCD does not answer exits 130 at once, with one line (rc $rc, $ms ms: $(head -c 300 "$tmp/sig.out"))"
grep -q "may be halted" "$tmp/sig.out" && pass "run_image: the line says that the hart may be halted" || fail "run_image: the line says that the hart may be halted"
run_signal INT 1 6 "$tmp/sig.out" "$PY" "$HW/run_probe.py" probe_time.S 1 --lab "$LH"
[ $rc -eq 130 ] && [ $ms -lt 3000 ] && grep -q 'interrupted (Ctrl+C)' "$tmp/sig.out" && ! grep -q Traceback "$tmp/sig.out" \
  && pass "run_probe: Ctrl+C while OpenOCD does not answer exits 130 at once, with one line" \
  || fail "run_probe: Ctrl+C while OpenOCD does not answer exits 130 at once, with one line (rc $rc, $ms ms: $(head -c 300 "$tmp/sig.out"))"
run_signal INT 1 6 "$tmp/sig.out" "$PY" "$HW/monitor.py" --secs 30 --lab "$tmp/lab-mon.conf"
[ $rc -eq 130 ] && [ $ms -lt 3000 ] && grep -q 'interrupted (Ctrl+C)' "$tmp/sig.out" && ! grep -q Traceback "$tmp/sig.out" && ! grep -q hart "$tmp/sig.out" \
  && pass "monitor: Ctrl+C exits 130 at once, with one line that does not mention a hart" \
  || fail "monitor: Ctrl+C exits 130 at once, with one line that does not mention a hart (rc $rc, $ms ms: $(head -c 300 "$tmp/sig.out"))"

# start_openocd.sh runs OpenOCD as a child and ends it after Ctrl+C. Stand-ins for openocd write their pid
# to a file: "stubborn" ignores SIGINT, SIGTERM and SIGHUP (OpenOCD stuck in a timeout loop), "polite" ends on them.
standin () {   # standin <name> <script body>: an OpenOCD directory $tmp/ocd-<name> whose openocd writes its pid to $tmp/<name>.pid
  mkdir -p "$tmp/ocd-$1/bin"
  printf '#!/bin/sh\necho $$ > "%s/%s.pid"\n%s\n' "$tmp" "$1" "$2" > "$tmp/ocd-$1/bin/openocd"
  chmod +x "$tmp/ocd-$1/bin/openocd"
}
standin stubborn "trap '' INT TERM HUP
while :; do sleep 0.1; done"
standin polite "trap 'exit 0' INT TERM HUP
while :; do sleep 0.1 & wait \$!; done"
standin quits "sleep 0.3
exit 7"
# supervise <signal> <stand-in> <grace> [second signal delay]: start_openocd.sh over the stand-in and signal it once it runs
supervise () {
  rm -f "$tmp/$2.pid"
  ready="$tmp/$2.pid" again="${4:-}" START_OPENOCD_GRACE="$3" OPENOCD="$tmp/ocd-$2" LAB_CONF="$tmp/none.conf" \
    run_signal "$1" 0.3 20 "$tmp/sup.out" sh "$HW/start_openocd.sh"
  ready="" again=""
}
supervise INT stubborn 1
[ $rc -eq 130 ] && [ $ms -ge 800 ] && [ $ms -lt 3000 ] && pass "start_openocd: an OpenOCD that ignores SIGINT is killed after the grace period, exit 130" \
  || fail "start_openocd: an OpenOCD that ignores SIGINT is killed after the grace period, exit 130 (rc $rc, $ms ms: $(cat "$tmp/sup.out"))"
gone "$tmp/stubborn.pid" && pass "start_openocd: no OpenOCD is left behind after SIGINT" || fail "start_openocd: no OpenOCD is left behind after SIGINT (pid $(cat "$tmp/stubborn.pid"))"
grep -q "killing it" "$tmp/sup.out" && pass "start_openocd: says that it killed OpenOCD" || fail "start_openocd: says that it killed OpenOCD ($(cat "$tmp/sup.out"))"
supervise INT polite 5
[ $rc -eq 130 ] && [ $ms -lt 1500 ] && pass "start_openocd: an OpenOCD that ends on SIGINT is not waited for until the grace period is over" \
  || fail "start_openocd: an OpenOCD that ends on SIGINT is not waited for until the grace period is over (rc $rc, $ms ms)"
gone "$tmp/polite.pid" && pass "start_openocd: no polite OpenOCD is left behind" || fail "start_openocd: no polite OpenOCD is left behind"
supervise TERM stubborn 1
[ $rc -eq 143 ] && [ $ms -lt 3000 ] && gone "$tmp/stubborn.pid" && pass "start_openocd: SIGTERM ends it too, exit 143, nothing left behind" \
  || fail "start_openocd: SIGTERM ends it too, exit 143, nothing left behind (rc $rc, $ms ms)"
supervise HUP stubborn 1
[ $rc -eq 129 ] && [ $ms -lt 3000 ] && gone "$tmp/stubborn.pid" && pass "start_openocd: SIGHUP (closed terminal) ends it too, exit 129, nothing left behind" \
  || fail "start_openocd: SIGHUP (closed terminal) ends it too, exit 129, nothing left behind (rc $rc, $ms ms)"
supervise INT stubborn 10 0.5
[ $rc -eq 130 ] && [ $ms -lt 2000 ] && gone "$tmp/stubborn.pid" && pass "start_openocd: a second Ctrl+C kills OpenOCD at once" \
  || fail "start_openocd: a second Ctrl+C kills OpenOCD at once (rc $rc, $ms ms)"
rm -f "$tmp/quits.pid"
START_OPENOCD_GRACE=1 OPENOCD="$tmp/ocd-quits" LAB_CONF="$tmp/none.conf" sh "$HW/start_openocd.sh" >/dev/null 2>&1; rc=$?
[ $rc -eq 7 ] && pass "start_openocd: the exit status of OpenOCD is passed on" || fail "start_openocd: the exit status of OpenOCD is passed on (exit $rc)"
expect_rc  "start_openocd: a bad grace period exits 2" 2 env START_OPENOCD_GRACE=soon OPENOCD="$tmp/ocd-quits" LAB_CONF="$tmp/none.conf" sh "$HW/start_openocd.sh"

# ./x hw openocd: the signal goes to x, hw.sh, the supervisor and OpenOCD alike, and none of them may hold it up
rm -f "$tmp/stubborn.pid"
ready="$tmp/stubborn.pid" START_OPENOCD_GRACE=1 OPENOCD="$tmp/ocd-stubborn" LAB_CONF="$tmp/none.conf" run_signal INT 0.3 20 "$tmp/sup.out" "$X" hw openocd
ready=""
[ $rc -eq 130 ] && [ $ms -lt 3000 ] && gone "$tmp/stubborn.pid" && pass "x hw openocd: Ctrl+C ends OpenOCD, exit 130, nothing left behind" \
  || fail "x hw openocd: Ctrl+C ends OpenOCD, exit 130, nothing left behind (rc $rc, $ms ms: $(cat "$tmp/sup.out"))"

# --- lab.conf ---------------------------------------------------------------------
grep -Eq '^OPENOCD=$' "$HW/lab.conf.example" && grep -q '^UART_PATTERN=.*{n}' "$HW/lab.conf.example" \
  && grep -q '^OCD_PORT=4444$' "$HW/lab.conf.example" \
  && pass "lab.conf.example: the OpenOCD directory, the OpenOCD port and the serial pattern" \
  || fail "lab.conf.example: the OpenOCD directory, the OpenOCD port and the serial pattern"
git -C "$HW" check-ignore -q lab.conf 2>/dev/null && pass "lab.conf is ignored by git" || fail "lab.conf is ignored by git"
printf 'OCD_PORT=5555\n' > "$tmp/lab-onlyport.conf"
[ "$("$PY" -c 'import sys; sys.path.insert(0, sys.argv[1]); import lab; v = lab.load(sys.argv[2]); print(v["OCD_PORT"], repr(v["OPENOCD"]), v["BOOTMODE_DIE"])' "$HW" "$tmp/lab-onlyport.conf")" = "5555 '' MPFS250T_ES" ] \
  && pass "lab.py: a key that the conf does not set takes its default from lab.conf.example" \
  || fail "lab.py: a key that the conf does not set takes its default from lab.conf.example"

# --- mss_init.py and initialize.py -----------------------------------------------------
init () { "$PY" "$HW/initialize.py" "$@"; }
serve init
LI="$tmp/lab-init.conf"
expect_rc  "initialize: --minimal against the stand-in exits 0" 0 init --minimal --lab "$LI"
w="$(grep '^mww' "$tmp/init.log")"
[ "$(printf '%s\n' "$w" | sed -n '1,2p;3,6p' | tr '\n' '|')" = "mww 0x2000200C 0x7D|mww 0x2000200C 0x1007D|mww 0x37080008 0x8A080|mww 0x20002098 0x1|mww 0x200031BC 0x3800|mww 0x20007C18 0xF00050CC|" ] \
  && pass "initialize: --minimal writes the five things CLINT.MTIME needs, in order" || fail "initialize: --minimal writes the five things CLINT.MTIME needs, in order ($w)"
# after the six steps come only the nine command lines (six words each) that clear the PLIC enables
[ "$(printf '%s\n' "$w" | wc -l)" = 15 ] && [ "$(printf '%s\n' "$w" | sed -n '7,$p' | grep -vc '^mww 0xc002[0-9a-f]* 0; ')" = 0 ] \
  && [ "$(grep -o 'mww 0xc002[0-9a-f]* 0' "$tmp/init.log" | wc -l)" = 54 ] \
  && pass "initialize: --minimal writes nothing else than the 54 PLIC enable words of nine contexts" \
  || fail "initialize: --minimal writes nothing else than the 54 PLIC enable words of nine contexts"
[ "$(grep -c '^reg fcsr 0$' "$tmp/init.log")" = 4 ] \
  && pass "initialize: clears fcsr of the four U54" || fail "initialize: clears fcsr of the four U54"
grep -q '^halt$' "$tmp/init.log" && grep -q '^resume$' "$tmp/init.log" && pass "initialize: halts the hart and resumes it at the end" || fail "initialize: halts the hart and resumes it at the end"
expect_out "initialize: --dry-run prints the steps" "mww 0x20007C18 0xF00050CC    ;# CFG_DDR_SGMII_PHY.CLK_CNTL" init --minimal --dry-run
: > "$tmp/init.log"
init --dry-run >/dev/null 2>&1
[ ! -s "$tmp/init.log" ] && pass "initialize: --dry-run does not touch OpenOCD" || fail "initialize: --dry-run does not touch OpenOCD"
full="$(init --dry-run)"
case "$full" in *"MSSIO_CONTROL_CR"*"IOSCB_MUX_SGMII.SOFT_RESET"*"PLL_CTRL.LOCK"*) pass "initialize: the full sequence has the MSSIO handshake, the SGMII set-up and the PLL lock in this order" ;; *) fail "initialize: the full sequence order" ;; esac
case "$full" in *"ENVM_CR"*|*"CLOCK_CONFIG_CR"*|*"MSSCLKMUX"*) fail "initialize: the full sequence leaves out the clock switch (found one of ENVM_CR, CLOCK_CONFIG_CR, MSSCLKMUX)" ;; *) pass "initialize: the full sequence leaves out the clock switch" ;; esac
case "$(init --dry-run --skip-io)" in *IOMUX*) fail "initialize: --skip-io leaves out the IO set-up" ;; *) pass "initialize: --skip-io leaves out the IO set-up" ;; esac
case "$full" in *IOMUX0_CR*) pass "initialize: the IO set-up is part of the full sequence" ;; *) fail "initialize: the IO set-up is part of the full sequence" ;; esac
# the stand-in reads every word as 0: the first poll runs out of time, which is exit status 2 and a message
expect_out "initialize: a poll that never succeeds is an error that names it" "PVT_STAT.IOEN" init --lab "$LI"
expect_rc  "initialize: a poll that never succeeds exits 2" 2 init --lab "$LI"
printf 'OCD_PORT=1\nOPENOCD=%s\nUART_PATTERN=x{n}\nUART_COUNT=4\n' "$tmp/ocd" > "$tmp/lab-nothing.conf"
expect_rc  "initialize: no OpenOCD is exit status 2" 2 init --minimal --lab "$tmp/lab-nothing.conf"
expect_rc  "l2_scratchpad: no OpenOCD is exit status 2" 2 "$PY" "$HW/l2_scratchpad.py" --lab "$tmp/lab-nothing.conf"
expect_rc  "l2_scratchpad: no cache way is exit status 2" 2 "$PY" "$HW/l2_scratchpad.py" --cache-ways 0 --lab "$tmp/lab-nothing.conf"
expect_rc  "l2_scratchpad: more than 16 ways is exit status 2" 2 "$PY" "$HW/l2_scratchpad.py" --scratchpad-ways 16 --lab "$tmp/lab-nothing.conf"
# the executor itself, with reads that satisfy the polls
"$PY" - "$HW" <<'PYEOF' && pass "mss_init.run: writes, read-modify-writes, polls, the silicon variant and the delays" || fail "mss_init.run: writes, read-modify-writes, polls, the silicon variant and the delays"
import sys
sys.path.insert(0, sys.argv[1])
import mss_init as m
mem = {m.PVT_STAT: (1 << 6) | (1 << 14), m.PLL_CNTL: 1 << 7, m.RECAL_CNTL: 1 << 23, m.PLL_MSS + 4: 1 << 25,
       m.SUBBLK_CLOCK_CR: 1, m.SOFT_RESET_CR: 0x3FFFFFFE, m.SPARE_STAT: 1 << 31, m.IO_CALIB_SGMII + 4: 0xE000}
writes, slept = [], []
status = {m.PVT_STAT, m.PLL_CNTL, m.RECAL_CNTL, m.PLL_MSS + 4, m.SPARE_STAT}  # read-only status: a write does not change it
def write(a, v, what):
    writes.append((a, v))
    if a not in status:
        mem[a] = v
m.run(m.full(), write, lambda a: mem.get(a, 0), sleep=slept.append)
assert (m.SUBBLK_CLOCK_CR, 7) in writes and (m.SOFT_RESET_CR, 0x3FFFFFF8) in writes, writes
assert (m.PVT_STAT, (1 << 6) | (1 << 14) | 0x40000000) in writes
assert (m.IO_CALIB_SGMII + 4, 0xE000 | (1 << 14)) in writes
assert writes.count((m.DYN_CNTL, 0x607F)) == 2, "rev C: the lanes are reset twice"
assert 0.01 in slept, slept
n_revc = len(writes)
mem[m.SPARE_STAT] = 0
writes.clear()
m.run(m.full(), write, lambda a: mem.get(a, 0), sleep=slept.append)
assert writes.count((m.DYN_CNTL, 0x607F)) == 1 and len(writes) == n_revc - 2, "rev B: the lanes are reset once"
assert not any(a in (m.SYSREG + 0xB8, m.SYSREG + 0x008, m.MUX_MSS + 0x0C) for a, _ in writes), "no clock switch"
t = iter(range(100))
try:
    m.run([m.Poll(0x10, 1, 1, "never", 1.0)], write, lambda a: 0, sleep=lambda s: None, monotonic=lambda: next(t) * 0.5)
    raise SystemExit("a poll that never succeeds did not fail")
except m.MssInitError as e:
    assert "never" in str(e)
PYEOF

# tests/hw/run_matrix.sh: a cell runs without a console flag first (the examples are primary images: they bring their UART
# up themselves), then with --uart-clocks, then with --uart-standin, and the line of the cell says which one passed. A copy
# of the script in a tree with a stand-in ./x that passes only with the flag in $MX_NEED.
mx="$tmp/mx"
mkdir -p "$mx/tests/hw" "$mx/tests/qemu" "$mx/examples/foo/bin-e51"
cp "$ROOT/tests/hw/run_matrix.sh" "$mx/tests/hw/"
: > "$mx/examples/foo/bin-e51/foo_test.elf"
printf 'name\tdir\tserial\texpect\tobserve\twhy\nfoo_test_e51\texamples/foo\t0\tpass\t-\t-\n' > "$mx/tests/qemu/tests.list"
cat > "$mx/x" <<'XEOF'
#!/usr/bin/env bash
case "$1" in
  build) exit 0 ;;
  hw) shift
      case "$1" in
        reset|initialize) exit 0 ;;
        run) flag=none
             for a in "$@"; do case "$a" in --uart-clocks|--uart-standin) flag="$a" ;; esac; done
             echo "$flag" >> "$MX_LOG"
             if [ "$flag" = "$MX_NEED" ]; then echo "TEST ${MX_TEST:-foo_test_e51}: PASS"; exit 0; fi
             if [ -n "${MX_GARBAGE:-}" ]; then echo "garbage"; exit 1; fi
             echo "no serial output on any port"; exit 1 ;;
      esac ;;
esac
exit 2
XEOF
chmod +x "$mx/x"
matrix () {   # matrix <flag that makes the stand-in pass>: output of the script; the flags it tried are in $tmp/mx.flags
  : > "$tmp/mx.flags"
  MX_NEED="$1" MX_LOG="$tmp/mx.flags" bash "$mx/tests/hw/run_matrix.sh" -o "$tmp/mx.out" 2>&1
}
out="$(matrix none)"
case "$out" in *"foo_test_e51"*"PASS"*"(no flag, hart 0, port 0)"*) pass "run_matrix: a cell that passes without a flag says so" ;; *) fail "run_matrix: a cell that passes without a flag says so ($out)" ;; esac
[ "$(tr '\n' ' ' < "$tmp/mx.flags")" = "none " ] && pass "run_matrix: that cell is run once, without a flag" || fail "run_matrix: that cell is run once, without a flag ($(cat "$tmp/mx.flags"))"
out="$(matrix --uart-clocks)"
case "$out" in *"PASS"*"(clocks, hart 0, port 0)"*) pass "run_matrix: a silent cell is run again with --uart-clocks" ;; *) fail "run_matrix: a silent cell is run again with --uart-clocks ($out)" ;; esac
[ "$(tr '\n' ' ' < "$tmp/mx.flags")" = "none --uart-clocks " ] && pass "run_matrix: no flag first, then --uart-clocks" || fail "run_matrix: no flag first, then --uart-clocks ($(cat "$tmp/mx.flags"))"
out="$(matrix --uart-standin)"
case "$out" in *"PASS"*"(standin, hart 0, port 0)"*) pass "run_matrix: and last with --uart-standin" ;; *) fail "run_matrix: and last with --uart-standin ($out)" ;; esac
[ "$(tr '\n' ' ' < "$tmp/mx.flags")" = "none --uart-clocks --uart-standin " ] && pass "run_matrix: the order is no flag, --uart-clocks, --uart-standin" || fail "run_matrix: the order is no flag, --uart-clocks, --uart-standin ($(cat "$tmp/mx.flags"))"
out="$(matrix impossible)"
case "$out" in *"FAIL"*"pass 0, fail 1"*) pass "run_matrix: a cell that passes with no set-up fails" ;; *) fail "run_matrix: a cell that passes with no set-up fails ($out)" ;; esac

# console_noinit_test does not set the divisor by design: it is run once, with --uart-standin, and counted as passed.
# The stand-in ./x prints garbage without a flag and with --uart-clocks (a console that printed something).
mkdir -p "$mx/examples/foo/bin-e51"
: > "$mx/examples/foo/bin-e51/console_noinit_test.elf"
printf 'name\tdir\tserial\texpect\tobserve\twhy\nconsole_noinit_test_e51\texamples/foo\t0\tpass\t-\t-\n' > "$mx/tests/qemu/tests.list"
out="$(MX_TEST=console_noinit_test_e51 MX_GARBAGE=1 matrix --uart-standin)"
case "$out" in *"console_noinit_test_e51"*"PASS"*"(standin, hart 0, port 0)"*"pass 1, fail 0"*) pass "run_matrix: console_noinit_test passes with --uart-standin" ;; *) fail "run_matrix: console_noinit_test passes with --uart-standin ($out)" ;; esac
[ "$(tr '\n' ' ' < "$tmp/mx.flags")" = "--uart-standin " ] && pass "run_matrix: console_noinit_test is run once, with --uart-standin only" || fail "run_matrix: console_noinit_test is run once, with --uart-standin only ($(cat "$tmp/mx.flags"))"

# flashpros: a fake sysfs with two FlashPro (vendor 1514), a CP2108 and a hub without serial number
fs="$tmp/sysfs"; mkdir -p "$fs"
mkusb () { mkdir -p "$fs/$1"; echo "$2" > "$fs/$1/idVendor"; echo "$3" > "$fs/$1/idProduct"; [ -z "$4" ] || echo "$4" > "$fs/$1/product"; [ -z "$5" ] || echo "$5" > "$fs/$1/serial"; }
mkusb 1-1 1514 200b "Embedded FP6b" FP6A0001
mkusb 1-2 1514 2008 "FlashPro5" FP5A0002
mkusb 1-4 1514 2009 "FlashPro6" FP6A0003
mkusb 1-5 1514 200a "Other" OTHER0004
mkusb 1-3 10c4 ea71 "CP2108" CPSERIAL
mkusb usb1 1d6b 0002 "Host Controller" ""
FPL () { "$PY" "$HW/flashpros.py" --sysfs "$fs" "$@"; }
expect_out "flashpros: lists the serial of the first FlashPro, with its model" "FP6A0001  1514:200b  Embedded FP6b  efp6" FPL
expect_out "flashpros: lists the serial of the second FlashPro, with its model" "FP5A0002  1514:2008  FlashPro5  fp5" FPL
expect_out "flashpros: product ID 2009 is a FlashPro6" "FP6A0003  1514:2009  FlashPro6  fp6" FPL
expect_out "flashpros: a product ID that is not known is unknown" "OTHER0004  1514:200a  Other  unknown" FPL
expect_out "flashpros: --model prints the models" "efp6" FPL --model
expect_out "flashpros: --model --serial prints the model of that FlashPro" "fp5" FPL --model --serial FP5A0002
case "$(FPL --model --serial FP5A0002 2>&1)" in *efp6*) fail "flashpros: --model --serial prints only that model" ;; *) pass "flashpros: --model --serial prints only that model" ;; esac
expect_rc  "flashpros: --model for a serial number that is not there exits 1" 1 FPL --model --serial NOSUCH
expect_rc  "flashpros: two adapters found exits 0" 0 FPL
case "$(FPL 2>&1)" in *CPSERIAL*) fail "flashpros: a CP2108 is not a FlashPro" ;; *) pass "flashpros: a CP2108 is not listed" ;; esac
expect_out "flashpros: --all lists the CP2108 too" "CPSERIAL" FPL --all
expect_rc  "flashpros: no adapter of the vendor exits 1" 1 FPL --vendor dead
expect_rc  "flashpros: no sysfs exits 2" 2 "$PY" "$HW/flashpros.py" --sysfs "$tmp/no-such-sysfs"

# --- program.py ---------------------------------------------------------------------
# FPExpress is a stand-in (fake_fpexpress.py) that records the Tcl scripts it is given and prints the lines the
# detection reads. What this cannot show: that the real FPExpress prints those lines, and what its exit status
# is: the Tcl exit of the programming script is not run here.
mkdir -p "$tmp/pg"
export FAKE_FPE_LOG="$tmp/pg/fpe.log"
printf '#!/bin/sh\nexec "%s" "%s/tests/host/hw/fake_fpexpress.py" "$@"\n' "$PY" "$ROOT" > "$tmp/pg/FPExpress"
chmod +x "$tmp/pg/FPExpress"
STP="$tmp/pg/design.stp"; : > "$STP"; STP="$(readlink -f "$STP")"
PGW="$tmp/pg/work"
printf 'FPEXPRESS=%s/pg/FPExpress\nOCD_PORT=1\n' "$tmp" > "$tmp/lab-pg.conf"
PL="$tmp/lab-pg.conf"
pgcmd=("$PY" "$HW/program.py" "$STP" --workdir "$PGW" --lab "$PL")
fpereset () { rm -f "$FAKE_FPE_LOG"; rm -rf "$PGW"; }
fpelog () { cat "$FAKE_FPE_LOG" 2>/dev/null; }
fpescripts () { fpelog | grep -c '^=== '; }
fpelog_has () { fpelog | grep -q -F -- "$1"; }

# the programmer lines of an embedded FlashPro6, as FlashPro Express printed them on a board: the name is the one in quotes
# (the first line has "Embedded" where a name might be expected)
pgparse () { "$PY" -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import program; print(program.programmers_in(sys.stdin.read()))' "$HW"; }
real=$'  Programmer: Embedded FP6 \'B347B62F\' : Version = EF9B\n  ===============================================================\n  programmer \'B347B62F\' : Embedded FlashPro6\n  Created new project \'/work/build/program/job/PolarfireProg/PolarfireProg.pro\'\n  Error:  Parameter \'name\' is missing or has invalid value.\n  Error:  The command \'auto_construct_job_project\' failed.\n'
[ "$(printf '%s' "$real" | pgparse)" = "['B347B62F']" ] && pass "program: reads the programmer name from the quotes of the lines FlashPro Express printed on a board (not 'Embedded')" || fail "program: reads the programmer name from the quotes (got $(printf '%s' "$real" | pgparse))"
[ "$(printf "programmer 'S200BM0VJ' : FlashPro5\nprogrammer 'B347B62F' : Embedded FlashPro6\n" | pgparse)" = "['S200BM0VJ', 'B347B62F']" ] && pass "program: two programmers give two names, in order" || fail "program: two programmers give two names, in order"
[ "$(printf 'Created new project /x\nError: Parameter name\n' | pgparse)" = "[]" ] && pass "program: no programmer lines give no name" || fail "program: no programmer lines give no name"
# the device line of the scan of an MPFS250 on a board: the name has parentheses and a bar
pgdev () { "$PY" -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import program; print(program.devices_in(sys.stdin.read()))' "$HW"; }
[ "$(printf "programmer 'B347B62F' : Found 8 instruction register bits.\nprogrammer 'B347B62F' : Device 1: F81A1CF Mfr: Microsemi Part: MPFS250(T_ES|TS_ES)\nprogrammer 'B347B62F' : Check Chain...\n" | pgdev)" = "['MPFS250(T_ES|TS_ES)']" ] \
  && pass "program: reads the device name of an MPFS250 with its parentheses and bar from the scan" || fail "program: reads the device name of an MPFS250 from the scan"
fpereset
expect_rc  "program: --yes detects, programs and exits 0" 0 "${pgcmd[@]}" --yes
[ "$(fpescripts)" = 3 ] && pass "program: without names it runs three scripts: the programmer, the chain, the programming" || fail "program: without names it runs three scripts (got $(fpescripts))"
fpelog_has "-programmer {FAKEPRG01}" && fpelog_has "enable_device -name {MPF500T} -enable 1" \
  && fpelog_has "set_programming_file -name {MPF500T} -file {$STP}" && fpelog_has "set_programming_action -name {MPF500T} -action {PROGRAM}" \
  && fpelog_has "run_selected_actions" \
  && pass "program: the programming script names the programmer and the device found, the file and the action" \
  || fail "program: the programming script names the programmer and the device found, the file and the action"
fpelog_has "-job_project_location {$PGW/job}" && pass "program: the job project is in <workdir>/job" || fail "program: the job project is in <workdir>/job"
[ -d "$PGW/job" ] && pass "program: the job project directory exists (FlashPro Express does not make it; the stand-in stops without it)" || fail "program: the job project directory exists"
[ -f "$PGW/program.tcl" ] && [ -f "$PGW/program.log" ] && [ -f "$PGW/detect_programmer.tcl" ] && [ -f "$PGW/detect_device.tcl" ] \
  && pass "program: the scripts and the log stay in the workdir" || fail "program: the scripts and the log stay in the workdir"
expect_out "program: shows the output of FlashPro Express" "fake FPExpress: PROGRAM MPF500T on FAKEPRG01" "${pgcmd[@]}" --yes
expect_out "program: prints what it did and for how long" "program: PROGRAM of MPF500T through programmer FAKEPRG01 took" "${pgcmd[@]}" --yes
fpereset; "${pgcmd[@]}" --yes --programmer FAKEPRG01 --device MPF500T >/dev/null 2>&1
[ "$(fpescripts)" = 1 ] && pass "program: --programmer and --device skip both detections" || fail "program: --programmer and --device skip both detections (got $(fpescripts) scripts)"
printf 'FPEXPRESS=%s/pg/FPExpress\nOCD_PORT=1\nFLASHPRO_ID=LABPRG7\n' "$tmp" > "$tmp/lab-pg2.conf"
fpereset; FAKE_FPE_PROGRAMMERS=LABPRG7 "$PY" "$HW/program.py" "$STP" --workdir "$PGW" --lab "$tmp/lab-pg2.conf" --yes >/dev/null 2>&1
{ [ "$(fpescripts)" = 2 ] && fpelog_has "-programmer {LABPRG7}"; } && pass "program: FLASHPRO_ID of lab.conf names the programmer, so only the chain is scanned" || fail "program: FLASHPRO_ID of lab.conf names the programmer (got $(fpescripts) scripts)"
# the serial of OpenOCD (FLASHPRO_SERIAL) is not the name FlashPro Express uses: 00BM80VJ against S200BM0VJ on a real board
printf 'FPEXPRESS=%s/pg/FPExpress\nOCD_PORT=1\nFLASHPRO_SERIAL=00BM80VJ\n' "$tmp" > "$tmp/lab-pg2b.conf"
fpereset; FAKE_FPE_PROGRAMMERS=S200BM0VJ "$PY" "$HW/program.py" "$STP" --workdir "$PGW" --lab "$tmp/lab-pg2b.conf" --yes >/dev/null 2>&1
{ [ "$(fpescripts)" = 3 ] && fpelog_has "-programmer {S200BM0VJ}" && ! fpelog_has "00BM80VJ"; } && pass "program: FLASHPRO_SERIAL (the serial of OpenOCD) is not taken for the programmer; FlashPro Express finds its own name" || fail "program: FLASHPRO_SERIAL is not taken for the programmer (got $(fpescripts) scripts)"
# a FlashPro5 that FLASHPRO_SERIAL names: FlashPro Express is assumed to call it "S2" and the serial number, and the guess is
# checked against the programmers FlashPro Express finds (the model comes from FLASHPRO_TYPE or from the USB descriptors)
printf 'FPEXPRESS=%s/pg/FPExpress\nOCD_PORT=1\nFLASHPRO_SERIAL=FP5A1\n' "$tmp" > "$tmp/lab-pg7.conf"
pg7 () { env FLASHPRO_SYSFS="$tmp/usb-fp5" ${PG7ENV:+"$PG7ENV"} "$PY" "$HW/program.py" "$STP" --workdir "$PGW" --lab "$tmp/lab-pg7.conf" "$@"; }   # PG7ENV: one NAME=value for the run
fpereset; PG7ENV=FAKE_FPE_PROGRAMMERS=S2FP5A1 pg7 --yes >/dev/null 2>&1
{ [ "$(fpescripts)" = 3 ] && fpelog_has "-programmer {S2FP5A1}"; } \
  && pass "program: a FlashPro5 that FLASHPRO_SERIAL names is S2 and the serial, and the programmers are looked for to check it" || fail "program: a FlashPro5 that FLASHPRO_SERIAL names is S2 and the serial (got $(fpescripts) scripts)"
PG7ENV=FAKE_FPE_PROGRAMMERS=OTHER expect_rc  "program: a derived name that FlashPro Express does not find exits 2" 2 pg7 --yes
PG7ENV=FAKE_FPE_PROGRAMMERS=OTHER expect_out "program: ... and says how the name was derived and what was found" "derived from FLASHPRO_SERIAL FP5A1" pg7 --yes
fpereset; PG7ENV=FAKE_FPE_PROGRAMMERS=S2FP5A1,OTHER pg7 --yes --programmer OTHER >/dev/null 2>&1
fpelog_has "-programmer {OTHER}" && ! fpelog_has "S2FP5A1" && pass "program: --programmer wins over the name derived from FLASHPRO_SERIAL" || fail "program: --programmer wins over the name derived from FLASHPRO_SERIAL"
expect_rc  "program: --scan does not use the derived name and lists what is found" 0 env FLASHPRO_SYSFS="$tmp/usb-fp5" FAKE_FPE_PROGRAMMERS=OTHER "$PY" "$HW/program.py" --scan --workdir "$PGW" --lab "$tmp/lab-pg7.conf"
expect_out "program: --dry-run says the name is derived" "derived from FLASHPRO_SERIAL" pg7 --dry-run
printf 'FPEXPRESS=%s/pg/FPExpress\nOCD_PORT=1\nFLASHPRO_SERIAL=EFP6A1\n' "$tmp" > "$tmp/lab-pg8.conf"
fpereset; env FLASHPRO_SYSFS="$tmp/usb-efp6" "$PY" "$HW/program.py" "$STP" --workdir "$PGW" --lab "$tmp/lab-pg8.conf" --yes >/dev/null 2>&1
{ [ "$(fpescripts)" = 3 ] && fpelog_has "-programmer {FAKEPRG01}" && ! fpelog_has "S2EFP6A1"; } \
  && pass "program: an embedded FlashPro6 gets no prefix: FlashPro Express finds its name" || fail "program: an embedded FlashPro6 gets no prefix"
printf 'FPEXPRESS=%s/pg/FPExpress\nOCD_PORT=1\nFLASHPRO_SERIAL=X1\nFLASHPRO_TYPE=fp5\n' "$tmp" > "$tmp/lab-pg9.conf"
fpereset; env FLASHPRO_SYSFS="$tmp/no-sysfs" FAKE_FPE_PROGRAMMERS=S2X1 "$PY" "$HW/program.py" "$STP" --workdir "$PGW" --lab "$tmp/lab-pg9.conf" --yes >/dev/null 2>&1
fpelog_has "-programmer {S2X1}" && pass "program: FLASHPRO_TYPE=fp5 gives the model without the USB descriptors" || fail "program: FLASHPRO_TYPE=fp5 gives the model without the USB descriptors"
printf 'FPEXPRESS=%s/pg/FPExpress\nOCD_PORT=1\nFLASHPRO_SERIAL=S2X1\nFLASHPRO_TYPE=fp5\n' "$tmp" > "$tmp/lab-pg10.conf"
fpereset; env FLASHPRO_SYSFS="$tmp/no-sysfs" FAKE_FPE_PROGRAMMERS=S2X1 "$PY" "$HW/program.py" "$STP" --workdir "$PGW" --lab "$tmp/lab-pg10.conf" --yes >/dev/null 2>&1
{ fpelog_has "-programmer {S2X1}" && ! fpelog_has "S2S2X1"; } && pass "program: a serial that has the prefix already is not prefixed twice" || fail "program: a serial that has the prefix already is not prefixed twice"
# run_selected_actions without -name runs the action on every connected programmer: with two connected, only the named one may
fpereset; PGOUT="$(env FAKE_FPE_PROGRAMMERS=PRGA,PRGB "${pgcmd[@]}" --programmer PRGB --yes 2>&1)"
case "$PGOUT" in *"programmer 'PRGA' : device"*) fail "program: with two programmers connected the action runs on the other one too" ;; *) pass "program: with two programmers connected the action runs on the named one only" ;; esac
case "$PGOUT" in *"programmer 'PRGB' : device"*"Executing action PROGRAM"*) pass "program: ... and it does run on the named one" ;; *) fail "program: ... and it does run on the named one (got: $PGOUT)" ;; esac
fpelog_has "run_selected_actions -name {PRGB}" && pass "program: the script names the programmer in run_selected_actions" || fail "program: the script names the programmer in run_selected_actions"
# bootmode names the programmer in the project of fpgenprog, with the element FlashPro Express writes
printf 'FPGENPROG=%s/bm/fpgenprog\nFPEXPRESS=%s/pg/FPExpress\nOCD_PORT=1\n' "$tmp" "$tmp" > "$tmp/lab-bmx.conf"
BMX="$tmp/lab-bmx.conf"
bmx () { env FAKE_FP_HONOUR=1 ${BMXENV:+"$BMXENV"} "$PY" "$HW/bootmode.py" 1 "$BME" --workdir "$BMW" --yes "$@"; }   # BMXENV: one NAME=value
fpereset; fpreset
expect_rc  "bootmode: one programmer that FlashPro Express sees is taken and programs" 0 bmx --lab "$BMX"
expect_out "bootmode: ... and fpgenprog used it" "FlashPro used: FAKEPRG01" bmx --lab "$BMX"
fpereset; fpreset; bmx --lab "$BMX" >/dev/null 2>&1
grep -q 'type="FlashPro6Lite" revision="UndefRev" connection="usb1.1"><name>FAKEPRG01</name>' "$BMW/bootmode1/fpgenprogProject/proj_fp/proj_fp.pro" \
  && pass "bootmode: the project names the programmer with the element of FlashPro Express (type and connection)" || fail "bootmode: the project names the programmer with the element of FlashPro Express"
BMXENV=FAKE_FPE_PROGRAMMERS=PRGA,PRGB expect_rc "bootmode: several programmers and none named exits 2" 2 bmx --lab "$BMX"
BMXENV=FAKE_FPE_PROGRAMMERS=PRGA,PRGB expect_out "bootmode: ... and lists them" "PRGA (Embedded FlashPro6), PRGB" bmx --lab "$BMX"
fpreset; BMXENV=FAKE_FPE_PROGRAMMERS=PRGA,PRGB bmx --lab "$BMX" >/dev/null 2>&1
[ ! -e "$FAKE_FP_LOG" ] && pass "bootmode: ... before fpgenprog runs" || fail "bootmode: ... before fpgenprog runs"
BMXENV=FAKE_FPE_PROGRAMMERS=PRGA,PRGB expect_out "bootmode: with several programmers --flashpro picks one" "FlashPro used: PRGB" bmx --flashpro PRGB --lab "$BMX"
# fpgenprog runs the action on every connected programmer, so with several bootmode programs through FlashPro Express, for one
fpreset; fpereset; BXOUT="$(env FAKE_FPE_PROGRAMMERS=PRGA,PRGB FAKE_FP_GANG=PRGA,PRGB "$PY" "$HW/bootmode.py" 1 "$BME" --workdir "$BMW" --yes --flashpro PRGB --lab "$BMX" 2>&1)"
case "$BXOUT" in *"programmer 'PRGA' : device"*) fail "bootmode: with several programmers the other one is programmed too" ;; *) pass "bootmode: with several programmers only the named one is programmed" ;; esac
case "$BXOUT" in *"programmer 'PRGB' : device 'MPF500T' : Executing action PROGRAM PASSED"*) pass "bootmode: ... and it is programmed through FlashPro Express" ;; *) fail "bootmode: ... and it is programmed through FlashPro Express (got: $BXOUT)" ;; esac
programmed && fail "bootmode: with several programmers fpgenprog does not do the PROGRAM" || pass "bootmode: with several programmers fpgenprog does not do the PROGRAM"
fpelog_has "run_selected_actions -name {PRGB}" && pass "bootmode: ... with the programmer named in run_selected_actions" || fail "bootmode: ... with the programmer named in run_selected_actions"
# with one connected programmer fpgenprog programs; if its output shows it ran on more than that one, nothing is programmed
fpreset; fpereset
expect_rc "bootmode: fpgenprog that runs the check on two programmers is refused" 1 env FAKE_FPE_PROGRAMMERS=PRGA FAKE_FP_GANG=PRGA,PRGB "$PY" "$HW/bootmode.py" 1 "$BME" --workdir "$BMW" --yes --flashpro PRGA --lab "$BMX"
fpreset; env FAKE_FPE_PROGRAMMERS=PRGA FAKE_FP_GANG=PRGA,PRGB "$PY" "$HW/bootmode.py" 1 "$BME" --workdir "$BMW" --yes --flashpro PRGA --lab "$BMX" >/dev/null 2>&1
programmed && fail "bootmode: ... and nothing is programmed" || pass "bootmode: ... and nothing is programmed"
expect_out "bootmode: ... and it says on which programmers it ran" "ran the action on PRGA, PRGB instead of only on PRGA" env FAKE_FPE_PROGRAMMERS=PRGA FAKE_FP_GANG=PRGA,PRGB "$PY" "$HW/bootmode.py" 1 "$BME" --workdir "$BMW" --yes --flashpro PRGA --lab "$BMX"
BMXENV=FAKE_FPE_PROGRAMMERS=PRGA,PRGB expect_rc "bootmode: a programmer that FlashPro Express does not see exits 2" 2 bmx --flashpro NOPE --lab "$BMX"
BMXENV=FAKE_FPE_PROGRAMMERS=PRGA,PRGB expect_out "bootmode: ... and names it and those it sees" "'NOPE' is not among the programmers FlashPro Express sees: PRGA" bmx --flashpro NOPE --lab "$BMX"
printf 'FLASHPRO_ID=PRGA\n' | cat "$BMX" - > "$tmp/lab-bmx2.conf"
BMXENV=FAKE_FPE_PROGRAMMERS=PRGA,PRGB expect_out "bootmode: FLASHPRO_ID of lab.conf picks one of several" "FlashPro used: PRGA" bmx --lab "$tmp/lab-bmx2.conf"
fpereset; bootmode 1 --prepare-only --lab "$BMX" >/dev/null 2>&1; bootmode 1 --dry-run --lab "$BMX" >/dev/null 2>&1
[ ! -e "$FAKE_FPE_LOG" ] && pass "bootmode: --prepare-only and --dry-run do not run FlashPro Express" || fail "bootmode: --prepare-only and --dry-run do not run FlashPro Express"
expect_out "bootmode: without FlashPro Express it says so and goes on as before" "FlashPro Express not found" bootmode 1 --yes --lab "$LB"
fpereset; "${pgcmd[@]}" --yes --action ERASE >/dev/null 2>&1
fpelog_has "-action {ERASE}" && pass "program: --action names the action" || fail "program: --action names the action"
# more than one, or none
fpereset
expect_rc  "program: two devices exit 2" 2 env FAKE_FPE_DEVICES=MPF500T,MPFS250T "${pgcmd[@]}" --yes
expect_out "program: two devices are listed and --device is named" "more than one device found: MPF500T, MPFS250T; name one with --device" env FAKE_FPE_DEVICES=MPF500T,MPFS250T "${pgcmd[@]}" --yes
fpereset; FAKE_FPE_DEVICES=MPF500T,MPFS250T "${pgcmd[@]}" --yes >/dev/null 2>&1
fpelog_has "set_programming_action" && fail "program: two devices program nothing" || pass "program: two devices program nothing"
expect_rc  "program: --device picks one of two" 0 env FAKE_FPE_DEVICES=MPF500T,MPFS250T "${pgcmd[@]}" --yes --device MPFS250T
expect_rc  "program: two programmers exit 2" 2 env FAKE_FPE_PROGRAMMERS=PRG1,PRG2 "${pgcmd[@]}" --yes
expect_out "program: two programmers are listed and --programmer is named" "more than one programmer found: PRG1, PRG2; name one with --programmer" env FAKE_FPE_PROGRAMMERS=PRG1,PRG2 "${pgcmd[@]}" --yes
expect_rc  "program: no programmer found exits 2" 2 env FAKE_FPE_PROGRAMMERS= "${pgcmd[@]}" --yes
expect_out "program: no programmer found shows the last lines of the output" "FlashPro Express printed no programmer" env FAKE_FPE_PROGRAMMERS= "${pgcmd[@]}" --yes
expect_rc  "program: no device found exits 2" 2 env FAKE_FPE_DEVICES= "${pgcmd[@]}" --yes
# failures of FlashPro Express
expect_rc  "program: a failing action exits 1" 1 env FAKE_FPE_RC=3 "${pgcmd[@]}" --yes
expect_out "program: a failing action is named, with the status" "FlashPro Express ended with status 3" env FAKE_FPE_RC=3 "${pgcmd[@]}" --yes
# a crash: FlashPro Express ended with a segmentation fault on a board. Run on a pipe, a program loses what it printed
# last (it buffers in blocks); on a pseudo-terminal the lines are there.
expect_rc  "program: a crashing FlashPro Express exits 1" 1 env FAKE_FPE_CRASH=1 "${pgcmd[@]}" --yes
expect_out "program: a crash is named as the signal" "killed by signal 11 (SIGSEGV)" env FAKE_FPE_CRASH=1 "${pgcmd[@]}" --yes
expect_out "program: what FlashPro Express printed before the crash is shown" "fake FPExpress: PROGRAM MPF500T on FAKEPRG01" env FAKE_FPE_CRASH=1 "${pgcmd[@]}" --yes
FAKE_FPE_CRASH=1 "${pgcmd[@]}" --yes >/dev/null 2>&1
grep -q "fake FPExpress: PROGRAM MPF500T on FAKEPRG01" "$PGW/program.log" && grep -q "killed by signal 11 (SIGSEGV)" "$PGW/program.log" \
  && pass "program: program.log has the last lines before the crash and the signal" || fail "program: program.log has the last lines before the crash and the signal"
grep -q "s)$" "$PGW/program.log" && pass "program: program.log has the duration of each run" || fail "program: program.log has the duration of each run"
expect_out "program: a shell that reports a signal as 128+N (the snap wrapper: 139) is read as the signal" "killed by signal 11 (SIGSEGV), as a shell reports it" env FAKE_FPE_RC=139 "${pgcmd[@]}" --yes
expect_out "program: status 1 is a script in which a command failed" "the Tcl script failed (a command printed an Error: line)" env FAKE_FPE_RC=1 "${pgcmd[@]}" --yes
# the Tcl command exit crashed FlashPro Express 2024.2.0.13 with a segmentation fault, after a failed and after a successful
# action: the script ends with run_selected_actions, and FlashPro Express ends it with its own message and status
fpereset; "${pgcmd[@]}" --yes >/dev/null 2>&1
{ [ "$(tail -n 1 "$PGW/program.tcl" | cut -d' ' -f1)" = "run_selected_actions" ] && ! grep -q -E '(^|[[:space:]])(exit|catch|puts)([[:space:]]|$)' "$PGW/program.tcl"; } \
  && pass "program: the programming script ends with run_selected_actions and has no exit, catch or puts" || fail "program: the programming script ends with run_selected_actions and has no exit, catch or puts"
# FlashPro Express 2026.1 failed on a scan_chain_prg right after auto_construct_job_project (with a FlashPro5 and a FlashPro6); the
# project is closed and opened again in between, which works with 2026.1 and with 2024.2 (the stand-in fails without it)
tclorder () { local f="$1" prev=0 n c; shift; for c in "$@"; do n="$(grep -n -m1 "^$c" "$f" | cut -d: -f1)"; [ -n "$n" ] && [ "$n" -gt "$prev" ] || return 1; prev=$n; done; }
fpereset; "${pgcmd[@]}" --yes --tck 2 >/dev/null 2>&1
tclorder "$PGW/program.tcl" auto_construct_job_project close_project open_project configure_flashpro6_prg scan_chain_prg enable_device set_programming_file set_programming_action run_selected_actions \
  && pass "program: the programming script closes and opens the project after auto_construct_job_project, before the clock and the scan" || fail "program: the programming script closes and opens the project after auto_construct_job_project, before the clock and the scan"
tclorder "$PGW/detect_device.tcl" auto_construct_job_project close_project open_project configure_flashpro6_prg scan_chain_prg \
  && pass "program: the scan script closes and opens the project after auto_construct_job_project, before the clock and the scan" || fail "program: the scan script closes and opens the project after auto_construct_job_project, before the clock and the scan"
grep -q "^open_project -project {$PGW/job/PolarfireProg/PolarfireProg.pro}\$" "$PGW/program.tcl" \
  && pass "program: it opens the project that auto_construct_job_project made, <workdir>/job/PolarfireProg/PolarfireProg.pro" || fail "program: it opens the project that auto_construct_job_project made"
grep -q -E '^(close_project|open_project)' "$PGW/detect_programmer.tcl" \
  && fail "program: the script that only looks for the programmers does not close or open a project" || pass "program: the script that only looks for the programmers does not close or open a project"
mkdir -p "$tmp/pg/direct/job"
printf '# Microsemi Tcl Script\nset_fpexpress_mode -mode {developer_mode}\nauto_construct_job_project \\\n  -job_project_location {%s} \\\n  -job_name {PolarfireProg} \\\n  -programmer {FAKEPRG01} \\\n  -overwrite 1\nscan_chain_prg -name {FAKEPRG01}\n' "$tmp/pg/direct/job" > "$tmp/pg/direct.tcl"
expect_rc  "program: the stand-in fails a scan right after auto_construct_job_project, as FlashPro Express 2026.1 did" 1 env FAKE_FPE_LOG="$tmp/pg/direct.log" "$tmp/pg/FPExpress" "script:$tmp/pg/direct.tcl"
printf '# Microsemi Tcl Script\nset_fpexpress_mode -mode {developer_mode}\nauto_construct_job_project \\\n  -job_project_location {%s} \\\n  -job_name {PolarfireProg} \\\n  -programmer {FAKEPRG01} \\\n  -overwrite 1\nclose_project\nopen_project -project {%s/PolarfireProg/PolarfireProg.pro}\nscan_chain_prg -name {FAKEPRG01}\n' "$tmp/pg/direct/job" "$tmp/pg/direct/job" > "$tmp/pg/reopen.tcl"
expect_rc  "program: ... and takes it with close_project and open_project in between" 0 env FAKE_FPE_LOG="$tmp/pg/direct.log" "$tmp/pg/FPExpress" "script:$tmp/pg/reopen.tcl"
expect_rc  "program: status 0 without 'The Execute Script command succeeded' exits 1" 1 env FAKE_FPE_NO_OK=1 "${pgcmd[@]}" --yes
expect_out "program: ... and says it is not trusted" "did not print 'The Execute Script command succeeded'" env FAKE_FPE_NO_OK=1 "${pgcmd[@]}" --yes
# a programming file for another device (the guardian file is for MPF300TS_ES, the board has an MPFS250): FlashPro Express
# fails the check of the chain before the action starts, and nothing is written
expect_rc  "program: a file for another device exits 1" 1 env FAKE_FPE_FILE_DEVICE=MPF300TS_ES "${pgcmd[@]}" --yes
expect_out "program: ... and names the device the file is for" "the programming file is for MPF300TS_ES devices and the chain has MPF500T" env FAKE_FPE_FILE_DEVICE=MPF300TS_ES "${pgcmd[@]}" --yes
expect_out "program: ... and says nothing was written, as the action did not start" "the action did not start, so nothing was written" env FAKE_FPE_FILE_DEVICE=MPF300TS_ES "${pgcmd[@]}" --yes
expect_out "program: a failing PROGRAM that started says the FPGA may be half programmed" "the FPGA may be half programmed" env FAKE_FPE_RC=1 "${pgcmd[@]}" --yes
expect_rc  "program: a programmer that FlashPro Express does not know exits 1" 1 "${pgcmd[@]}" --yes --programmer NOSUCH --device MPF500T
expect_rc  "program: ... and exits 2 if the chain cannot be scanned for the device" 2 "${pgcmd[@]}" --yes --programmer NOSUCH
expect_rc  "program: no output exits 1" 1 env FAKE_FPE_SILENT=1 "${pgcmd[@]}" --yes
expect_out "program: no output is named" "printed nothing" env FAKE_FPE_SILENT=1 "${pgcmd[@]}" --yes
# --dry-run and the refusal
fpereset
expect_rc  "program: --dry-run exits 0" 0 "${pgcmd[@]}" --dry-run </dev/null
expect_out "program: --dry-run prints the programming script with the file" "set_programming_file -name {<device>} -file {$STP}" "${pgcmd[@]}" --dry-run
expect_out "program: --dry-run prints the detections too" "detect_device.tcl" "${pgcmd[@]}" --dry-run
[ ! -e "$FAKE_FPE_LOG" ] && [ ! -e "$PGW" ] && pass "program: --dry-run runs nothing and writes nothing" || fail "program: --dry-run runs nothing and writes nothing"
# the file types that were used on a board (.stp, .ppd) go through silently, another one with a warning
: > "$tmp/pg/design.ppd"; : > "$tmp/pg/design.dat"
case "$("$PY" "$HW/program.py" "$tmp/pg/design.ppd" --workdir "$PGW" --lab "$PL" --dry-run 2>&1)" in *neither*) fail "program: a .ppd file is taken without a warning" ;; *) pass "program: a .ppd file is taken without a warning" ;; esac
case "$("${pgcmd[@]}" --dry-run 2>&1)" in *neither*) fail "program: a .stp file is taken without a warning" ;; *) pass "program: a .stp file is taken without a warning" ;; esac
expect_out "program: another file type is tried with a warning" "is neither a .stp nor a .ppd file" "$PY" "$HW/program.py" "$tmp/pg/design.dat" --workdir "$PGW" --lab "$PL" --dry-run
expect_out "program: a .ppd file is put into the script as the file" "set_programming_file -name {<device>} -file {$tmp/pg/design.ppd}" "$PY" "$HW/program.py" "$tmp/pg/design.ppd" --workdir "$PGW" --lab "$PL" --dry-run
expect_out "program: --dry-run with the names given prints the programming script" "set_programming_action -name {D1} -action {VERIFY}" "${pgcmd[@]}" --dry-run --programmer P1 --device D1 --action VERIFY
case "$("${pgcmd[@]}" --dry-run --programmer P1 --device D1 2>&1)" in *detect_*) fail "program: --dry-run with the names given prints no detection" ;; *) pass "program: --dry-run with the names given prints no detection" ;; esac
expect_rc  "program: without --yes and without a terminal exits 2" 2 "${pgcmd[@]}" </dev/null
expect_out "program: the refusal says nothing was done" "nothing was done" "${pgcmd[@]}" </dev/null
[ ! -e "$FAKE_FPE_LOG" ] && [ ! -e "$PGW" ] && pass "program: the refusal runs nothing and writes nothing" || fail "program: the refusal runs nothing and writes nothing"
# the prompt, on a pseudo terminal
ptyprog () { PTY_SCRIPT=program.py ptyrun "$@"; }
fpereset
expect_rc  "program: the answer 'no' exits 1" 1 ptyprog no "$STP" --workdir "$PGW" --lab "$PL"
fpelog_has "set_programming_action" && fail "program: the answer 'no' does not program" || pass "program: the answer 'no' does not program"
fpereset
expect_rc  "program: the answer 'yes' programs and exits 0" 0 ptyprog yes "$STP" --workdir "$PGW" --lab "$PL"
fpelog_has "set_programming_action" && pass "program: the answer 'yes' programmed" || fail "program: the answer 'yes' programmed"
# --scan: the programmers and the devices of their chains, read only
pgbase=("$PY" "$HW/program.py" --workdir "$PGW" --lab "$PL")   # no FILE
fpereset
expect_rc  "program: --scan exits 0 and needs neither --yes nor a terminal" 0 "${pgbase[@]}" --scan </dev/null
expect_out "program: --scan lists the programmer with its model" "programmer FAKEPRG01: Embedded FlashPro6" "${pgbase[@]}" --scan
expect_out "program: --scan lists the device of the chain with IDCODE and manufacturer" "device 1: MPF500T, IDCODE F81A1CF, Microsemi" "${pgbase[@]}" --scan
fpereset; "${pgbase[@]}" --scan >/dev/null 2>&1
{ [ "$(fpescripts)" = 2 ] && ! fpelog_has "set_programming_action" && ! fpelog_has "run_selected_actions"; } \
  && pass "program: --scan runs the detection and one scan and no action" || fail "program: --scan runs the detection and one scan and no action (got $(fpescripts) scripts)"
fpereset; env FAKE_FPE_PROGRAMMERS=PRG1,PRG2 "${pgbase[@]}" --scan > "$tmp/pg/scan2.out" 2>&1
{ [ "$(fpescripts)" = 3 ] && grep -q "programmer PRG1:" "$tmp/pg/scan2.out" && grep -q "programmer PRG2:" "$tmp/pg/scan2.out"; } \
  && pass "program: --scan scans the chain of every programmer it finds" || fail "program: --scan scans the chain of every programmer it finds"
fpereset; env FAKE_FPE_PROGRAMMERS=PRG1,PRG2 "${pgbase[@]}" --scan --programmer PRG2 > "$tmp/pg/scan3.out" 2>&1
{ [ "$(fpescripts)" = 2 ] && grep -q "programmer PRG2:" "$tmp/pg/scan3.out" && ! grep -q "programmer PRG1:" "$tmp/pg/scan3.out"; } \
  && pass "program: --scan --programmer scans only that one" || fail "program: --scan --programmer scans only that one"
expect_out "program: --scan lists the part of an MPFS250 as the scan printed it" "device 1: MPFS250(T_ES|TS_ES), IDCODE F81A1CF, Microsemi" env 'FAKE_FPE_DEVICES=MPFS250(T_ES|TS_ES)' "${pgbase[@]}" --scan
expect_rc  "program: --scan with an empty chain exits 1" 1 env FAKE_FPE_DEVICES= "${pgbase[@]}" --scan
expect_out "program: ... and says no device was found" "no device found" env FAKE_FPE_DEVICES= "${pgbase[@]}" --scan
expect_rc  "program: --scan without a programmer exits 2" 2 env FAKE_FPE_PROGRAMMERS= "${pgbase[@]}" --scan
expect_rc  "program: --scan of a programmer that is not there exits 2" 2 "${pgbase[@]}" --scan --programmer NOSUCH
expect_rc  "program: --scan with a FILE exits 2" 2 "${pgcmd[@]}" --scan
expect_rc  "program: no FILE and no --scan exits 2" 2 "${pgbase[@]}" </dev/null
fpereset
expect_rc  "program: --scan --dry-run exits 0" 0 "${pgbase[@]}" --scan --dry-run
expect_out "program: --scan --dry-run prints the scan script" "scan_<programmer>.tcl" "${pgbase[@]}" --scan --dry-run
[ ! -e "$FAKE_FPE_LOG" ] && [ ! -e "$PGW" ] && pass "program: --scan --dry-run runs nothing and writes nothing" || fail "program: --scan --dry-run runs nothing and writes nothing"
# actions that only read: no prompt, no --yes. Every action needs a FILE: FlashPro Express stops without a loaded programming
# file ("A programming file must be loaded before running the command 'set_programming_action'", seen with DEVICE_INFO)
fpereset
expect_rc  "program: DEVICE_INFO needs no --yes and no terminal" 0 "${pgcmd[@]}" --action DEVICE_INFO </dev/null
{ fpelog_has "set_programming_file -name {MPF500T}" && fpelog_has "set_programming_action -name {MPF500T} -action {DEVICE_INFO}"; } \
  && pass "program: DEVICE_INFO loads the file and sets the action" || fail "program: DEVICE_INFO loads the file and sets the action"
expect_rc  "program: DEVICE_INFO without a FILE exits 2" 2 "${pgbase[@]}" --action DEVICE_INFO </dev/null
expect_rc  "program: READ_IDCODE without a FILE exits 2" 2 "${pgbase[@]}" --action READ_IDCODE </dev/null
expect_rc  "program: READ_IDCODE with a FILE needs no --yes either" 0 "${pgcmd[@]}" --action READ_IDCODE </dev/null
expect_rc  "program: VERIFY needs no --yes and no terminal" 0 "${pgcmd[@]}" --action VERIFY </dev/null
expect_rc  "program: VERIFY without a FILE exits 2" 2 "${pgbase[@]}" --action VERIFY </dev/null
expect_rc  "program: ERASE still needs --yes or a terminal" 2 "${pgcmd[@]}" --action ERASE </dev/null
expect_rc  "program: PROGRAM without a FILE exits 2" 2 "${pgbase[@]}" --yes </dev/null
expect_out "program: a failing action that only reads says nothing was written" "it only reads, so nothing was written" env FAKE_FPE_RC=3 "${pgcmd[@]}" --action DEVICE_INFO </dev/null
expect_out "program: a failing PROGRAM still says the FPGA may be half programmed" "the FPGA may be half programmed" env FAKE_FPE_RC=3 "${pgcmd[@]}" --yes
# --tck and OCD_TCK_MHZ: the frequency goes into the scripts that scan and program, in Hz (FlashPro Express wants Hz in whole
# MHz, 1 to 20 MHz for a FlashPro6: on a board it rejected 10 with "expecting 1000000, 2000000, ... 20000000"), by the
# model of the programmer
fpereset; "${pgcmd[@]}" --yes >/dev/null 2>&1
fpelog_has "configure_flashpro" && fail "program: without a frequency no configure command is put into a script" || pass "program: without a frequency no configure command is put into a script"
fpereset; "${pgcmd[@]}" --yes --tck 2 >/dev/null 2>&1
{ [ "$(fpescripts)" = 3 ] && [ "$(fpelog | grep -c 'configure_flashpro6_prg -force_freq {ON} -freq {2000000}')" = 2 ]; } \
  && pass "program: --tck 2 is 2000000 Hz in the scan and in the programming script (FlashPro6)" || fail "program: --tck 2 is 2000000 Hz in the scan and in the programming script (got $(fpelog | grep -c configure_flashpro6_prg))"
fpereset; "${pgcmd[@]}" --yes --programmer FAKEPRG01 --device MPF500T --tck 10 >/dev/null 2>&1
{ [ "$(fpescripts)" = 2 ] && fpelog_has "configure_flashpro6_prg -force_freq {ON} -freq {10000000}"; } \
  && pass "program: --tck 10 is 10000000 Hz, and the programmers are looked for even when one is named (the model decides the command)" || fail "program: --tck 10 is 10000000 Hz (got $(fpescripts) scripts)"
expect_rc  "program: a FlashPro6 takes up to 20 MHz" 0 "${pgcmd[@]}" --yes --tck 20
expect_rc  "program: a FlashPro6 does not take 21 MHz" 2 "${pgcmd[@]}" --yes --tck 21
expect_out "program: ... and says 1 to 20 MHz" "a FlashPro6 takes 1 to 20 MHz" "${pgcmd[@]}" --yes --tck 21
expect_rc  "program: a frequency with a fraction exits 2 (whole MHz)" 2 "${pgcmd[@]}" --yes --tck 2.5
fpereset; FAKE_FPE_MODEL=FlashPro5 "${pgcmd[@]}" --yes --tck 3 >/dev/null 2>&1
fpelog_has "configure_flashpro5_prg -force_freq {ON} -freq {3000000}" && pass "program: a FlashPro5 gets configure_flashpro5_prg" || fail "program: a FlashPro5 gets configure_flashpro5_prg"
expect_rc  "program: a FlashPro5 is not held to the 20 MHz of the FlashPro6 (its steps are not known: FlashPro Express decides)" 0 env FAKE_FPE_MODEL=FlashPro5 "${pgcmd[@]}" --yes --tck 21
expect_rc  "program: a model without a known command exits 2" 2 env 'FAKE_FPE_MODEL=FlashPro Lite' "${pgcmd[@]}" --yes --tck 3
expect_out "program: ... and says so" "no command to set the TCK frequency is known" env 'FAKE_FPE_MODEL=FlashPro Lite' "${pgcmd[@]}" --yes --tck 3
expect_rc  "program: a named programmer that is not found exits 2 with a frequency" 2 "${pgcmd[@]}" --yes --programmer NOSUCH --device MPF500T --tck 2
printf 'FPEXPRESS=%s/pg/FPExpress\nOCD_PORT=1\nTCK_MHZ=3\n' "$tmp" > "$tmp/lab-pg6.conf"
fpereset; "$PY" "$HW/program.py" "$STP" --workdir "$PGW" --lab "$tmp/lab-pg6.conf" --yes >/dev/null 2>&1
fpelog_has "-freq {3000000}" && pass "program: TCK_MHZ of lab.conf sets the frequency" || fail "program: TCK_MHZ of lab.conf sets the frequency"
fpereset; "$PY" "$HW/program.py" "$STP" --workdir "$PGW" --lab "$tmp/lab-pg6.conf" --yes --tck 1 >/dev/null 2>&1
{ fpelog_has "-freq {1000000}" && ! fpelog_has "-freq {3000000}"; } && pass "program: --tck wins over TCK_MHZ" || fail "program: --tck wins over TCK_MHZ"
# OCD_TCK_MHZ is the clock of OpenOCD (its limit is not the one of FlashPro Express): programming does not take it
printf 'FPEXPRESS=%s/pg/FPExpress\nOCD_PORT=1\nOCD_TCK_MHZ=3\n' "$tmp" > "$tmp/lab-pg6b.conf"
fpereset; "$PY" "$HW/program.py" "$STP" --workdir "$PGW" --lab "$tmp/lab-pg6b.conf" --yes >/dev/null 2>&1
{ ! fpelog_has "-freq" && ! fpelog_has "configure_flashpro"; } && pass "program: OCD_TCK_MHZ of lab.conf (the clock of OpenOCD) does not set the frequency" || fail "program: OCD_TCK_MHZ of lab.conf (the clock of OpenOCD) does not set the frequency"
expect_rc  "program: --tck that is not a number exits 2" 2 "${pgcmd[@]}" --yes --tck abc
expect_rc  "program: --tck 0 exits 2" 2 "${pgcmd[@]}" --yes --tck 0
expect_rc  "program: a negative --tck exits 2" 2 "${pgcmd[@]}" --yes --tck=-1
expect_out "program: --dry-run with a frequency leaves the command of the family open" "configure_flashpro<5 or 6>_prg -force_freq {ON} -freq {2000000}" "${pgcmd[@]}" --dry-run --tck 2
fpereset; "${pgbase[@]}" --scan --tck 2 >/dev/null 2>&1
fpelog_has "configure_flashpro6_prg -force_freq {ON} -freq {2000000}" && pass "program: --scan takes --tck too" || fail "program: --scan takes --tck too"
# a command of the scan script fails and FlashPro Express says why: the errors are shown, not "name it with --device"
expect_rc  "program: a failing scan exits 2" 2 env FAKE_FPE_SCAN_ERROR=1 "${pgcmd[@]}" --yes
expect_out "program: ... and shows the errors FlashPro Express printed" "reported errors" env FAKE_FPE_SCAN_ERROR=1 "${pgcmd[@]}" --yes
case "$(FAKE_FPE_SCAN_ERROR=1 "${pgcmd[@]}" --yes 2>&1)" in *"name it with"*) fail "program: ... and does not say to name the device" ;; *) pass "program: ... and does not say to name the device" ;; esac
# set-up errors
expect_rc  "program: a file that does not exist exits 2" 2 "$PY" "$HW/program.py" "$tmp/pg/none.stp" --workdir "$PGW" --lab "$PL" --yes
mkdir -p "$tmp/pg/odd{dir}"; : > "$tmp/pg/odd{dir}/d.stp"
fpereset
expect_rc  "program: a path with a brace exits 2" 2 "$PY" "$HW/program.py" "$tmp/pg/odd{dir}/d.stp" --workdir "$PGW" --lab "$PL" --yes
[ ! -e "$FAKE_FPE_LOG" ] && pass "program: a path with a brace is found before anything runs" || fail "program: a path with a brace is found before anything runs"
expect_rc  "program: a device name with a space exits 2" 2 "${pgcmd[@]}" --yes --device 'a b'
# the part of an MPFS250 is printed as MPFS250(T_ES|TS_ES): the Tcl script gets the name as the scan printed it (splitting it
# into MPFS250T_ES and MPFS250TS_ES was tried and taken out again: it did not work as hoped on a board)
fpereset
expect_rc  "program: an MPFS250(T_ES|TS_ES) device is detected and programmed" 0 env 'FAKE_FPE_DEVICES=MPFS250(T_ES|TS_ES)' "${pgcmd[@]}" --yes
{ fpelog_has "enable_device -name {MPFS250(T_ES|TS_ES)} -enable 1" && fpelog_has "set_programming_file -name {MPFS250(T_ES|TS_ES)}"; } \
  && pass "program: the device name goes into the script as the scan printed it, with parentheses and bar" || fail "program: the device name goes into the script as the scan printed it"
expect_rc  "program: --device takes the name as the scan prints it" 0 env 'FAKE_FPE_DEVICES=MPFS250(T_ES|TS_ES)' "${pgcmd[@]}" --yes --device 'MPFS250(T_ES|TS_ES)'
expect_rc  "program: a detected name with a brace exits 2" 2 env 'FAKE_FPE_DEVICES=MPF{1}' "${pgcmd[@]}" --yes
printf 'FPEXPRESS=%s/pg/none\nOCD_PORT=1\n' "$tmp" > "$tmp/lab-pg3.conf"
expect_rc  "program: a missing FPEXPRESS exits 2" 2 "$PY" "$HW/program.py" "$STP" --workdir "$PGW" --lab "$tmp/lab-pg3.conf" --yes
expect_out "program: a missing FPEXPRESS is named" "FPEXPRESS '$tmp/pg/none'" "$PY" "$HW/program.py" "$STP" --workdir "$PGW" --lab "$tmp/lab-pg3.conf" --yes
printf 'FPGENPROG=%s/pg/fpgenprog\nFPEXPRESS=\nOCD_PORT=1\n' "$tmp" > "$tmp/lab-pg4.conf"
expect_out "program: an empty FPEXPRESS is the FPExpress next to FPGENPROG" "FPExpress: $tmp/pg/FPExpress" "$PY" "$HW/program.py" "$STP" --workdir "$PGW" --lab "$tmp/lab-pg4.conf" --dry-run
fpereset
printf 'FPEXPRESS=%s/pg/FPExpress\nOCD_PORT=%s\n' "$tmp" "$(cat "$tmp/hello.port")" > "$tmp/lab-pg5.conf"
expect_rc  "program: a running OpenOCD exits 2" 2 "$PY" "$HW/program.py" "$STP" --workdir "$PGW" --lab "$tmp/lab-pg5.conf" --yes
expect_out "program: a running OpenOCD is named" "OpenOCD is running" "$PY" "$HW/program.py" "$STP" --workdir "$PGW" --lab "$tmp/lab-pg5.conf" --yes
[ ! -e "$FAKE_FPE_LOG" ] && pass "program: a running OpenOCD stops it before anything runs" || fail "program: a running OpenOCD stops it before anything runs"
expect_rc  "program: --dry-run does not mind a running OpenOCD" 0 "$PY" "$HW/program.py" "$STP" --workdir "$PGW" --lab "$tmp/lab-pg5.conf" --dry-run
fpereset
expect_rc  "program: --scan stops for a running OpenOCD too (the FlashPro is shared)" 2 "$PY" "$HW/program.py" --scan --workdir "$PGW" --lab "$tmp/lab-pg5.conf"
[ ! -e "$FAKE_FPE_LOG" ] && pass "program: --scan with a running OpenOCD runs nothing" || fail "program: --scan with a running OpenOCD runs nothing"

echo "summary: $fails failure(s)"
[ $fails -eq 0 ]
