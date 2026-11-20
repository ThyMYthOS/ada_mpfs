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
#   MSS_INIT_SPIKE_IMAGES=<dir> in a run that builds copies the tampered image there (tampered.elf).
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
  # the table says the same as the Python sequence: its entries are the steps of full(), the IfSet flattened
  "$PY" -I - "$TABLE" "$XML" <<'EOF' >"$work/entries.out" 2>&1 && pass "$(cat "$work/entries.out")" || fail "$(cat "$work/entries.out")"
import re, sys
sys.path[:0] = ["hw", "config/gen"]
import mss_init
import mss_init_table
steps = mss_init.full(mss_init.load(__import__("pathlib").Path(sys.argv[2])))
want = mss_init_table.entries_of(steps)
text = open(sys.argv[1]).read()
kinds = re.findall(r"\(Kind => (\w+), Address => 16#([0-9A-F_]+)#, Value => 16#([0-9A-F_]+)#,", text)
assert len(kinds) == len(want), f"{len(kinds)} entries in the table, {len(want)} from the steps"
for i, ((kind, address, value), entry) in enumerate(zip(kinds, want), 1):
    assert (kind, int(address.replace("_", ""), 16), int(value.replace("_", ""), 16)) == (entry.kind, entry.address, entry.value), f"entry {i} differs"
print(f"the {len(want)} entries of the table are the {len(steps)} steps of mss_init.full (kind, address, value)")
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
if [ "$prebuilt" = 1 ]; then
  tampered_elf="$keep/tampered.elf"
elif [ "$build_ok" = 1 ]; then
  if xbuild "$work/tampered.log" "$work/tampered"; then
    cp "$real/mss_init_spike_qemu.elf" "$work/tampered.elf"
    if [ -n "${MSS_INIT_SPIKE_IMAGES:-}" ]; then mkdir -p "$keep" && cp "$work/tampered.elf" "$keep/tampered.elf"; fi
    pass "the image of the tampered table builds"
  else
    tail -5 "$work/tampered.log" >&2; fail "the image of the tampered table builds"
  fi
  tampered_elf="$work/tampered.elf"
  if xbuild "$work/real.log"; then
    pass "the board image and the QEMU image build ($(riscv64-elf-size -B "$real/mss_init_spike.elf" | awk 'NR == 2 { print $1 " text, " $2 " data, " $3 " bss" }'))"
  else
    tail -5 "$work/real.log" >&2; fail "the images build"
  fi
fi

# qrun <name> <elf> <regexp>: boots the image with the register trace; the serial ports are $work/<name>.s0 to .s4
# and the trace $work/<name>.trace. Returns 0 if the regexp is on port 0 within 60 s.
qrun () {
  local name="$1" elf="$2" re="$3" pid i ok=1
  "$QEMU" -M microchip-icicle-kit -smp 5 -m 2G -display none -monitor none -bios none -kernel "$elf" -no-reboot \
    -serial "file:$work/$name.s0" -serial "file:$work/$name.s1" -serial "file:$work/$name.s2" \
    -serial "file:$work/$name.s3" -serial "file:$work/$name.s4" \
    -trace memory_region_ops_read -trace memory_region_ops_write -D "$work/$name.trace" \
    >"$work/$name.qemu" 2>&1 &
  pid=$!
  for i in $(seq 1 120); do
    if grep -Eq "$re" "$work/$name.s0" 2>/dev/null; then ok=0; break; fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.5
  done
  sleep 0.3
  kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  return $ok
}

# has <name> <regexp> <what>: the console of the run has a line
has () {
  grep -Eq "$2" "$work/$1.s0" && pass "$3" || { fail "$3 (no /$2/ on the console)"; sed 's/^/      | /' "$work/$1.s0" | tail -20 >&2; }
}

