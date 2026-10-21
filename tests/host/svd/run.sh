#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Tests for the SVD process: the committed SVD is reproducible, and each rule of
# `./x svd check` (XSD, mandatory headers, patch targets, local interrupt schema)
# rejects a violation. Works on a copy of the repository parts involved.
# Exits non-zero on any failure.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fails=0
. "$ROOT/tools/mpfs-env.sh"
mpfs_toolchain_on_path 2>/dev/null || true
mpfs_find_python

pass () { echo "ok:   $1"; }
fail () { echo "FAIL: $1" >&2; fails=$((fails + 1)); }

tmp="$(mktemp -d)"
trap 'rm -r "$tmp"' EXIT

# fresh <name>: a pristine copy of tools/, hw/ and svd/ in $tmp/<name>, becomes $W
fresh () {
  W="$tmp/$1"
  mkdir -p "$W"
  cp -r "$ROOT/tools" "$ROOT/hw" "$ROOT/svd" "$W/"
  }

# expect_check <description> <pass|fail> [pattern]: run svd.py check in $W
expect_check () {
  local desc="$1" want="$2" pat="${3:-}" out rc
  out="$(cd "$W" && "$MPFS_PYTHON" tools/svd.py check 2>&1)"; rc=$?
  if [ "$want" = pass ] && [ $rc -eq 0 ]; then pass "$desc"
  elif [ "$want" = fail ] && [ $rc -ne 0 ] && { [ -z "$pat" ] || printf '%s' "$out" | grep -q "$pat"; }; then pass "$desc"
  else fail "$desc (exit $rc: $(printf '%s' "$out" | head -3 | tr '\n' ' '))"; fi
}

# the merge reproduces the committed hash
fresh clean
expect_check "check passes: the merged SVD has the recorded hash" pass
( cd "$W" && "$MPFS_PYTHON" tools/svd.py merge >/dev/null && cmp -s svd/PolarfireSoC.sha256 "$ROOT/svd/PolarfireSoC.sha256" ) \
  && pass "merge records the committed hash" || fail "merge records the committed hash"

# ensure regenerates a missing or modified SVD and leaves a current one alone
fresh ensure
( cd "$W" && "$MPFS_PYTHON" tools/svd.py ensure >/dev/null && cmp -s build/svd/PolarfireSoC.svd "$tmp/clean/build/svd/PolarfireSoC.svd" ) \
  && pass "ensure builds a missing SVD" || fail "ensure builds a missing SVD"
echo "<!-- x -->" >> "$W/build/svd/PolarfireSoC.svd"
( cd "$W" && "$MPFS_PYTHON" tools/svd.py ensure >/dev/null && cmp -s build/svd/PolarfireSoC.svd "$tmp/clean/build/svd/PolarfireSoC.svd" ) \
  && pass "ensure rebuilds an SVD with a different hash" || fail "ensure rebuilds an SVD with a different hash"
out="$(cd "$W" && "$MPFS_PYTHON" tools/svd.py ensure 2>&1)"
[ -z "$out" ] && pass "ensure is silent when the hash fits" || fail "ensure is silent when the hash fits ($out)"
# ... and needs no PyYAML: a module of that name that cannot be imported is put first on the path
mkdir -p "$tmp/noyaml"; echo 'raise ImportError("PyYAML is not installed")' > "$tmp/noyaml/yaml.py"
out="$(cd "$W" && PYTHONPATH="$tmp/noyaml" "$MPFS_PYTHON" tools/svd.py ensure 2>&1)"
[ $? -eq 0 ] && [ -z "$out" ] && pass "ensure of a current SVD needs no PyYAML" || fail "ensure of a current SVD needs no PyYAML ($out)"
out="$(cd "$W" && PYTHONPATH="$tmp/noyaml" "$MPFS_PYTHON" tools/svd.py merge 2>&1)"
[ $? -ne 0 ] && printf '%s' "$out" | grep -q 'PyYAML' && pass "merge without PyYAML says so" || fail "merge without PyYAML says so ($out)"

