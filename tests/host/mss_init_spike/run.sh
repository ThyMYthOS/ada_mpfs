#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Tests for the MSS set-up of examples/mss_init_spike: the Ada image runs a table that
# config/gen/mss_init_table.py makes from the MSS Configurator XML of the board and from hw/mss_init.py (the
# sequence of `./x hw initialize`), and the register writes of the image under QEMU must be that sequence.
#
#   - the generator: the committed table is current (--check), the output is the same twice, another XML, --skip-io
#     and a tampered value give other tables, an unknown XML and a Write that does not exist are exit status 2;
#   - the images (both built from the committed table; a third from a table with one value flipped, the negative
#     control): the board image and the QEMU image link;
#   - QEMU's register trace (-trace memory_region_ops_read/write, compared by compare_trace.py with the steps of
#     hw/mss_init.py run by mss_init.run): the QEMU image writes the sequence of icicle_es, a Modify writes
#     what it read, polls and the silicon decision read their register; the board image stops at the first poll
#     that times out (QEMU does not model the SGMII PLL) and says MSS INIT FAILED;
#   - the XML of the build: MSS_XML (example.conf, or the environment, which wins) and MSS_INIT_OPTS of ./x build: the
#     default has the committed table, another board's XML gives a table and an image with its SHA-256 (and the
#     QEMU trace of that image equals the sequence of that XML), --skip-io, and a broken XML (truncated, a field that
#     leaves its register) fails the build with exit 2 and the reader's code;
#   - the log: nothing is written to MMUART0 before the end of the sequence (compare_trace.py: no access before the
#     console bring-up, which follows the last write of the table), the console is complete and in order with the
#     verdict last (check_console.py), also after the stop of the board image at a poll, and with a ring that is too
#     small (a second image, built with MSS_INIT_RING_DIR) the dropped bytes are counted and said;
#   - controls: the image of the tampered table fails the comparison at the write that was flipped; the same trace
#     fails against the XML of another board and against a trace with a write left out.
#
# Three ways to run it:
#   - alone: generator cases, builds the images, runs the QEMU cases if QEMU 10.1 or newer is installed
#     (QEMU_MIN of tools/toolchain.env); the builds are skipped when the pinned GNAT is missing;
#   - MSS_INIT_SPIKE_QEMU=0: no QEMU cases even if QEMU is installed (CI job `build`, which has no QEMU; the
#     cases run in job `qemu`);
#   - MPFS_PREBUILT_IMAGES=1: builds nothing and needs no toolchain: only the QEMU cases, on the images of
#     ./x test examples (examples/mss_init_spike/bin-e51/) and the tampered image of an earlier build
#     (MSS_INIT_SPIKE_IMAGES, default build/mss-init-spike). A missing image or a missing QEMU fails.
#   MSS_INIT_SPIKE_IMAGES=<dir> in a run that builds copies the tampered image and the image with the small ring there (tampered.elf, ring.elf).
# The generator cases need the merged SVD (tools/svd.py ensure, which needs svdtools if it is missing or stale).
# Exits non-zero on any failure.

set -u
export LC_ALL=C
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HERE="$ROOT/tests/host/mss_init_spike"
EX="$ROOT/examples/mss_init_spike"
GEN="$ROOT/config/gen/mss_init_table.py"
XML="config/boards/icicle_es/ICICLE_MSS_mss_cfg.xml"
OTHER_XML="config/boards/icicle/ICICLE_MSS_mss_cfg.xml"
TABLE="$EX/src/generated/mpfs_init_table.ads"
TAMPER=10   # the Write that the negative control flips (0 is the first); the 11th write of the sequence
fails=0
cd "$ROOT" || exit 1

