#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Tests for the trimmed bb-runtimes fork, the runtime packs and the licenses of the fork:
#  - build_rts.py accepts only the board mpfs with a hart class, writes the ISA switches of the
#    class and no linker script, and its output does not depend on the order in which the file
#    system lists a directory;
#  - no pack is committed, packs.sha256 is in the format of `make_packs.sh --update`, `--ensure`
#    generates the six packs, finds them current, and regenerates a missing, corrupt, other or
#    stale one (with a warning if the sources do not match the hash file);
#  - `--check` (regenerated == committed hashes) passes, also under another umask, time zone and
#    working directory, and fails for a changed, a missing, a stale and an unformatted hash, and
#    for a missing hash file;
#  - the packs hold sources and licenses only, with sorted entries, fixed owner and time;
#  - compare_toolchain.sh finds a changed, a missing and an added common source and an FPU source
#    that is not the soft-float one, while a changed port unit is allowed (skipped when the pinned
#    GNAT is not installed: ./x toolchain install gnat);
#  - the licenses: the Python files of the fork are GPL-3.0-or-later without the exception, the
#    files annotated LicenseRef-Ada-RM-permissive in REUSE.toml are exactly the files whose notice
#    is the Ada Reference Manual paragraph and no GPL paragraph.
# Exits non-zero on any failure.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CRATE="$ROOT/crates/mpfs_rts"
BBRT="$ROOT/crates/bb-runtimes"
MAKE="$CRATE/make_packs.sh"
fails=0
export PYTHONDONTWRITEBYTECODE=1

pass () { echo "ok:   $1"; }
fail () { echo "FAIL: $1" >&2; fails=$((fails + 1)); }
skip () { echo "skip: $1"; }

# expect_rc <description> <expected exit code: 0|nonzero|N> <command...>
expect_rc () {
  local desc="$1" want="$2"; shift 2
  "$@" >/dev/null 2>&1
  local rc=$?
  if { [ "$want" = 0 ] && [ $rc -eq 0 ]; } || { [ "$want" = nonzero ] && [ $rc -ne 0 ]; } || [ "$want" = "$rc" ]; then
    pass "$desc"
  else
    fail "$desc (exit $rc, wanted $want)"
  fi
}

# expect_out <description> <expected exit code> <text that must be in stderr+stdout> <command...>
expect_out () {
  local desc="$1" want="$2" text="$3"; shift 3
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [ "$want" = nonzero ] && [ $rc -eq 0 ]; then fail "$desc (exit 0)"; return; fi
  if [ "$want" != nonzero ] && [ "$rc" != "$want" ]; then fail "$desc (exit $rc, wanted $want)"; return; fi
  case "$out" in *"$text"*) pass "$desc" ;; *) fail "$desc (no \"$text\" in: $out)" ;; esac
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# -- build_rts.py: the board mpfs with a hart class, nothing else ---------------------------
BUILD="python3 $BBRT/build_rts.py"
expect_rc "build_rts.py: mpfs --hart u54"      0       $BUILD --hart u54 -o "$work/b1" mpfs
expect_rc "build_rts.py: mpfs --hart e51"      0       $BUILD --hart e51 -o "$work/b2" mpfs
expect_rc "build_rts.py: the old board polarfiresoc is rejected" nonzero $BUILD --hart u54 -o "$work/b3" polarfiresoc
expect_rc "build_rts.py: spike is rejected"    nonzero $BUILD --hart u54 -o "$work/b3" spike
expect_rc "build_rts.py: a generic board (rv64imafdc) is rejected" nonzero $BUILD --hart u54 -o "$work/b3" rv64imafdc
expect_rc "build_rts.py: mpfs without --hart is rejected" nonzero $BUILD -o "$work/b3" mpfs
expect_rc "build_rts.py: an unknown hart class is rejected" nonzero $BUILD --hart e52 -o "$work/b3" mpfs
expect_rc "build_rts.py: no board is rejected" nonzero $BUILD --hart u54 -o "$work/b3"
[ ! -e "$work/b3" ] && pass "build_rts.py: a rejected call generates nothing" || fail "build_rts.py: a rejected call generates nothing"
# The generated runtime.xml has the ISA of the hart class, no loader script and no -T.
for h in "e51:rv64imac_zicsr_zifencei:lp64" "u54:rv64imafdc_zicsr_zifencei:lp64d"; do
  hart="${h%%:*}"; rest="${h#*:}"; march="${rest%%:*}"; mabi="${rest#*:}"
  b="$work/b-$hart"
  python3 "$BBRT/build_rts.py" --hart "$hart" -o "$b" mpfs >/dev/null 2>&1
  for p in light light-tasking embedded; do
    x="$b/$p-mpfs/runtime.xml"
    if grep -q -- "\"-march=$march\", \"-mabi=$mabi\"" "$x" 2>/dev/null; then pass "$p $hart: runtime.xml has -march=$march -mabi=$mabi"
    else fail "$p $hart: runtime.xml has -march=$march -mabi=$mabi"; fi
    if grep -q -- '"-T"' "$x" 2>/dev/null; then fail "$p $hart: runtime.xml has no -T"; else pass "$p $hart: runtime.xml has no -T"; fi
    if [ -z "$(find "$b/$p-mpfs" -name '*.ld' | head -1)" ]; then pass "$p $hart: no linker script in the runtime"; else fail "$p $hart: no linker script in the runtime"; fi
  done