if [ "$qemu_ok" = 1 ]; then
  q="$real/mss_init_spike_qemu.elf"
  if [ ! -f "$q" ]; then
    fail "the QEMU image $q is missing"
  elif qrun q "$q" 'MSS INIT (OK|DONE|FAILED)'; then
    has q 'mss_init_spike_qemu: [0-9]+ table entries in 5 phases, a poll that times out is reported' "the console names the entries, the phases and the policy"
    has q 'mss_init_spike_qemu: xml sha256 [0-9a-f]{64}' "the console names the XML by its SHA-256"
    for ph in 'phase 1 refclk' 'phase 2 io' 'phase 3 mssio' 'phase 4 sgmii' 'phase 5 pll'; do
      has q "mss_init_spike_qemu: $ph: entries [0-9]+-[0-9]+, [0-9]+ run, [0-9]+ poll timeout" "the console has a line for the $ph"
    done
    has q 'mss_init_spike_qemu: TIMEOUT entry [0-9]+: .*, wanted 0x' "a poll that timed out is named with the word it read"
    has q 'mss_init_spike_qemu: mtime 0x[0-9a-f]{8} then 0x[0-9a-f]{8} after 100 us by mcycle: advancing' "mtime advances between two reads"
    has q 'mss_init_spike_qemu: MSS PLL: PLL_CTRL 0x[0-9a-f]{8}, LOCK [01]' "the console reads the PLL status back"
    has q 'mss_init_spike_qemu: MSS INIT DONE WITH TIMEOUTS' "the QEMU image reports its timeouts and ends"
    if msg="$("$PY" -I "$HERE/compare_trace.py" "$work/q.trace" --xml "$ROOT/$XML" 2>&1)"; then
      pass "the writes of the QEMU image are the sequence of hw/mss_init.py: $msg"
    else
      fail "the writes of the QEMU image are the sequence of hw/mss_init.py: $msg"
    fi
    # controls: the comparison is not vacuous
    if msg="$("$PY" -I "$HERE/compare_trace.py" "$work/q.trace" --xml "$ROOT/$OTHER_XML" 2>&1)"; then
      fail "control: the trace passes against the XML of another board"
    else
      pass "control: the trace fails against the XML of another board ($msg)"
    fi
    grep -v 'addr 0x3e001020 ' "$work/q.trace" >"$work/q-dropped.trace"
    if msg="$("$PY" -I "$HERE/compare_trace.py" "$work/q-dropped.trace" --xml "$ROOT/$XML" 2>&1)"; then
      fail "control: a trace with a write left out passes"
    else
      pass "control: a trace with a write left out fails ($msg)"
    fi
    if msg="$("$PY" -I "$HERE/compare_trace.py" "$work/q.trace" --xml "$ROOT/$XML" --skip-io 2>&1)"; then
      fail "control: the trace passes against the sequence without the IO set-up"
    else
      pass "control: the trace fails against the sequence without the IO set-up ($msg)"
    fi
  else
    fail "the QEMU image does not end its run under QEMU"; tail -5 "$work/q.s0" >&2
  fi

  # the negative control: the image of the table with one value flipped
  if [ ! -f "$tampered_elf" ]; then
    fail "the image of the tampered table is missing ($tampered_elf)"
  elif qrun t "$tampered_elf" 'MSS INIT (OK|DONE|FAILED)'; then
    if msg="$("$PY" -I "$HERE/compare_trace.py" "$work/t.trace" --xml "$ROOT/$XML" 2>&1)"; then
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

  # the board image: a poll that times out stops it (under QEMU the SGMII PLL never locks)
  b="$real/mss_init_spike.elf"
  if [ ! -f "$b" ]; then
    fail "the board image $b is missing"
  elif qrun b "$b" 'MSS INIT (OK|DONE|FAILED)'; then
    has b 'mss_init_spike: [0-9]+ table entries in 5 phases, a poll that times out stops the sequence' "the board image says that a timeout stops it"
    has b 'mss_init_spike: TIMEOUT entry [0-9]+: ' "the board image names the poll that timed out"
    has b 'mss_init_spike: MSS INIT FAILED' "the board image ends with MSS INIT FAILED"
    grep -q 'phase 5 pll' "$work/b.s0" && fail "the board image stops at the first timeout (phase 5 is not reached)" \
      || pass "the board image stops at the first timeout (phase 5 is not reached)"
  else
    fail "the board image does not end its run under QEMU"
  fi
fi

[ $fails -eq 0 ] || { echo "$fails failure(s)" >&2; exit 1; }
echo "all ok"