pass () { echo "ok:   $1"; }
fail () { echo "FAIL: $1" >&2; fails=$((fails + 1)); }
skip () { echo "skip: $1"; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

. "$ROOT/tools/mpfs-env.sh"
mpfs_find_python
PY="$MPFS_PYTHON"
prebuilt=0; [ "${MPFS_PREBUILT_IMAGES:-}" = 1 ] && prebuilt=1
keep="${MSS_INIT_SPIKE_IMAGES:-$ROOT/build/mss-init-spike}"
build_ok=1
if [ "$prebuilt" = 0 ] && ! mpfs_toolchain_on_path >/dev/null 2>&1; then
  build_ok=0; skip "the builds: the pinned toolchain is not installed (./x toolchain install gnat)"
fi

# QEMU: the version floor of the project
QEMU="${QEMU:-qemu-system-riscv64}"
qemu_ok=0
qemu_min="$(sed -n 's/^QEMU_MIN=//p' "$ROOT/tools/toolchain.env" | head -n 1)"
if command -v "$QEMU" >/dev/null 2>&1; then
  have="$("$QEMU" --version 2>&1 | sed -n '1s/.*version \([0-9]*\)\.\([0-9]*\).*/\1 \2/p')"
  # shellcheck disable=SC2086
  set -- $have
  if [ $# -eq 2 ] && { [ "$1" -gt "${qemu_min%%.*}" ] || { [ "$1" -eq "${qemu_min%%.*}" ] && [ "$2" -ge "${qemu_min#*.}" ]; }; }; then
    qemu_ok=1
  fi
fi
if [ "${MSS_INIT_SPIKE_QEMU:-1}" = 0 ]; then
  qemu_ok=0; skip "the QEMU cases: MSS_INIT_SPIKE_QEMU=0"
elif [ "$qemu_ok" = 1 ]; then :
elif [ "$prebuilt" = 1 ]; then fail "QEMU $qemu_min or newer is not installed (MPFS_PREBUILT_IMAGES=1 runs only the QEMU cases)"
else skip "the QEMU cases: QEMU $qemu_min or newer is not installed"
fi

# -- the generator ---------------------------------------------------------------------------------------------
if [ "$prebuilt" = 0 ]; then
  if "$PY" -I "$GEN" --xml "$XML" --check >"$work/check.out" 2>&1; then
    pass "the committed table is current (--check)"
  else
    cat "$work/check.out" >&2; fail "the committed table is current (--check)"
  fi
  "$PY" -I "$GEN" --xml "$XML" --output "$work/a.ads" && "$PY" -I "$GEN" --xml "$XML" --output "$work/b.ads" \
    && cmp -s "$work/a.ads" "$work/b.ads" && cmp -s "$work/a.ads" "$TABLE" \
    && pass "the output is the same twice and the committed one" || fail "the output is the same twice and the committed one"
  "$PY" -I "$GEN" --xml "$OTHER_XML" --check --output "$TABLE" >/dev/null 2>&1
  [ $? -eq 1 ] && pass "the table of another board's XML is not current (exit 1)" \
    || fail "the table of another board's XML is not current (exit 1)"
  "$PY" -I "$GEN" --xml "$XML" --skip-io --check --output "$TABLE" >/dev/null 2>&1
  [ $? -eq 1 ] && pass "the table without the IO set-up is not current (exit 1)" \
    || fail "the table without the IO set-up is not current (exit 1)"
  "$PY" -I "$GEN" --xml "$XML" --tamper-write "$TAMPER" --output "$work/tampered/mpfs_init_table.ads"
  d="$(diff "$TABLE" "$work/tampered/mpfs_init_table.ads" | grep -c '^[<>]')"
  [ "$d" = 2 ] && pass "--tamper-write $TAMPER changes one line (the value of one entry)" \
    || fail "--tamper-write $TAMPER changes one line (the value of one entry; $d differing lines)"
  "$PY" -I "$GEN" --xml "$XML" --tamper-write 9999 --output "$work/x.ads" >/dev/null 2>&1
  [ $? -eq 2 ] && pass "a Write that the table does not have is exit status 2" || fail "a Write that the table does not have is exit status 2"
  "$PY" -I "$GEN" --xml "$work/missing.xml" --output "$work/x.ads" >/dev/null 2>&1
  [ $? -eq 2 ] && pass "a missing XML is exit status 2" || fail "a missing XML is exit status 2"
  # the table says the same as the Python sequence: its entries are the steps of full(), the IfSet flattened, and
  # the register that an entry names is the register of the merged SVD at the address of the step
  "$PY" -I - "$TABLE" "$XML" <<'EOF' >"$work/entries.out" 2>&1 && pass "$(cat "$work/entries.out")" || fail "$(cat "$work/entries.out")"
import re, sys
from pathlib import Path
sys.path[:0] = ["hw", "config/gen", "tools"]
import mss_init
import mss_init_table
from gen_ada import svdread
values = mss_init.load(Path(sys.argv[2]))
steps = mss_init.full(values)
want = mss_init_table.entries_of(steps)
registers = svdread.register_map(svdread.load(svdread.ensure(Path("."))))
text = open(sys.argv[1]).read()
rows = re.findall(r"\(Kind => (\w+), Register => ([A-Za-z0-9_.']+),\s+Value => 16#([0-9A-F_]+)#, Mask => 16#([0-9A-F_]+)#, Count => (\d+),", text)
assert len(rows) == len(want), f"{len(rows)} entries in the table, {len(want)} from the steps"
named = 0
for i, ((kind, register, value, mask, count), entry) in enumerate(zip(rows, want), 1):
    got = (kind, int(value.replace("_", ""), 16), int(mask.replace("_", ""), 16), int(count))
    assert got == (entry.kind, entry.value, entry.mask, entry.count), f"entry {i} differs"
    if entry.kind == "Wait":
        assert register == "System.Null_Address", f"entry {i}: {register}"
    else:
        at = registers[entry.address]
        assert register == f"{at.peripheral}.{at.name}'Address", f"entry {i}: {register} is not the register at 0x{entry.address:08X} ({at.peripheral}.{at.name})"
        named += 1
print(f"the {len(want)} entries of the table are the {len(steps)} steps of mss_init.full (kind, value, mask, count) and the {named} registers they name are the registers of the SVD at the addresses of the steps")
EOF
  # an address that no register of the merged SVD covers is refused (exit status 2, the step and the address named)
  "$PY" -I - "$XML" <<'EOF' >"$work/refuse.out" 2>&1 && pass "a step on an address with no register of the SVD is refused: $(cat "$work/refuse.out")" || fail "a step on an address with no register of the SVD is refused: $(cat "$work/refuse.out")"
import sys
from pathlib import Path
sys.path[:0] = ["hw", "config/gen", "tools"]
import mss_init
import mss_init_table
from gen_ada import errors
real = mss_init.phases
def broken(values, io=True):
    phases = list(real(values, io))
    first = phases[0]
    phases[0] = mss_init.Phase(first.name, first.what, (mss_init.Write(0x20002201, 1, "a write between two registers"), *first.steps))
    return tuple(phases)
mss_init.phases = broken
status = errors.run(mss_init_table.main, "mss_init_table", ["--xml", sys.argv[1], "--output", "/dev/null"])
assert status == 2, f"exit status {status}"
mss_init.phases = real
print("exit status 2")
EOF
  # the fabric sources of the image (Fabric: Ada.Interrupts.Names.F2M_0 .. F2M_63) are the fabric interrupts of the SVD
  "$PY" -I - <<'EOF' >"$work/fabric.out" 2>&1 && pass "$(cat "$work/fabric.out")" || fail "$(cat "$work/fabric.out")"
import re, sys
from pathlib import Path
sys.path[:0] = ["tools"]
from gen_ada import svdread
interrupts = svdread.interrupts(svdread.load(svdread.ensure(Path("."))))
fabric = {i.name: int(i.value) for i in interrupts if i.name.startswith("F2M_")}
assert fabric == {f"F2M_{n}": 118 + n for n in range(64)}, "the F2M_<n> interrupts of the SVD are not F2M_0 .. F2M_63 = 118 .. 181"
assert {int(i.value) for i in interrupts if 118 <= int(i.value) <= 181} == set(range(118, 182)), "another source in 118 .. 181"
assert not [i.name for i in interrupts if re.match(r"F2H|FAB", i.name)], "another fabric-named source"
names = {k: int(v) for k, v in re.findall(r"^   (F2M_\d+) : constant Interrupt_ID := (\d+);", open("crates/mpfs_rts/mpfs/gnarl/a-intnam.ads").read(), re.M)}
assert names == fabric, "Ada.Interrupts.Names of the runtime differs from the SVD in the F2M sources"
source = open("examples/mss_init_spike/src/fabric.ads").read()
assert "Names.F2M_0" in source and "Names.F2M_63" in source and "Source_Count" in source
print("the image's fabric sources, Ada.Interrupts.Names.F2M_0 .. F2M_63, are the 64 F2M interrupts of the SVD (118 .. 181, nothing else in that range) and the runtime's names agree")
EOF
fi

# -- the images --------------------------------------------------------------------------------------------------
real="$EX/bin-e51"
xbuild () {   # xbuild <log> [table dir]: ./x build of the example, with the table of <table dir> if given
  local log="$1"
  rm -rf "$EX/obj-e51" "$EX/bin-e51"
  if [ -n "${2:-}" ]; then MSS_INIT_TABLE_DIR="$2" "$ROOT/x" build mss_init_spike --hart e51 >"$log" 2>&1
  else "$ROOT/x" build mss_init_spike --hart e51 >"$log" 2>&1; fi
}
# the image with a ring that is too small for the log (src/ring/ring_size.ads of another directory)
mkring () {   # mkring <dir>
  mkdir -p "$1"
  sed 's/Size : constant := [0-9]*;/Size : constant := 512;/' "$EX/src/ring/ring_size.ads" >"$1/ring_size.ads"
}
if [ "$prebuilt" = 1 ]; then
  tampered_elf="$keep/tampered.elf"
  ring_elf="$keep/ring.elf"
elif [ "$build_ok" = 1 ]; then
  if xbuild "$work/tampered.log" "$work/tampered"; then
    cp "$real/mss_init_spike_qemu.elf" "$work/tampered.elf"
    if [ -n "${MSS_INIT_SPIKE_IMAGES:-}" ]; then mkdir -p "$keep" && cp "$work/tampered.elf" "$keep/tampered.elf"; fi
    pass "the image of the tampered table builds"
  else
    tail -5 "$work/tampered.log" >&2; fail "the image of the tampered table builds"
  fi
  tampered_elf="$work/tampered.elf"
  mkring "$work/ring"
  rm -rf "$EX/obj-e51" "$EX/bin-e51"
  if MSS_INIT_RING_DIR="$work/ring" "$ROOT/x" build mss_init_spike --hart e51 >"$work/ring.log" 2>&1; then
    cp "$real/mss_init_spike_qemu.elf" "$work/ring.elf"
    if [ -n "${MSS_INIT_SPIKE_IMAGES:-}" ]; then mkdir -p "$keep" && cp "$work/ring.elf" "$keep/ring.elf"; fi
    pass "the image with a ring of 512 bytes builds"
  else
    tail -5 "$work/ring.log" >&2; fail "the image with a ring of 512 bytes builds"
  fi
  ring_elf="$work/ring.elf"
  if xbuild "$work/real.log"; then
    pass "the board image and the QEMU image build ($(riscv64-elf-size -B "$real/mss_init_spike.elf" | awk 'NR == 2 { print $1 " text, " $2 " data, " $3 " bss" }'))"
  else
    tail -5 "$work/real.log" >&2; fail "the images build"
  fi
fi

# qrun <name> <elf> <regexp> [ticks]: boots the image with the register trace; the serial ports are $work/<name>.s0 to
# .s4 (the console is MMUART2, .s2; the status lines are on MMUART0, .s0) and the trace $work/<name>.trace. Returns 0 if
# the regexp is on the console within 60 s and, with <ticks>, the status line with that number is on MMUART0.
qrun () {
  local name="$1" elf="$2" re="$3" ticks="${4:-}" pid i ok=1
  "$QEMU" -M microchip-icicle-kit -smp 5 -m 2G -display none -monitor none -bios none -kernel "$elf" -no-reboot \
    -serial "file:$work/$name.s0" -serial "file:$work/$name.s1" -serial "file:$work/$name.s2" \
    -serial "file:$work/$name.s3" -serial "file:$work/$name.s4" \
    -trace memory_region_ops_read -trace memory_region_ops_write -D "$work/$name.trace" \
    >"$work/$name.qemu" 2>&1 &
  pid=$!
  for i in $(seq 1 120); do
    if grep -Eq "$re" "$work/$name.s2" 2>/dev/null; then ok=0; break; fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.5
  done
  if [ -n "$ticks" ] && [ $ok -eq 0 ]; then
    for i in $(seq 1 120); do
      grep -q "^tick $ticks: " "$work/$name.s0" 2>/dev/null && break
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.5
    done
  fi
  sleep 1.2   # a status line that should not be there would come within 1 s
  kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  return $ok
}

# has <name> <regexp> <what>: the console of the run has a line
has () {
  grep -Eq "$2" "$work/$1.s2" && pass "$3" || { fail "$3 (no /$2/ on the console)"; sed 's/^/      | /' "$work/$1.s2" | tail -20 >&2; }
}

if [ "$qemu_ok" = 1 ]; then
  q="$real/mss_init_spike_qemu.elf"
  if [ ! -f "$q" ]; then
    fail "the QEMU image $q is missing"
  elif qrun q "$q" 'MSS INIT (OK|DONE|FAILED)' 3; then
    has q 'mss_init_spike_qemu: [0-9]+ table entries in 5 phases, a poll that times out is reported' "the console names the entries, the phases and the policy"
    has q 'mss_init_spike_qemu: xml sha256 [0-9a-f]{64}' "the console names the XML by its SHA-256"
    for ph in 'phase 1 refclk' 'phase 2 io' 'phase 3 mssio' 'phase 4 sgmii' 'phase 5 pll'; do
      has q "mss_init_spike_qemu: $ph: entries [0-9]+-[0-9]+, [0-9]+ run, [0-9]+ poll timeout" "the console has a line for the $ph"
    done
    has q 'mss_init_spike_qemu: TIMEOUT entry [0-9]+: .*, wanted 0x' "a poll that timed out is named with the word it read"
    has q 'mss_init_spike_qemu: mtime 0x[0-9a-f]{8} then 0x[0-9a-f]{8} after 100 us by mcycle: advancing' "mtime advances between two reads"
    has q 'mss_init_spike_qemu: MSS PLL: PLL_CTRL 0x[0-9a-f]{8}, LOCK [01]' "the console reads the PLL status back"
    has q 'mss_init_spike_qemu: MSS INIT DONE WITH TIMEOUTS' "the QEMU image reports its timeouts and ends"
    if msg="$("$PY" -I "$HERE/check_console.py" "$work/q.s0" ticks 3 fabric 2 119:2,123:1 2>&1)"; then
      pass "MMUART0 carries three status lines after the log, the fabric table none in tick 1 and the injected sources from tick 2 on: $msg"
    else
      fail "MMUART0 carries three status lines after the log: $msg"
    fi
    if msg="$("$PY" -I "$HERE/check_console.py" "$work/q.s2" mss_init_spike_qemu full 2>&1)"; then
      pass "the console of the QEMU image is complete and in order: $msg"
    else
      fail "the console of the QEMU image is complete and in order: $msg"
    fi
    if msg="$("$PY" -I "$HERE/compare_trace.py" "$work/q.trace" --xml "$ROOT/$XML" --fabric-masked 119,123 2>&1)"; then
      pass "the writes of the QEMU image are the sequence of hw/mss_init.py: $msg"
    else
      fail "the writes of the QEMU image are the sequence of hw/mss_init.py: $msg"
    fi
    # controls: the comparison is not vacuous
    if msg="$("$PY" -I "$HERE/compare_trace.py" "$work/q.trace" --xml "$ROOT/$OTHER_XML" --fabric-masked 119,123 2>&1)"; then
      fail "control: the trace passes against the XML of another board"
    else
      pass "control: the trace fails against the XML of another board ($msg)"
    fi
    grep -v 'addr 0x3e001020 ' "$work/q.trace" >"$work/q-dropped.trace"
    if msg="$("$PY" -I "$HERE/compare_trace.py" "$work/q-dropped.trace" --xml "$ROOT/$XML" --fabric-masked 119,123 2>&1)"; then
      fail "control: a trace with a write left out passes"
    else
      pass "control: a trace with a write left out fails ($msg)"
    fi
    # the masks that the injected sources cause are in the trace: expecting none fails
    if msg="$("$PY" -I "$HERE/compare_trace.py" "$work/q.trace" --xml "$ROOT/$XML" 2>&1)"; then
      fail "control: the trace passes without the masks of the injected sources"
    else
      pass "control: the trace passes only with the masks of the injected sources, F2M_1 and F2M_5 ($msg)"
    fi
    # the sink gate: an access to MMUART0 before the end of the sequence fails the comparison
    awk '{ print } !done && /addr 0x2000200c value 0x7d / { print "memory_region_ops_write cpu 0 mr 0x1 addr 0x20000000 value 0x41 size 4 name '"'"'serial'"'"'"; done = 1 }' "$work/q.trace" >"$work/q-early.trace"
    if msg="$("$PY" -I "$HERE/compare_trace.py" "$work/q-early.trace" --xml "$ROOT/$XML" --fabric-masked 119,123 2>&1)"; then
      fail "control: a byte written to MMUART0 during the sequence passes"
    else
      pass "control: a byte written to MMUART0 during the sequence fails ($msg)"
    fi
    # the same for MMUART2 (data), for the clock of a port (SYSREG) before the last write of the table, and for MMUART0
    # before the last byte of the log has gone out on MMUART2
    "$PY" -I - "$work/q.trace" "$work" <<'EOF'
import sys
lines = open(sys.argv[1]).read().splitlines()
work = sys.argv[2]
def write(address, value):
    return f"memory_region_ops_write cpu 0 mr 0x1 addr {address:#x} value {value:#x} size 4 name 'x'"
first = next(i for i, l in enumerate(lines) if "addr 0x2000200c value 0x7d " in l)
def variant(name, index, text):
    open(f"{work}/{name}.trace", "w").write("\n".join(lines[:index] + [text] + lines[index:]) + "\n")
variant("q-early2", first + 1, write(0x20102000, 0x41))
variant("q-clock", first + 1, write(0x20002084, 0x80))
last = max(i for i, l in enumerate(lines) if "ops_write" in l and "addr 0x20102000 " in l)
variant("q-order", last, write(0x20000000, 0x41))
variant("q-plic-priority", first + 1, write(0x0C000000 + 4 * 119, 1))
variant("q-plic-enable", first + 1, write(0x0C00200C, 1 << 23))
open(f"{work}/q-attach.trace", "w").write("\n".join(l for l in lines if "addr 0xc000258 " not in l) + "\n")
open(f"{work}/q-level.trace", "w").write("\n".join(l.replace("addr 0xc0001dc value 0x1 ", "addr 0xc0001dc value 0x3 ") for l in lines) + "\n")
open(f"{work}/q-divisor.trace", "w").write("\n".join(l.replace("addr 0x20000000 value 0xb ", "addr 0x20000000 value 0xc ") for l in lines) + "\n")
open(f"{work}/q-ier0.trace", "w").write("\n".join(lines + [write(0x20000004, 0x2)]) + "\n")
open(f"{work}/q-dfr.trace", "w").write("\n".join(lines + [write(0x2000003c, 0x36)]) + "\n")
EOF
    for control in "q-early2:a byte written to MMUART2 during the sequence" "q-clock:the clock of MMUART2 released during the sequence" \
                   "q-order:a byte written to MMUART0 before the last byte of the log on MMUART2" "q-divisor:a wrong divisor of MMUART0" \
                   "q-ier0:an interrupt enable of MMUART0" "q-dfr:a write to the fractional baud rate register" \
                   "q-plic-priority:a PLIC priority of a fabric source during the sequence" "q-plic-enable:a PLIC enable bit during the sequence" \
                   "q-attach:a fabric source (F2M_32) that is not attached" "q-level:a fabric source (F2M_1) at level 3"; do
      if msg="$("$PY" -I "$HERE/compare_trace.py" "$work/${control%%:*}.trace" --xml "$ROOT/$XML" --fabric-masked 119,123 2>&1)"; then
        fail "control: ${control#*:} passes"
      else
        pass "control: ${control#*:} fails ($msg)"
      fi
    done
    awk '{ print } !done && /addr 0x2000200c value 0x7d / { print "memory_region_ops_write cpu 0 mr 0x1 addr 0x20000004 value 0x2 size 4 name '"'"'serial'"'"'"; done = 1 }' "$work/q.trace" >"$work/q-ier.trace"
    if "$PY" -I "$HERE/compare_trace.py" "$work/q-ier.trace" --xml "$ROOT/$XML" --fabric-masked 119,123 >/dev/null 2>&1; then
      fail "control: an interrupt enable of MMUART0 during the sequence passes"
    else
      pass "control: an interrupt enable of MMUART0 during the sequence fails"
    fi
    if msg="$("$PY" -I "$HERE/compare_trace.py" "$work/q.trace" --xml "$ROOT/$XML" --fabric-masked 119,123 --skip-io 2>&1)"; then
      fail "control: the trace passes against the sequence without the IO set-up"
    else
      pass "control: the trace fails against the sequence without the IO set-up ($msg)"
    fi
  else
    fail "the QEMU image does not end its run under QEMU"; tail -5 "$work/q.s2" >&2
  fi

  # the negative control: the image of the table with one value flipped
  if [ ! -f "$tampered_elf" ]; then
    fail "the image of the tampered table is missing ($tampered_elf)"
  elif qrun t "$tampered_elf" 'MSS INIT (OK|DONE|FAILED)'; then
    if msg="$("$PY" -I "$HERE/compare_trace.py" "$work/t.trace" --xml "$ROOT/$XML" --fabric-masked 119,123 2>&1)"; then
      fail "negative control: the image of a table with one value flipped passes the comparison"
    else
      case "$msg" in
        "write $((TAMPER + 1)) "*) pass "negative control: the table with Write $TAMPER flipped fails at write $((TAMPER + 1)): $msg" ;;
        *) fail "negative control: the comparison fails, but not at write $((TAMPER + 1)): $msg" ;;
      esac
    fi
  else
    fail "the image of the tampered table does not end its run under QEMU"
  fi

  # a ring that is too small: the dropped bytes are counted and said, the rest arrives
  if [ ! -f "$ring_elf" ]; then
    fail "the image with a small ring is missing ($ring_elf)"
  elif qrun r "$ring_elf" 'MSS INIT (OK|DONE|FAILED)' 3; then
    if msg="$("$PY" -I "$HERE/check_console.py" "$work/r.s2" mss_init_spike_qemu dropped 2>&1)"; then
      pass "a ring of 512 bytes: $msg"
    else
      fail "a ring of 512 bytes: $msg"
    fi
    if msg="$("$PY" -I "$HERE/compare_trace.py" "$work/r.trace" --xml "$ROOT/$XML" --fabric-masked 119,123 2>&1)"; then
      pass "the writes of the image with the small ring are the sequence too: $msg"
    else
      fail "the writes of the image with the small ring are the sequence too: $msg"
    fi
  else
    fail "the image with a small ring does not end its run under QEMU"
  fi

  # the board image: a poll that times out stops it (under QEMU the SGMII PLL never locks)
  b="$real/mss_init_spike.elf"
  if [ ! -f "$b" ]; then
    fail "the board image $b is missing"
  elif qrun b "$b" 'MSS INIT (OK|DONE|FAILED)'; then
    has b 'mss_init_spike: [0-9]+ table entries in 5 phases, a poll that times out stops the sequence' "the board image says that a timeout stops it"
    has b 'mss_init_spike: TIMEOUT entry [0-9]+: ' "the board image names the poll that timed out"
    has b 'mss_init_spike: MSS INIT FAILED' "the board image ends with MSS INIT FAILED"
    if msg="$("$PY" -I "$HERE/check_console.py" "$work/b.s0" silent 2>&1)"; then
      pass "after the stop MMUART0 stays silent (no status loop): $msg"
    else
      fail "after the stop MMUART0 stays silent: $msg"
    fi
    if msg="$("$PY" -I "$HERE/check_console.py" "$work/b.s2" mss_init_spike stopped 2>&1)"; then
      pass "after the stop the log is sent in order and the last line is MSS INIT FAILED: $msg"
    else
      fail "after the stop the log is sent in order and the last line is MSS INIT FAILED: $msg"
    fi
    grep -q 'phase 5 pll' "$work/b.s2" && fail "the board image stops at the first timeout (phase 5 is not reached)" \
      || pass "the board image stops at the first timeout (phase 5 is not reached)"
  else
    fail "the board image does not end its run under QEMU"
  fi
