#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Tests for the scripts of hw/ and ./x hw without a board: a stand-in for the OpenOCD
# telnet port (fake_ocd.py), files in place of the serial ports, a stand-in for
# SoftConsole, and the pinned RISC-V compiler for the images and probes. Every
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
mkdir -p "$tmp/uart" "$tmp/sc"

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
  printf 'SOFT_CONSOLE=%s\nOCD_PORT=%s\nUART_PATTERN=%s\nUART_COUNT=4\n' "$tmp/sc" "$(cat "$tmp/$name.port")" "$tmp/uart/$name/mmuart{n}.log" > "$tmp/lab-$name.conf"
}

run_image () { "$PY" "$HW/run_image.py" "$@"; }

# --- run_image.py -----------------------------------------------------------------
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
printf 'SOFT_CONSOLE=%s\nOCD_PORT=1\nUART_PATTERN=%s\nUART_COUNT=4\n' "$tmp/sc" "$tmp/uart/mon/mmuart{n}.log" > "$tmp/lab-mon.conf"
monitor () { "$PY" "$HW/monitor.py" "$@"; }
expect_rc  "monitor: shows the ports and exits 0 without --expect" 0 monitor --secs 0.3 --lab "$tmp/lab-mon.conf"
expect_out "monitor: names the port that printed" "MMUART1:" monitor --secs 0.3 --lab "$tmp/lab-mon.conf"
expect_rc  "monitor: --expect that matches exits 0" 0 monitor --secs 0.3 --lab "$tmp/lab-mon.conf" --expect 'hello from MMUART[0-9]'
expect_rc  "monitor: --expect that does not match exits 1" 1 monitor --secs 0.3 --lab "$tmp/lab-mon.conf" --expect 'goodbye'
expect_rc  "monitor: --port selects one port (nothing on port 0: no match)" 1 monitor --secs 0.3 --lab "$tmp/lab-mon.conf" --port 0 --expect 'hello'
expect_rc  "monitor: --port with the port that printed matches" 0 monitor --secs 0.3 --lab "$tmp/lab-mon.conf" --port 1 --expect 'hello'
expect_rc  "monitor: a port outside the range exits 2" 2 monitor --secs 0.3 --lab "$tmp/lab-mon.conf" --port 9
expect_rc  "monitor: a serial port that does not exist exits 2" 2 monitor --secs 0.3 --lab "$tmp/lab-noport.conf"

# --- start_openocd.sh ---------------------------------------------------------------
mkdir -p "$tmp/sc/openocd/bin"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/openocd.args"\necho "$LD_LIBRARY_PATH" > "%s/openocd.ld"\n' "$tmp" "$tmp" > "$tmp/sc/openocd/bin/openocd"
chmod +x "$tmp/sc/openocd/bin/openocd"
expect_rc  "start_openocd: starts the SoftConsole OpenOCD of lab.conf" 0 env LAB_CONF="$L" sh "$HW/start_openocd.sh" -c "extra"
grep -qx -- "$tmp/sc/openocd/share/openocd/scripts" "$tmp/openocd.args" && grep -qx 'board/microsemi-riscv.cfg' "$tmp/openocd.args" \
  && grep -qx 'set DEVICE MPFS' "$tmp/openocd.args" && grep -qx 'extra' "$tmp/openocd.args" \
  && pass "start_openocd: passes the script path, the board file, the device and further arguments" \
  || fail "start_openocd: passes the script path, the board file, the device and further arguments"