# probe without a peripheral reads all of them
all="$("$MPFS_PYTHON" "$ROOT/hw/svd_probe.py" --svd "$tmp/clean/build/svd/PolarfireSoC.svd" --list 2>/dev/null | wc -l)"
one="$("$MPFS_PYTHON" "$ROOT/hw/svd_probe.py" --svd "$tmp/clean/build/svd/PolarfireSoC.svd" --list CLINT 2>/dev/null | wc -l)"
[ "$all" -gt "$one" ] && [ "$all" = "$("$MPFS_PYTHON" "$ROOT/hw/svd_probe.py" --svd "$tmp/clean/build/svd/PolarfireSoC.svd" --list --all 2>/dev/null | wc -l)" ] \
  && pass "probe without a peripheral lists all registers" || fail "probe without a peripheral lists all registers"

fresh stale
sed -i 's/^./g/' "$W/svd/PolarfireSoC.sha256"
expect_check "a wrong recorded hash is rejected" fail "does not match"

fresh changed
sed -i '0,/description: .* Controller/s//description: changed/' "$W/svd/base/envm.yaml"
expect_check "a changed fragment changes the hash" fail "does not match"

fresh nostatus
sed -i '/^# status:/d' "$W/svd/additions/clint.yaml"
expect_check "a missing status header is rejected" fail "status"

fresh badstatus
sed -i 's/^# status:.*/# status: maybe/' "$W/svd/additions/plic.yaml"
expect_check "an invalid status is rejected" fail "status"

fresh notincluded
cp "$W/svd/additions/clint.yaml" "$W/svd/additions/extra.yaml"
expect_check "an addition missing in device.yaml is rejected" fail "does not include"

fresh badtarget
printf '# source: test\n# status: unverified\n# owner: test\nNOSUCH:\n  _modify:\n    description: x\n' > "$W/svd/patches/NOSUCH.yaml"
sed -i 's#^  - additions/plic.yaml#  - patches/NOSUCH.yaml\n  - additions/plic.yaml#' "$W/svd/device.yaml"
expect_check "a patch for a missing peripheral is rejected" fail "no peripheral matches"

fresh patchok
printf '# source: test\n# status: unverified\n# owner: test\nSYSREG:\n  _add:\n    TESTREG:\n      description: patched\n      addressOffset: 0x7F0\n' > "$W/svd/patches/SYSREG.yaml"
sed -i 's#^  - additions/plic.yaml#  - patches/SYSREG.yaml\n  - additions/plic.yaml#' "$W/svd/device.yaml"
( cd "$W" && "$MPFS_PYTHON" tools/svd.py merge >/dev/null 2>&1 && grep -q '<name>TESTREG</name>' build/svd/PolarfireSoC.svd ) \
  && pass "a valid patch is applied" || fail "a valid patch is applied"

# the committed patches take effect: a mask and a reset value; the ATHENA offset comes from the import
python3 -I - "$tmp/clean/build/svd/PolarfireSoC.svd" <<'PY' && pass "the committed patches are applied" || fail "the committed patches are applied"
import sys
from xml.etree import ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
def reg(periph, name):
    p = next(p for p in root.iter("peripheral") if p.findtext("name") == periph)
    return next(r for r in p.iter("register") if r.findtext("name") == name)
r = reg("SCB_REGS", "SOFT_RESET")
assert int(r.findtext("resetMask"), 0) == 0 and int(r.findtext("resetValue"), 0) == 0
assert int(reg("SYSREG", "MSS_BUILD").findtext("resetMask"), 0) == 0
assert int(reg("ATHENA", "CSRMAIN").findtext("addressOffset"), 0) == 0
PY

fresh dupirq
sed -i '0,/local: 3$/s//local: 2/' "$W/svd/additions/local_interrupts.yaml"
expect_check "a duplicate local interrupt is rejected" fail "used twice"

fresh badxsd
sed -i 's#<revision>r1p0</revision>#<revision>1.0</revision>#' "$W/svd/base/device.svd"
expect_check "an XSD violation is rejected" fail "xmllint failed"

fresh noaddr
sed -i '0,/baseAddress:/{/baseAddress:/d}' "$W/svd/base/envm.yaml"
expect_check "a peripheral without base address is rejected" fail "baseAddress"