done
# The output does not depend on the order in which the file system lists a directory (the
# languages of runtime_build.gpr followed it once: "C", "Asm_Cpp" here, the reverse on a CI runner).
cat > "$work/reversed.py" <<'PY'
import os, runpy, sys
real = os.listdir
os.listdir = lambda p=".": sorted(real(p), reverse=True)
root = sys.argv[1]
sys.path.insert(0, root)
sys.argv = [root + "/build_rts.py"] + sys.argv[2:]
runpy.run_path(root + "/build_rts.py", run_name="__main__")
PY
for hart in e51 u54; do
  python3 "$work/reversed.py" "$BBRT" --hart "$hart" -o "$work/rev-$hart" mpfs >/dev/null 2>&1
  if diff -r "$work/b-$hart" "$work/rev-$hart" >/dev/null 2>&1; then pass "build_rts.py $hart: the output does not depend on the directory order"
  else fail "build_rts.py $hart: the output does not depend on the directory order"; fi
done

# -- the licenses of the fork ----------------------------------------------------------------
# (the tag is assembled so that reuse does not read this file's own text as a header)
tag='SPDX-License''-Identifier'
for f in build_rts.py riscv/__init__.py riscv/mpfs/__init__.py; do
  if grep -q "^# $tag: GPL-3.0-or-later\$" "$BBRT/$f"; then pass "$f: GPL-3.0-or-later, no exception"
  else fail "$f: GPL-3.0-or-later, no exception"; fi
done
python3 -I - "$ROOT" <<'PY'
import re, sys, tomllib
from pathlib import Path
root = Path(sys.argv[1])
bb = root / "crates" / "bb-runtimes"
para = ["-- This specification is derived from the Ada Reference Manual for use with --",
        "-- GNAT.  In accordance with the copyright of that document, you can freely --",
        "-- copy and modify this specification,  provided that if you redistribute a --",
        "-- modified version,  any changes that you have made are clearly indicated. --"]
expected = set()
for f in bb.rglob("*"):
    if not f.is_file() or f.suffix not in (".ads", ".adb"):
        continue
    t = f.read_text(errors="replace")
    if all(p in t for p in para) and "General Public License" not in t:
        expected.add(f.relative_to(root).as_posix())
listed = set()
for a in tomllib.loads((root / "REUSE.toml").read_text())["annotations"]:
    if a["SPDX-License-Identifier"] == "LicenseRef-Ada-RM-permissive":
        listed |= set(a["path"])
ok = True
def check(desc, cond, extra=""):
    global ok
    print(("ok:   " if cond else "FAIL: ") + desc + (("" if cond else " " + extra)), file=sys.stdout if cond else sys.stderr)
    ok = ok and cond
check("RM-permissive: the files of REUSE.toml are the files with the RM paragraph and no GPL paragraph (%d)" % len(listed),
      listed == expected, "only in REUSE.toml: %s; only in the sources: %s" % (sorted(listed - expected)[:5], sorted(expected - listed)[:5]))
check("RM-permissive: 73 files", len(listed) == 73, str(len(listed)))
text = (root / "LICENSES" / "LicenseRef-Ada-RM-permissive.txt").read_text()
check("RM-permissive: LICENSES/LicenseRef-Ada-RM-permissive.txt has the paragraph word for word", all(p in text for p in para))
# what is annotated with the exception: no Python, and every Ada file with a GPL paragraph that is not RM-only
gpl = [a for a in tomllib.loads((root / "REUSE.toml").read_text())["annotations"]
       if a["SPDX-License-Identifier"] == "GPL-3.0-or-later WITH GCC-exception-3.1"]