grep -qx "$tmp/sc/openocd/bin" "$tmp/openocd.ld" && pass "start_openocd: sets LD_LIBRARY_PATH to the OpenOCD bin" || fail "start_openocd: sets LD_LIBRARY_PATH to the OpenOCD bin"
printf 'SOFT_CONSOLE=%s\n' "$tmp/nosoftconsole" > "$tmp/lab-nosc.conf"
expect_rc  "start_openocd: a missing SoftConsole exits 2" 2 env LAB_CONF="$tmp/lab-nosc.conf" sh "$HW/start_openocd.sh"
expect_out "start_openocd: names the path it tried" "$tmp/nosoftconsole/openocd/bin/openocd" env LAB_CONF="$tmp/lab-nosc.conf" sh "$HW/start_openocd.sh"
expect_rc  "start_openocd: SOFT_CONSOLE in the environment overrides lab.conf" 0 env LAB_CONF="$tmp/lab-nosc.conf" SOFT_CONSOLE="$tmp/sc" sh "$HW/start_openocd.sh"
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
# A stand-in java records its arguments and the PATH it got, prints what STANDIN_OUT says (default: a line)
# and ends with STANDIN_RC (default 0). The stand-in jar is an empty file. The real jar was not run.
mkdir -p "$tmp/bm/sc/extras/mpfs" "$tmp/bm/bin" "$tmp/bm/libero"
: > "$tmp/bm/sc/extras/mpfs/mpfsBootmodeProgrammer.jar"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/bm/java.args"\necho "$PATH" > "%s/bm/java.path"\necho "$SC_INSTALL_DIR" > "%s/bm/java.sc"\necho "$FPGENPROG" > "%s/bm/java.fp"\n[ "${STANDIN_SILENT:-}" = 1 ] || echo "standin: programming"\nexit "${STANDIN_RC:-0}"\n' "$tmp" "$tmp" "$tmp" "$tmp" > "$tmp/bm/bin/java"
printf '#!/bin/sh\nexit 0\n' > "$tmp/bm/libero/fpgenprog"
chmod +x "$tmp/bm/bin/java" "$tmp/bm/libero/fpgenprog"
printf 'SOFT_CONSOLE=%s/bm/sc\nJAVA=%s/bm/bin/java\nFPGENPROG=%s/bm/libero/fpgenprog\nOCD_PORT=1\n' "$tmp" "$tmp" "$tmp" > "$tmp/lab-bm.conf"
LB="$tmp/lab-bm.conf"
BME="$tmp/bm/app.elf"; BMW="$tmp/bm/work"   # the boot program and the working directory of the programmer
printf 'ELF stand-in\n' > "$BME"
bootmode () {  # the boot mode, then the ELF and the working directory, then the rest
  case "${1:-}" in -*|"") "$PY" "$HW/bootmode.py" "$@" ;; *) local n="$1"; shift; "$PY" "$HW/bootmode.py" "$n" "$BME" --workdir "$BMW" "$@" ;; esac
}
rm -f "$tmp/bm/java.args"
expect_rc  "bootmode: --yes runs the jar and exits 0" 0 bootmode 2 --yes --lab "$LB"
args="$(tr '\n' ' ' < "$tmp/bm/java.args" 2>/dev/null)"
[ "$args" = "-jar $tmp/bm/sc/extras/mpfs/mpfsBootmodeProgrammer.jar --workdir $BMW --bootmode 2 --die MPFS250T_ES --package FCVG484 app.elf " ] \
  && pass "bootmode: passes -jar, the jar below SOFT_CONSOLE, --workdir, --bootmode, --die, --package and the ELF by name (the defaults)" \
  || fail "bootmode: passes -jar, the jar below SOFT_CONSOLE, --workdir, --bootmode, --die, --package and the ELF by name (got: $args)"
[ -f "$BMW/app.elf" ] && cmp -s "$BME" "$BMW/app.elf" && pass "bootmode: copies the ELF to the working directory" || fail "bootmode: copies the ELF to the working directory"
grep -q "^$tmp/bm/libero:" "$tmp/bm/java.path" && pass "bootmode: puts the directory of fpgenprog on PATH for the jar" || fail "bootmode: puts the directory of fpgenprog on PATH for the jar"
expect_out "bootmode: shows the output of the jar" "standin: programming" bootmode 0 --yes --lab "$LB"
expect_out "bootmode: prints the duration" "the programmer took" bootmode 0 --yes --lab "$LB"
expect_out "bootmode: says what to do next" "Power-cycle the board" bootmode 0 --yes --lab "$LB"
expect_out "bootmode: names the PC to check" "0x2000312E" bootmode 0 --yes --lab "$LB"
# die, package and the jar path from lab.conf
printf 'BOOTMODE_DIE=MPFS250T\nBOOTMODE_PACKAGE=FCG1152\nBOOTMODE_JAR=%s/bm/other.jar\n' "$tmp" | cat "$LB" - > "$tmp/lab-bm2.conf"
: > "$tmp/bm/other.jar"
bootmode 3 --yes --lab "$tmp/lab-bm2.conf" >/dev/null 2>&1
args="$(tr '\n' ' ' < "$tmp/bm/java.args")"
[ "$args" = "-jar $tmp/bm/other.jar --workdir $BMW --bootmode 3 --die MPFS250T --package FCG1152 app.elf " ] \
  && pass "bootmode: die, package and jar come from lab.conf" || fail "bootmode: die, package and jar come from lab.conf (got: $args)"