# svd_probe against a fake OpenOCD telnet port: MSIP1 differs, mtimecmp/mtime cannot be read
"$MPFS_PYTHON" -I - "$ROOT" "$tmp/clean/build/svd/PolarfireSoC.svd" <<'PY' && pass "svd_probe reports ok, mismatch and unreadable" || fail "svd_probe reports ok, mismatch and unreadable"
import re, socket, subprocess, sys, threading
root = sys.argv[1]
srv = socket.socket(); srv.bind(("127.0.0.1", 0)); srv.listen(1)
port = srv.getsockname()[1]
TABLE = ("    TargetName         Type       Endian TapName            State\r\n"
         "--  ------------------ ---------- ------ ------------------ ------------\r\n"
         " 0* mpfs.hart0_e51     riscv      little mpfs.cpu           halted")
seen = []
def md(line):
    m = re.match(r"md([bhwd]) 0x([0-9A-F]+) (\d+)$", line)
    width = {"b": 1, "h": 2, "w": 4, "d": 8}[m.group(1)]
    addr, count = int(m.group(2), 16), int(m.group(3))
    if 0x2004000 <= addr < 0x10000000:
        return "invalid"
    return "\n".join(f"0x{addr + i * width:08x}: {5 if addr + i * width == 0x2000004 else 0:0{2 * width}x}" for i in range(count))
def serve():
    c, _ = srv.accept()
    c.sendall(b"Open On-Chip Debugger\r\n> ")
    buf = b""
    while True:
        d = c.recv(4096)
        if not d: break
        buf += d
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            if not line.startswith(b"echo svd_probe_"): seen.append(line.decode())  # not the frame of a command
            r = md(line.decode()) if line.startswith(b"md") else TABLE if line == b"targets" else line[5:].decode() if line.startswith(b"echo ") else ""
            c.sendall(line + b"\r\n" + (r.encode() + b"\r\n" if r else b"") + b"> ")
threading.Thread(target=serve, daemon=True).start()
r = subprocess.run([sys.executable, root + "/hw/svd_probe.py", "--svd", sys.argv[2], "--port", str(port), "--skip-file", "/dev/null", "CLINT"],
                   capture_output=True, text=True)  # no rules: MSIP1 is a mismatch, not state
out = [l for l in r.stdout.splitlines() if l.split()[0] in ("ok", "mismatch", "state", "noref", "unreadable", "skipped")]  # not the header
assert r.returncode == 1, r
kinds = [l.split()[0] for l in out]
assert kinds == ["ok", "mismatch", "ok", "ok", "ok"] + ["unreadable"] * 5 + ["skipped"], out
assert "'invalid'" in out[5] and "not read after" in out[6], out
summary = [l for l in r.stdout.splitlines() if l.startswith("svd_probe: 11 register(s)")]
assert len(summary) == 1 and "11 register(s), 6 not ok, 1 skipped, 0 readAction, " in summary[0] and '0 noref' in summary[0] and '0 state' in summary[0] and summary[0].endswith('0 excluded'), r.stdout
assert seen[:2] == ["targets mpfs.hart0_e51", "halt"] and "riscv set_prefer_sba off" in seen, seen
assert [l for l in seen if l.startswith("mdw 0x2000000")] == ["mdw 0x2000000 5"] and seen[-1] == "resume", seen  # the five MSIP registers need one command
PY

# --enable-clocks writes the two SYSREG registers before the first read; --skip leaves a peripheral out
"$MPFS_PYTHON" -I - "$ROOT" "$tmp/clean/build/svd/PolarfireSoC.svd" <<'PY' && pass "svd_probe enables clocks and skips peripherals" || fail "svd_probe enables clocks and skips peripherals"
import socket, subprocess, sys, threading
root = sys.argv[1]
srv = socket.socket(); srv.bind(("127.0.0.1", 0)); srv.listen(1)
port = srv.getsockname()[1]
TABLE = ("    TargetName         Type       Endian TapName            State\r\n"
         "--  ------------------ ---------- ------ ------------------ ------------\r\n"
         " 0* mpfs.hart0_e51     riscv      little mpfs.cpu           halted")