fi

# -- the XML of the build (MSS_XML of example.conf or of the environment, MSS_INIT_OPTS) ---------------------------
# The cases above and the comparison are bound to the committed table, made from $XML. These builds take the table
# from another XML (x: config/gen/mss_init_table.py into build/mss-init/<name>/, MSS_INIT_TABLE_DIR). They need the
# toolchain, so not in a prebuilt run.
if [ "$prebuilt" = 0 ] && [ "$build_ok" = 1 ]; then
  gen="$ROOT/build/mss-init/mss_init_spike-e51/mpfs_init_table.ads"
  sha_of () { sed -n 's/^ *"\([0-9a-f]\{64\}\)";$/\1/p' "$1" | head -n 1; }
  default_sha="$(sha_of "$TABLE")"
  rm -rf "$ROOT/build/mss-init"
  if xbuild "$work/default.log"; then
    [ ! -e "$gen" ] && grep -aq "$default_sha" "$real/mss_init_spike.elf" \
      && pass "default: no table is generated, the image has the committed table (the SHA-256 of icicle_es)" \
      || fail "default: no table is generated, the image has the committed table"
  else
    fail "default build"
  fi

  # another board by the environment
  if MSS_XML="$OTHER_XML" xbuild "$work/other.log"; then
    other_sha="$(sha_of "$gen")"
    [ -n "$other_sha" ] && [ "$other_sha" != "$default_sha" ] && grep -aq "$other_sha" "$real/mss_init_spike_qemu.elf" \
      && ! grep -aq "$default_sha" "$real/mss_init_spike_qemu.elf" \
      && pass "MSS_XML=$OTHER_XML: the generated table and the image carry its SHA-256, not that of icicle_es" \
      || fail "MSS_XML=$OTHER_XML: the generated table and the image carry its SHA-256, not that of icicle_es"
    "$PY" -I "$GEN" --xml "$OTHER_XML" --check --output "$gen" >/dev/null 2>&1 \
      && pass "the generated table is current for that XML (--check)" || fail "the generated table is current for that XML (--check)"
    cp "$real/mss_init_spike_qemu.elf" "$work/other.elf"
    if [ "$qemu_ok" = 1 ]; then
      if qrun o "$work/other.elf" 'MSS INIT (OK|DONE|FAILED)'; then
        has o "mss_init_spike_qemu: xml sha256 $other_sha" "the console of the image names the XML it was made from"
        if msg="$("$PY" -I "$HERE/compare_trace.py" "$work/o.trace" --xml "$ROOT/$OTHER_XML" --fabric-masked 119,123 2>&1)"; then
          pass "the writes of the image of $OTHER_XML are the sequence of that XML: $msg"
        else
          fail "the writes of the image of $OTHER_XML are the sequence of that XML: $msg"
        fi
        if "$PY" -I "$HERE/compare_trace.py" "$work/o.trace" --xml "$ROOT/$XML" --fabric-masked 119,123 >/dev/null 2>&1; then
          fail "control: the writes of the image of $OTHER_XML pass against the sequence of icicle_es"
        else
          pass "control: the writes of the image of $OTHER_XML fail against the sequence of icicle_es"
        fi
      else
        fail "the image of $OTHER_XML does not end its run under QEMU"
      fi
    fi
  else
    tail -5 "$work/other.log" >&2; fail "MSS_XML=$OTHER_XML builds"
  fi

  # the key of example.conf, and the environment wins over it
  conf="$EX/example.conf"; cp "$conf" "$work/example.conf.orig"
  restore_conf () { cp "$work/example.conf.orig" "$conf"; }
  sed -i "s#^MSS_XML=.*#MSS_XML=$OTHER_XML#" "$conf"
  if xbuild "$work/conf.log" && [ "$(sha_of "$gen")" = "$other_sha" ]; then
    pass "MSS_XML= in example.conf makes the table of that XML"
  else
    fail "MSS_XML= in example.conf makes the table of that XML"
  fi
  if MSS_XML="$XML" xbuild "$work/conf2.log" && [ "$(sha_of "$gen")" = "$default_sha" ]; then
    pass "MSS_XML in the environment wins over example.conf (icicle_es again)"
  else
    fail "MSS_XML in the environment wins over example.conf (icicle_es again)"
  fi
  restore_conf

  # --skip-io through MSS_INIT_OPTS, and the options without an XML
  if MSS_XML="$XML" MSS_INIT_OPTS="--skip-io" xbuild "$work/opts.log" && ! grep -q 'SYSREG.IOMUX0_CR' "$gen" \
     && "$PY" -I "$GEN" --xml "$XML" --skip-io --check --output "$gen" >/dev/null 2>&1; then
    pass "MSS_INIT_OPTS=--skip-io leaves the IO set-up out of the table"
  else
    fail "MSS_INIT_OPTS=--skip-io leaves the IO set-up out of the table"
  fi
  MSS_INIT_OPTS="--skip-io" xbuild "$work/opts2.log"; rc=$?
  [ $rc -ne 0 ] && grep -q 'MSS_INIT_OPTS needs MSS_XML' "$work/opts2.log" \
    && pass "MSS_INIT_OPTS without an XML stops the build" || fail "MSS_INIT_OPTS without an XML stops the build (exit $rc)"

  # an XML that the reader rejects: no image, the diagnostic of the reader, exit status 2
  head -c 300 "$ROOT/$XML" >"$work/truncated.xml"
  "$PY" -I - "$ROOT/$XML" "$work/width.xml" <<'EOF'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