printf 'SOFT_CONSOLE=%s/bm/nosc\nJAVA=%s/bm/bin/java\nFPGENPROG=%s/bm/libero/fpgenprog\n' "$tmp" "$tmp" "$tmp" > "$tmp/lab-bm-nojar.conf"
# --dry-run
rm -f "$tmp/bm/java.args"
expect_rc  "bootmode: --dry-run exits 0" 0 bootmode 1 --dry-run --lab "$LB"
expect_out "bootmode: --dry-run prints the command" "--bootmode 1 --die MPFS250T_ES --package FCVG484 app.elf" bootmode 1 --dry-run --lab "$LB"
[ ! -e "$tmp/bm/java.args" ] && pass "bootmode: --dry-run does not run java" || fail "bootmode: --dry-run does not run java"
expect_rc  "bootmode: --dry-run with a missing jar still exits 2" 2 bootmode 1 --dry-run --lab "$tmp/lab-bm-nojar.conf"
# refusal without --yes (no terminal here)
expect_rc  "bootmode: without --yes and without a terminal exits 2" 2 bootmode 1 --lab "$LB" </dev/null
expect_out "bootmode: the refusal says nothing was done" "nothing was done" bootmode 1 --lab "$LB" </dev/null
[ ! -e "$tmp/bm/java.args" ] && pass "bootmode: the refusal does not run java" || fail "bootmode: the refusal does not run java"
# the prompt, on a pseudo terminal: "yes" writes, anything else does not
ptyrun () {  # ptyrun <answer> <args...>: bootmode with a terminal on stdin that types <answer>
  local answer="$1"; shift
  "$PY" -I -c 'import os, pty, sys, time
answer, argv = sys.argv[1], sys.argv[2:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(argv[0], argv)
time.sleep(1)
os.write(fd, (answer + "\n").encode())
while True:
    try:
        if not os.read(fd, 4096): break
    except OSError: break
_, st = os.waitpid(pid, 0)
sys.exit(os.waitstatus_to_exitcode(st))' "$answer" "$PY" "$HW/bootmode.py" "$@"
}
rm -f "$tmp/bm/java.args"
expect_rc  "bootmode: the answer 'no' exits 1" 1 ptyrun no 2 "$BME" --workdir "$BMW" --lab "$LB"
[ ! -e "$tmp/bm/java.args" ] && pass "bootmode: the answer 'no' does not run java" || fail "bootmode: the answer 'no' does not run java"
expect_rc  "bootmode: the answer 'yes' runs the jar and exits 0" 0 ptyrun yes 2 "$BME" --workdir "$BMW" --lab "$LB"
[ -e "$tmp/bm/java.args" ] && pass "bootmode: the answer 'yes' ran java" || fail "bootmode: the answer 'yes' ran java"
# failures
expect_rc  "bootmode: boot mode 4 exits 2" 2 bootmode 4 --yes --lab "$LB"
expect_rc  "bootmode: boot mode -1 exits 2" 2 bootmode -1 --yes --lab "$LB"
expect_rc  "bootmode: boot mode 'x' exits 2" 2 bootmode x --yes --lab "$LB"
expect_rc  "bootmode: no boot mode exits 2" 2 bootmode --yes --lab "$LB"
printf 'SOFT_CONSOLE=%s/bm/sc\nJAVA=%s/bm/bin/none\nFPGENPROG=%s/bm/libero/fpgenprog\n' "$tmp" "$tmp" "$tmp" > "$tmp/lab-bm-nojava.conf"
expect_rc  "bootmode: a missing java exits 2" 2 bootmode 0 --yes --lab "$tmp/lab-bm-nojava.conf"
expect_out "bootmode: a missing java says what to do" "install a JRE or set JAVA" bootmode 0 --yes --lab "$tmp/lab-bm-nojava.conf"
expect_rc  "bootmode: a missing jar exits 2" 2 bootmode 0 --yes --lab "$tmp/lab-bm-nojar.conf"
expect_out "bootmode: a missing jar says what to do" "set SOFT_CONSOLE or BOOTMODE_JAR" bootmode 0 --yes --lab "$tmp/lab-bm-nojar.conf"
printf 'SOFT_CONSOLE=%s/bm/sc\nJAVA=%s/bm/bin/java\nFPGENPROG=%s/bm/libero/none\n' "$tmp" "$tmp" "$tmp" > "$tmp/lab-bm-nofp.conf"
expect_rc  "bootmode: a missing fpgenprog exits 2" 2 bootmode 0 --yes --lab "$tmp/lab-bm-nofp.conf"
expect_out "bootmode: a missing fpgenprog says what to do" "set FPGENPROG" bootmode 0 --yes --lab "$tmp/lab-bm-nofp.conf"
rm -f "$tmp/bm/java.args"
expect_rc  "bootmode: a jar that fails exits 1" 1 env STANDIN_RC=3 "$PY" "$HW/bootmode.py" 0 "$BME" --workdir "$BMW" --yes --lab "$LB"
expect_out "bootmode: a failed jar is named with its status" "ended with status 3" env STANDIN_RC=3 "$PY" "$HW/bootmode.py" 0 "$BME" --workdir "$BMW" --yes --lab "$LB"
if STANDIN_RC=3 "$PY" "$HW/bootmode.py" 0 "$BME" --workdir "$BMW" --yes --lab "$LB" 2>&1 | grep -q "Power-cycle the board"; then fail "bootmode: a failed jar does not say 'power-cycle'"; else pass "bootmode: a failed jar does not say 'power-cycle'"; fi
expect_rc  "bootmode: a jar without any output exits 1" 1 env STANDIN_SILENT=1 "$PY" "$HW/bootmode.py" 0 "$BME" --workdir "$BMW" --yes --lab "$LB"
expect_out "bootmode: no output is named" "printed nothing" env STANDIN_SILENT=1 "$PY" "$HW/bootmode.py" 0 "$BME" --workdir "$BMW" --yes --lab "$LB"
expect_rc  "bootmode: a lab.conf that does not exist exits 2" 2 bootmode 0 --yes --lab "$tmp/none.conf"
# every set-up error comes with the help text and its description of the boot modes
expect_out "bootmode: a bad boot mode prints the error and the help text" "non-secure boot from eNVM" bootmode 4 --yes --lab "$LB"
expect_out "bootmode: a bad boot mode names the error" "is not a boot mode" bootmode 4 --yes --lab "$LB"
expect_out "bootmode: no arguments print the error and the help text" "user secure boot from sNVM" "$PY" "$HW/bootmode.py"
expect_out "bootmode: a missing jar prints the help text too" "factory secure boot from eNVM" bootmode 0 --yes --lab "$tmp/lab-bm-nojar.conf"
expect_out "bootmode: a missing java prints the help text too" "idle boot" bootmode 0 --yes --lab "$tmp/lab-bm-nojava.conf"
expect_out "bootmode: the refusal without --yes prints the help text too" "idle boot" bootmode 1 --lab "$LB" </dev/null
expect_rc  "bootmode: --help exits 0" 0 "$PY" "$HW/bootmode.py" --help
expect_out "bootmode: --help says PERMANENT" "PERMANENT" "$PY" "$HW/bootmode.py" --help
# the boot program
expect_rc  "bootmode: a missing ELF exits 2" 2 "$PY" "$HW/bootmode.py" 0 "$tmp/none.elf" --yes --lab "$LB"
expect_out "bootmode: a missing ELF names it and prints the help text" "none.elf' does not exist" "$PY" "$HW/bootmode.py" 0 "$tmp/none.elf" --yes --lab "$LB"
expect_out "bootmode: --dry-run without an ELF names bare_hello" "bare_hello.elf" "$PY" "$HW/bootmode.py" 1 --dry-run --lab "$LB"
# without an ELF the example bare_hello is built (./x build bare_hello --hart e51): a tree with a stand-in x
mkdir -p "$tmp/bmroot/hw" "$tmp/bmroot/examples/bare_hello/bin-e51"
cp "$HW/bootmode.py" "$HW/lab.py" "$HW/lab.conf.example" "$tmp/bmroot/hw/"
printf '#!/bin/sh\necho "$@" > "%s/bmroot/x.args"\n' "$tmp" > "$tmp/bmroot/x"; chmod +x "$tmp/bmroot/x"
printf 'bare_hello ELF\n' > "$tmp/bmroot/examples/bare_hello/bin-e51/bare_hello.elf"
rm -f "$tmp/bm/java.args"
"$PY" "$tmp/bmroot/hw/bootmode.py" 1 --yes --lab "$LB" >/dev/null 2>&1
[ "$(cat "$tmp/bmroot/x.args" 2>/dev/null)" = "build bare_hello --hart e51" ] && pass "bootmode: without an ELF it builds bare_hello for the E51" || fail "bootmode: without an ELF it builds bare_hello for the E51"
args="$(tr '\n' ' ' < "$tmp/bm/java.args" 2>/dev/null)"
case "$args" in *"--workdir $tmp/bmroot/build/bootmode --bootmode 1 "*" bare_hello.elf ") pass "bootmode: the default working directory is build/bootmode and the ELF is bare_hello.elf" ;; *) fail "bootmode: the default working directory is build/bootmode and the ELF is bare_hello.elf (got: $args)" ;; esac
[ -f "$tmp/bmroot/build/bootmode/bare_hello.elf" ] && pass "bootmode: bare_hello.elf is copied to the working directory" || fail "bootmode: bare_hello.elf is copied to the working directory"
printf '#!/bin/sh\nexit 3\n' > "$tmp/bmroot/x"
expect_rc  "bootmode: a failing build of bare_hello exits 2" 2 "$PY" "$tmp/bmroot/hw/bootmode.py" 1 --yes --lab "$LB"
# boot mode 0 needs no boot program: none is built, none is passed
printf '#!/bin/sh\necho "$@" > "%s/bmroot/x.args"\n' "$tmp" > "$tmp/bmroot/x"
rm -f "$tmp/bm/java.args" "$tmp/bmroot/x.args"
"$PY" "$tmp/bmroot/hw/bootmode.py" 0 --yes --lab "$LB" >/dev/null 2>&1
args="$(tr '\n' ' ' < "$tmp/bm/java.args" 2>/dev/null)"
case "$args" in *"--bootmode 0 --die MPFS250T_ES --package FCVG484 ") pass "bootmode: mode 0 without an ELF passes none" ;; *) fail "bootmode: mode 0 without an ELF passes none (got: $args)" ;; esac
[ ! -e "$tmp/bmroot/x.args" ] && pass "bootmode: mode 0 without an ELF builds nothing" || fail "bootmode: mode 0 without an ELF builds nothing"
# the jar finds SoftConsole and fpgenprog by environment variables
[ "$(cat "$tmp/bm/java.sc")" = "$tmp/bm/sc" ] && pass "bootmode: sets SC_INSTALL_DIR to SOFT_CONSOLE for the jar" || fail "bootmode: sets SC_INSTALL_DIR to SOFT_CONSOLE for the jar (got: $(cat "$tmp/bm/java.sc"))"
[ "$(cat "$tmp/bm/java.fp")" = "$tmp/bm/libero/fpgenprog" ] && pass "bootmode: sets FPGENPROG to the full path for the jar" || fail "bootmode: sets FPGENPROG to the full path for the jar (got: $(cat "$tmp/bm/java.fp"))"
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
# FPGENPROG is the full path of the executable, a name on PATH is not enough
printf 'SOFT_CONSOLE=%s/bm/sc\nJAVA=%s/bm/bin/java\nFPGENPROG=fpgenprog\n' "$tmp" "$tmp" > "$tmp/lab-bm-fpname.conf"
expect_rc  "bootmode: a bare fpgenprog name exits 2 even when it is on PATH" 2 env PATH="$tmp/bm/libero:$PATH" "$PY" "$HW/bootmode.py" 0 --yes --lab "$tmp/lab-bm-fpname.conf"
expect_out "bootmode: a bare fpgenprog name says it needs the full path" "full path of the fpgenprog executable" env PATH="$tmp/bm/libero:$PATH" "$PY" "$HW/bootmode.py" 0 --yes --lab "$tmp/lab-bm-fpname.conf"
printf 'SOFT_CONSOLE=%s/bm/sc\nJAVA=%s/bm/bin/java\nFPGENPROG=%s/bm/libero\n' "$tmp" "$tmp" "$tmp" > "$tmp/lab-bm-fpdir.conf"
expect_rc  "bootmode: a directory as FPGENPROG exits 2" 2 "$PY" "$HW/bootmode.py" 0 --yes --lab "$tmp/lab-bm-fpdir.conf"
# the copy of lab.conf.example has no header lines; the keys and their notes stay
cp "$HW/bootmode.py" "$HW/lab.py" "$HW/lab.conf.example" "$tmp/bmroot/hw/"
rm -f "$tmp/bmroot/hw/lab.conf"
env -u LAB_CONF "$PY" "$tmp/bmroot/hw/bootmode.py" 0 --dry-run >/dev/null 2>&1
if [ -f "$tmp/bmroot/hw/lab.conf" ] && ! grep -q 'lab.conf.example --' "$tmp/bmroot/hw/lab.conf" && ! grep -q 'Copy it to' "$tmp/bmroot/hw/lab.conf" \
   && grep -q '^SOFT_CONSOLE=' "$tmp/bmroot/hw/lab.conf" && grep -q '^#   FPGENPROG ' "$tmp/bmroot/hw/lab.conf"; then
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
out="$(FORCE_COLOR=1 "$PY" "$HW/bootmode.py" 4 --yes --lab "$LB" 2>&1)"
case "$out" in *$'\033[1;31m'*) pass "bootmode: an error is red" ;; *) fail "bootmode: an error is red" ;; esac
# OpenOCD must not run while the boot mode changes
"$PY" -c 'import socket,sys,time; s=socket.socket(); s.bind(("127.0.0.1",0)); s.listen(5); print(s.getsockname()[1], flush=True); time.sleep(30)' > "$tmp/ocdport" &
ocdpid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$tmp/ocdport" ] && break; sleep 0.2; done
printf 'OCD_HOST=127.0.0.1\nOCD_PORT=%s\n' "$(cat "$tmp/ocdport")" | cat "$LB" - > "$tmp/lab-bm-ocd.conf"
rm -f "$tmp/bm/java.args"
expect_rc  "bootmode: refuses while OpenOCD answers on its port" 2 bootmode 0 --yes --lab "$tmp/lab-bm-ocd.conf"
expect_out "bootmode: says OpenOCD has to be stopped first" "stop it first" bootmode 0 --yes --lab "$tmp/lab-bm-ocd.conf"
[ ! -e "$tmp/bm/java.args" ] && pass "bootmode: does not run the programmer while OpenOCD runs" || fail "bootmode: does not run the programmer while OpenOCD runs"
expect_rc  "bootmode: --dry-run is allowed while OpenOCD runs" 0 bootmode 0 --dry-run --lab "$tmp/lab-bm-ocd.conf"
kill "$ocdpid" 2>/dev/null; wait "$ocdpid" 2>/dev/null
printf 'OCD_HOST=127.0.0.1\nOCD_PORT=1\n' | cat "$LB" - > "$tmp/lab-bm-noocd.conf"
expect_rc  "bootmode: runs when nothing answers on the OpenOCD port" 0 bootmode 0 --yes --lab "$tmp/lab-bm-noocd.conf"
expect_rc  "x hw bootmode: --dry-run passes through" 0 "$X" hw bootmode 0 --dry-run --lab "$LB"
expect_rc  "x hw bootmode: a bad boot mode exits 2" 2 "$X" hw bootmode 9 --yes --lab "$LB"
grep -q '^BOOTMODE_DIE=MPFS250T_ES$' "$HW/lab.conf.example" && grep -q '^BOOTMODE_PACKAGE=FCVG484$' "$HW/lab.conf.example" \
  && pass "lab.conf.example: the die and the package of the bootmode programmer" || fail "lab.conf.example: the die and the package of the bootmode programmer"

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
standin () {   # standin <name> <script body>: a SoftConsole directory $tmp/sc-<name> whose openocd writes its pid to $tmp/<name>.pid
  mkdir -p "$tmp/sc-$1/openocd/bin"
  printf '#!/bin/sh\necho $$ > "%s/%s.pid"\n%s\n' "$tmp" "$1" "$2" > "$tmp/sc-$1/openocd/bin/openocd"
  chmod +x "$tmp/sc-$1/openocd/bin/openocd"
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
  ready="$tmp/$2.pid" again="${4:-}" START_OPENOCD_GRACE="$3" SOFT_CONSOLE="$tmp/sc-$2" LAB_CONF="$tmp/none.conf" \
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
START_OPENOCD_GRACE=1 SOFT_CONSOLE="$tmp/sc-quits" LAB_CONF="$tmp/none.conf" sh "$HW/start_openocd.sh" >/dev/null 2>&1; rc=$?
[ $rc -eq 7 ] && pass "start_openocd: the exit status of OpenOCD is passed on" || fail "start_openocd: the exit status of OpenOCD is passed on (exit $rc)"
expect_rc  "start_openocd: a bad grace period exits 2" 2 env START_OPENOCD_GRACE=soon SOFT_CONSOLE="$tmp/sc-quits" LAB_CONF="$tmp/none.conf" sh "$HW/start_openocd.sh"

# ./x hw openocd: the signal goes to x, hw.sh, the supervisor and OpenOCD alike, and none of them may hold it up
rm -f "$tmp/stubborn.pid"
ready="$tmp/stubborn.pid" START_OPENOCD_GRACE=1 SOFT_CONSOLE="$tmp/sc-stubborn" LAB_CONF="$tmp/none.conf" run_signal INT 0.3 20 "$tmp/sup.out" "$X" hw openocd
ready=""
[ $rc -eq 130 ] && [ $ms -lt 3000 ] && gone "$tmp/stubborn.pid" && pass "x hw openocd: Ctrl+C ends OpenOCD, exit 130, nothing left behind" \
  || fail "x hw openocd: Ctrl+C ends OpenOCD, exit 130, nothing left behind (rc $rc, $ms ms: $(cat "$tmp/sup.out"))"

# --- lab.conf ---------------------------------------------------------------------
grep -Eq '^SOFT_CONSOLE=/opt/Microchip_SoftConsole' "$HW/lab.conf.example" && grep -q '^UART_PATTERN=.*{n}' "$HW/lab.conf.example" \
  && grep -q '^OCD_PORT=4444$' "$HW/lab.conf.example" \
  && pass "lab.conf.example: the SoftConsole path, the OpenOCD port and the serial pattern" \
  || fail "lab.conf.example: the SoftConsole path, the OpenOCD port and the serial pattern"
git -C "$HW" check-ignore -q lab.conf 2>/dev/null && pass "lab.conf is ignored by git" || fail "lab.conf is ignored by git"
printf 'OCD_PORT=5555\n' > "$tmp/lab-onlyport.conf"
[ "$("$PY" -c 'import sys; sys.path.insert(0, sys.argv[1]); import lab; v = lab.load(sys.argv[2]); print(v["OCD_PORT"], v["SOFT_CONSOLE"], v["BOOTMODE_DIE"])' "$HW" "$tmp/lab-onlyport.conf")" = "5555 /opt/Microchip_SoftConsole-v2022.2 MPFS250T_ES" ] \
  && pass "lab.py: a key that the conf does not set takes its default from lab.conf.example" \
  || fail "lab.py: a key that the conf does not set takes its default from lab.conf.example"

echo "summary: $fails failure(s)"
[ $fails -eq 0 ]