paths = [p for a in gpl for p in a["path"]]
check("the exception is not annotated on the Python generator", not any("support" in p or p.endswith(".py") for p in paths), str(paths))
sys.exit(0 if ok else 1)
PY
[ $? -eq 0 ] || fails=$((fails + 1))

# -- no pack is committed; the hash file -------------------------------------------------------
if [ -d "$ROOT/.git" ] || [ -f "$ROOT/.git" ]; then
  tracked="$(git -C "$ROOT" ls-files -- '*.tar.zst' '*.tar' 2>/dev/null | grep -c . || true)"
  [ "$tracked" = 0 ] && pass "no pack (.tar.zst or .tar) is committed" || fail "no pack (.tar.zst or .tar) is committed ($tracked tracked)"
else
  skip "no pack committed: not a git checkout"
fi
HASHES="$CRATE/packs.sha256"
if [ "$(grep -Ec '^[0-9a-f]{64}  (light|light-tasking|embedded)-(e51|u54)\.tar$' "$HASHES")" = 6 ] && [ "$(wc -l < "$HASHES")" = 6 ]; then
  pass "packs.sha256: six lines '<sha256>  <profile>-<hart>.tar'"
else fail "packs.sha256: six lines '<sha256>  <profile>-<hart>.tar'"; fi
if [ "$(awk '{ print $2 }' "$HASHES")" = "$(awk '{ print $2 }' "$HASHES" | LC_ALL=C sort)" ]; then pass "packs.sha256: sorted by name"; else fail "packs.sha256: sorted by name"; fi

if ! command -v zstd >/dev/null 2>&1 || ! tar --version 2>&1 | grep -q 'GNU tar'; then
  skip "packs: zstd or GNU tar is not installed"