i = text.index('name="WAY_ENABLE"')
old = 'offset="0" width="8"'
j = text.index(old, i)
open(sys.argv[2], "w", encoding="utf-8").write(text[:j] + 'offset="28" width="8"' + text[j + len(old):])
EOF
  for bad in "truncated:GEN-E040" "width:GEN-E048"; do
    f="$work/${bad%%:*}.xml"; code="${bad##*:}"
    rm -rf "$EX/obj-e51" "$EX/bin-e51"
    MSS_XML="$f" "$ROOT/x" build mss_init_spike --hart e51 >"$work/bad.log" 2>&1; rc=$?
    if [ $rc -eq 2 ] && grep -q "$code" "$work/bad.log" && [ ! -e "$EX/bin-e51" ]; then
      pass "a broken XML (${bad%%:*}) fails the build with exit 2, $code from the reader, and no image"
    else
      fail "a broken XML (${bad%%:*}) fails the build with exit 2, $code from the reader, and no image (exit $rc)"; tail -4 "$work/bad.log" >&2
    fi
  done
  rm -rf "$ROOT/build/mss-init"
  xbuild "$work/final.log" || fail "the default build after the cases"
fi

[ $fails -eq 0 ] || { echo "$fails failure(s)" >&2; exit 1; }
echo "all ok"