seen = []
def serve():
    c, _ = srv.accept()
    c.sendall(b"> ")
    buf = b""
    while True:
        d = c.recv(4096)
        if not d: break
        buf += d
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            if not line.startswith(b"echo svd_probe_"): seen.append(line.decode())  # not the frame of a command
            r = TABLE if line == b"targets" else line[5:].decode() if line.startswith(b"echo ") else ""
            c.sendall(line + b"\r\n" + (r.encode() + b"\r\n" if r else b"") + b"> ")
threading.Thread(target=serve, daemon=True).start()
r = subprocess.run([sys.executable, root + "/hw/svd_probe.py", "--svd", sys.argv[2], "--port", str(port),
                    "--enable-clocks", "--skip", "CLINT,PLIC", "SYSREG", "CLINT"], capture_output=True, text=True)
assert r.returncode == 1 and "register(s)" in r.stdout, r
mww = [l for l in seen if l.startswith("mww")]
assert len(mww) == 2 and mww[0].endswith(" 0xFFFFFFFF") and mww[1].endswith(" 0x0"), seen
assert seen.index(mww[1]) < next(i for i, l in enumerate(seen) if l.startswith("md") and i > seen.index(mww[1])), seen
assert not any("0x2000000" in l or "0xC000000" in l for l in seen), seen
r = subprocess.run([sys.executable, root + "/hw/svd_probe.py", "--svd", sys.argv[2], "--skip", "NOPE", "--list"],
                   capture_output=True, text=True)
assert r.returncode == 2 and "NOPE" in r.stderr, r
PY

# a peripheral that does not answer aborts the probe with exit code 2
"$MPFS_PYTHON" -I - "$ROOT" "$tmp/clean/build/svd/PolarfireSoC.svd" <<'PY' && pass "svd_probe stops when OpenOCD does not answer" || fail "svd_probe stops when OpenOCD does not answer"
import socket, subprocess, sys, threading
root = sys.argv[1]
srv = socket.socket(); srv.bind(("127.0.0.1", 0)); srv.listen(1)
port = srv.getsockname()[1]
TABLE = ("    TargetName         Type       Endian TapName            State\r\n"
         "--  ------------------ ---------- ------ ------------------ ------------\r\n"
         " 0* mpfs.hart0_e51     riscv      little mpfs.cpu           halted")
def serve():
    c, _ = srv.accept()
    c.sendall(b"> ")
    buf, stuck = b"", False
    while True:
        d = c.recv(4096)
        if not d: break
        buf += d
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            if line.startswith(b"mdw 0x2000000"):
                stuck = True
                continue  # the first CLINT register does not answer
            if stuck and line.startswith(b"echo svd_probe_end_"):
                stuck = False  # nor does the echo that closes it
                continue
            if line.startswith(b"md"):
                c.sendall(line + b"\r\n0x20000000: 00000000\r\n> ")
            else:
                r = TABLE if line == b"targets" else line[5:].decode() if line.startswith(b"echo ") else ""
                c.sendall(line + b"\r\n" + (r.encode() + b"\r\n" if r else b"") + b"> ")
threading.Thread(target=serve, daemon=True).start()
r = subprocess.run([sys.executable, root + "/hw/svd_probe.py", "--svd", sys.argv[2], "--port", str(port),
                    "--timeout", "1", "CLINT"], capture_output=True, text=True)
assert r.returncode == 2 and "probably hung" in r.stderr and "0x02000000" in r.stderr, r
PY

# svd_probe against stand-ins that die, refuse the resume, answer with errors, ...
probe_out="$("$MPFS_PYTHON" "$ROOT/tests/host/svd/probe_test.py" "$tmp/clean/build/svd/PolarfireSoC.svd" 2>&1)"; probe_rc=$?
while IFS= read -r line; do
  case "$line" in
    "ok:   "*)   pass "svd_probe: ${line#ok:   }" ;;
    "FAIL: "*)   fail "svd_probe: ${line#FAIL: }" ;;
  esac
done <<< "$probe_out"
[ "$probe_rc" -eq 0 ] || [ "$fails" -gt 0 ] || fail "svd_probe stand-in tests ended with exit $probe_rc"

echo "summary: $fails failure(s)"
[ "$fails" -eq 0 ]