else
  PK="$work/packs"

  # --ensure: generates the six, finds them current, regenerates what is missing, corrupt, other
  # or stale.
  out="$(bash "$MAKE" --ensure --out "$PK" 2>&1)"; rc=$?
  n="$(find "$PK" -name '*.tar.zst' 2>/dev/null | wc -l)"
  if [ $rc -eq 0 ] && [ "$n" -eq 6 ] && [ "$(printf '%s\n' "$out" | grep -c 'regenerating')" = 6 ]; then pass "make_packs.sh --ensure: generates the six packs"
  else fail "make_packs.sh --ensure: generates the six packs (exit $rc, $n packs): $out"; fi
  for cell in $(awk '{ sub(/\.tar$/, "", $2); print $2 }' "$HASHES"); do
    want="$(awk -v n="$cell.tar" '$2 == n { print $1 }' "$HASHES")"
    have="$(zstd -dc "$PK/$cell.tar.zst" 2>/dev/null | sha256sum | cut -d' ' -f1)"
    [ "$want" = "$have" ] && pass "pack $cell: the tar stream has the hash of packs.sha256" || fail "pack $cell: the tar stream has the hash of packs.sha256"
  done
  out="$(bash "$MAKE" --ensure --out "$PK" 2>&1)"; rc=$?
  if [ $rc -eq 0 ] && [ "$(printf '%s\n' "$out" | grep -c 'has the recorded hash')" = 6 ] && ! printf '%s\n' "$out" | grep -q regenerating; then pass "make_packs.sh --ensure: current packs are left alone"
  else fail "make_packs.sh --ensure: current packs are left alone: $out"; fi
  keep="$(sha256sum "$PK/light-e51.tar.zst")"
  rm "$PK/light-u54.tar.zst"
  printf 'x' >> "$PK/embedded-e51.tar.zst"
  printf 'not a pack' | zstd -q -c > "$PK/light-tasking-u54.tar.zst"
  out="$(bash "$MAKE" --ensure --out "$PK" 2>&1)"; rc=$?
  if [ $rc -eq 0 ] && [ "$(printf '%s\n' "$out" | grep -c 'regenerating')" = 3 ] && [ "$(sha256sum "$PK/light-e51.tar.zst")" = "$keep" ] \
     && [ "$(zstd -dc "$PK/light-u54.tar.zst" | sha256sum | cut -d' ' -f1)" = "$(awk '$2 == "light-u54.tar" { print $1 }' "$HASHES")" ]; then
    pass "make_packs.sh --ensure: a missing, a corrupt and another pack are regenerated, the others are not touched"
  else fail "make_packs.sh --ensure: a missing, a corrupt and another pack are regenerated, the others are not touched: $out"; fi
  # a hash file that does not match the sources: regenerate, warn, exit 0 (as tools/svd.py ensure)
  sed 's/^[0-9a-f]\{64\}  light-u54.tar$/0000000000000000000000000000000000000000000000000000000000000000  light-u54.tar/' "$HASHES" > "$work/other.sha256"
  out="$(bash "$MAKE" --ensure --out "$PK" --hashes "$work/other.sha256" --cells light-u54 2>&1)"; rc=$?
  case "$out" in
    *"warning: the sources do not match"*"light-u54"*) [ $rc -eq 0 ] && pass "make_packs.sh --ensure: a hash file that differs from the sources warns and exits 0" || fail "make_packs.sh --ensure: warns and exits 0 (exit $rc)" ;;
    *) fail "make_packs.sh --ensure: a hash file that differs from the sources warns: $out" ;;
  esac

  # Contents: sources and the two license texts, no objects; sorted entries, owner 0:0, fixed time.
  for cell in $(awk '{ sub(/\.tar$/, "", $2); print $2 }' "$HASHES"); do
    f="$PK/$cell.tar.zst"
    [ -f "$f" ] || continue
    lst="$work/list-$cell"
    zstd -dc "$f" | tar -tvf - --numeric-owner > "$lst" 2>/dev/null
    names="$(awk '{ print $NF }' "$lst")"
    case "$names" in *"$cell/COPYING3"*"$cell/COPYING.RUNTIME"*|*"$cell/COPYING.RUNTIME"*"$cell/COPYING3"*) pass "$cell: COPYING3 and COPYING.RUNTIME in the pack" ;; *) fail "$cell: COPYING3 and COPYING.RUNTIME in the pack" ;; esac
    if printf '%s\n' "$names" | grep -Eq '\.(o|ali|a|elf|so)$'; then fail "$cell: no objects in the pack"; else pass "$cell: no objects in the pack"; fi
    if [ "$names" = "$(printf '%s\n' "$names" | LC_ALL=C sort)" ]; then pass "$cell: entries sorted"; else fail "$cell: entries sorted"; fi
    if awk '{ if ($2 != "0/0" || $4 != "2026-01-01") bad = 1 } END { exit bad }' "$lst"; then pass "$cell: owner 0/0, fixed time stamp"; else fail "$cell: owner 0/0, fixed time stamp"; fi
  done

  # --check: regenerated == committed, also with another umask, time zone and working directory.
  out="$( cd "$work" && umask 077 && TZ=Asia/Tokyo bash "$MAKE" --check 2>&1 )"; rc=$?
  if [ $rc -eq 0 ]; then pass "make_packs.sh --check: regenerated == committed hashes (umask 077, TZ Asia/Tokyo, other cwd)"
  else fail "make_packs.sh --check: regenerated == committed hashes (exit $rc): $out"; fi
  # ... and fails for a changed, a missing, a stale and an unformatted hash, and a missing file.
  CELLS="light-u54 light-e51"
  sed 's/^[0-9a-f]\{64\}  light-u54.tar$/0000000000000000000000000000000000000000000000000000000000000000  light-u54.tar/' "$HASHES" > "$work/h1"
  expect_out "make_packs.sh --check: a changed hash fails" 1 "light-u54: the regenerated tar stream" bash "$MAKE" --check --cells "$CELLS" --hashes "$work/h1"
  grep -v 'light-e51.tar$' "$HASHES" > "$work/h2"
  expect_out "make_packs.sh --check: a missing hash fails" 1 "light-e51: no hash" bash "$MAKE" --check --cells "$CELLS" --hashes "$work/h2"
  { cat "$HASHES"; echo "0000000000000000000000000000000000000000000000000000000000000000  light-u55.tar"; } > "$work/h3"
  expect_out "make_packs.sh --check: a stale hash fails" 1 "light-u55.tar: no such cell" bash "$MAKE" --check --cells "$CELLS" --hashes "$work/h3"
  sort -r "$HASHES" > "$work/h4"
  expect_out "make_packs.sh --check: an unsorted hash file fails" 1 "not in the format" bash "$MAKE" --check --hashes "$work/h4"
  expect_out "make_packs.sh --check: a missing hash file fails" 1 "is missing" bash "$MAKE" --check --hashes "$work/none.sha256"
  expect_rc "make_packs.sh: an unknown option is a set-up error" 2 bash "$MAKE" --bogus
  expect_rc "make_packs.sh: no mode is a set-up error" 2 bash "$MAKE"
  expect_rc "make_packs.sh: an unknown cell is a set-up error" 2 bash "$MAKE" --check --cells light-u55
  # --update with --cells rewrites only its lines
  cp "$HASHES" "$work/h5"
  expect_rc "make_packs.sh --update --cells: writes the hash file" 0 bash "$MAKE" --update --cells light-u54 --out "$work/upd" --hashes "$work/h5"
  cmp -s "$HASHES" "$work/h5" && pass "make_packs.sh --update --cells: the hash file is the committed one (reproducible, the other lines kept)" || fail "make_packs.sh --update --cells: the hash file is the committed one"

  # -- compare_toolchain.sh -----------------------------------------------------------------
  bash "$CRATE/compare_toolchain.sh" --packs "$PK" >"$work/cmp.out" 2>&1; rc=$?
  if [ $rc -eq 2 ]; then
    skip "compare_toolchain.sh: $(tail -1 "$work/cmp.out")"
  else
    if [ $rc -eq 0 ]; then pass "compare_toolchain.sh: the packs match the shipped runtimes"
    else fail "compare_toolchain.sh: the packs match the shipped runtimes (exit $rc): $(cat "$work/cmp.out")"; fi

    # repack <pack> <command run in the unpacked pack directory>: $work/cp is a copy of the
    # packs in which that pack is changed.
    repack () {
      local pack="$1" cmd="$2" d="$work/rp-$1"
      rm -rf "$d" "$work/cp"; mkdir -p "$d" "$work/cp"
      cp "$PK"/*.tar.zst "$work/cp/"
      zstd -dc "$PK/$pack.tar.zst" | tar -x -C "$d"
      ( cd "$d/$pack" && eval "$cmd" )
      tar --sort=name --format=gnu --mtime='2026-01-01 00:00:00 UTC' --owner=0 --group=0 --numeric-owner \
          -C "$d" -cf - "$pack" | zstd -q -3 -f -o "$work/cp/$pack.tar.zst"
    }
    repack light-u54 'echo "-- tampered" >> gnat/a-assert.adb'
    expect_out "compare_toolchain.sh: a changed common source fails" 1 "gnat/a-assert.adb differs" \
      bash "$CRATE/compare_toolchain.sh" --packs "$work/cp"
    repack light-tasking-u54 'rm gnarl/a-exetim.adb'
    expect_out "compare_toolchain.sh: a missing common source fails" 1 "gnarl/a-exetim.adb is in the toolchain runtime but not in the pack" \
      bash "$CRATE/compare_toolchain.sh" --packs "$work/cp"
    repack light-u54 'echo "package Extra is end Extra;" > gnat/extra.ads'
    expect_out "compare_toolchain.sh: an added common source fails" 1 "gnat/extra.ads is in the pack but not in the toolchain runtime" \
      bash "$CRATE/compare_toolchain.sh" --packs "$work/cp"
    repack embedded-e51 'echo "-- hard float" >> gnat/s-lidosq.adb'
    expect_out "compare_toolchain.sh: an FPU source that is not the soft-float one fails" 1 "gnat/s-lidosq.adb is not the soft-float source" \
      bash "$CRATE/compare_toolchain.sh" --packs "$work/cp"
    repack light-tasking-u54 'echo "-- own PLIC" >> gnarl/s-bbripl.adb'
    expect_out "compare_toolchain.sh: a changed port unit is allowed and reported" 0 "light-tasking-u54: 602 sources compared with light-tasking-polarfiresoc, port units that differ: s-bbripl.adb" \
      bash "$CRATE/compare_toolchain.sh" --packs "$work/cp"
    expect_rc "compare_toolchain.sh: a missing pack directory is a failure" 1 bash "$CRATE/compare_toolchain.sh" --packs "$work/none"
    expect_rc "compare_toolchain.sh: a toolchain without runtimes is a set-up error" 2 bash "$CRATE/compare_toolchain.sh" --packs "$PK" --toolchain "$work"
  fi
fi

[ $fails -eq 0 ] || { echo "$fails failure(s)" >&2; exit 1; }
echo "all ok"
