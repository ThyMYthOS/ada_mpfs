#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Tests for the checks around the bare images, on fixtures and without a
# toolchain or QEMU: tests/qemu/smoke.sh (with a stand-in for QEMU) and
# tools/metrics.sh (with stand-ins for size and readelf), each with positive and
# negative cases that must really fail, and properties of the committed
# metrics.golden. Exits non-zero on any failure.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fails=0

pass () { echo "ok:   $1"; }
fail () { echo "FAIL: $1" >&2; fails=$((fails + 1)); }

# expect_rc <description> <0|nonzero> <command...>
expect_rc () {
  local desc="$1" want="$2"; shift 2
  "$@" >/dev/null 2>&1
  local rc=$?
  if { [ "$want" = 0 ] && [ $rc -eq 0 ]; } || { [ "$want" = nonzero ] && [ $rc -ne 0 ]; }; then
    pass "$desc"
  else
    fail "$desc (exit $rc, wanted $want)"
  fi
}

# expect_out <description> <fixed string> <command...>: the combined output contains the string
expect_out () {
  local desc="$1" needle="$2"; shift 2
  local out
  out="$("$@" 2>&1)"
  case "$out" in *"$needle"*) pass "$desc" ;; *) fail "$desc (no '$needle' in: $out)" ;; esac
}

tmp="$(mktemp -d)"
trap 'rm -r "$tmp"' EXIT
tab="$(printf '\t')"

# ---------------------------------------------------------------------------
# smoke.sh with a stand-in for QEMU. The "image" is a text file; the stand-in
# writes its content to the file behind -serial, like a guest writing to MMUART0.
mkdir -p "$tmp/q"
cat > "$tmp/q/qemu" <<'EOF'
#!/bin/sh
# Stand-in for qemu-system-riscv64: QEMU_FAKE_VERSION is what --version reports.
case "$1" in
  --version) echo "QEMU emulator version ${QEMU_FAKE_VERSION:-10.2.1}"; exit 0 ;;
  -M) [ "$2" = help ] && { echo "microchip-icicle-kit  Microchip PolarFire SoC Icicle Kit"; exit 0; } ;;
esac
serial=""; kernel=""
while [ $# -gt 0 ]; do
  case "$1" in
    -serial) serial="${2#file:}"; shift 2 ;;
    -kernel) kernel="$2"; shift 2 ;;
    *) shift ;;
  esac
done
cat "$kernel" > "$serial"
EOF
chmod +x "$tmp/q/qemu"
printf 'bare hello E51 hart 0\r\n' > "$tmp/q/good.img"
printf 'bare hello U54 hart 3\r\n' > "$tmp/q/wronghart.img"
: > "$tmp/q/silent.img"

expected () {   # expected <file> <image> <string>...
  local f="$1" img="$2"; shift 2
  { printf '# fixture\nimage\tstring\n'; for s in "$@"; do printf '%s\t%s\n' "$img" "$s"; done; } > "$f"
}
smoke () {   # smoke <expectation file> [env...]
  local f="$1"; shift
  env QEMU="$tmp/q/qemu" SMOKE_EXPECTED="$f" SMOKE_TIMEOUT=5 "$@" sh "$ROOT/tests/qemu/smoke.sh"
}

expected "$tmp/q/ok.expected" "$tmp/q/good.img" "bare hello E51 hart 0"
expect_rc  "smoke: passes when the image prints what is expected" 0 smoke "$tmp/q/ok.expected"
expected "$tmp/q/wrong.expected" "$tmp/q/wronghart.img" "bare hello U54 hart 1"
expect_rc  "smoke: fails when the console shows another hart" nonzero smoke "$tmp/q/wrong.expected"
expect_out "smoke: names the missing string" 'MISSING: "bare hello U54 hart 1"' smoke "$tmp/q/wrong.expected"
expected "$tmp/q/silent.expected" "$tmp/q/silent.img" "bare hello E51 hart 0"
expect_rc  "smoke: fails on an empty console" nonzero smoke "$tmp/q/silent.expected"
expect_out "smoke: says the console was empty" "guest console: EMPTY" smoke "$tmp/q/silent.expected"
expected "$tmp/q/missing.expected" "$tmp/q/no-such.img" "bare hello E51 hart 0"
expect_rc  "smoke: fails on a missing image" nonzero smoke "$tmp/q/missing.expected"
expected "$tmp/q/two.expected" "$tmp/q/good.img" "bare hello E51 hart 0" "bare hello E51 hart 1"
expect_rc  "smoke: every string of an image must appear" nonzero smoke "$tmp/q/two.expected"
expect_rc  "smoke: fails for a QEMU older than the floor" nonzero smoke "$tmp/q/ok.expected" QEMU_FAKE_VERSION=9.2.0
expect_out "smoke: reports the QEMU floor" "older than" smoke "$tmp/q/ok.expected" QEMU_FAKE_VERSION=9.2.0
expect_rc  "smoke: the floor can be lowered" 0 smoke "$tmp/q/ok.expected" QEMU_FAKE_VERSION=9.2.0 QEMU_MIN=0
expect_rc  "smoke: fails without QEMU" nonzero smoke "$tmp/q/ok.expected" QEMU="$tmp/q/none"
: > "$tmp/q/empty.expected"
expect_rc  "smoke: an empty expectation file fails" nonzero smoke "$tmp/q/empty.expected"
printf 'image\tstring\n%s\n' "$tmp/q/good.img" > "$tmp/q/badrow.expected"
expect_rc  "smoke: a row without a string fails" nonzero smoke "$tmp/q/badrow.expected"
printf 'app\tstring\n%s\tbare hello E51 hart 0\n' "$tmp/q/good.img" > "$tmp/q/badhdr.expected"
expect_rc  "smoke: a wrong header fails" nonzero smoke "$tmp/q/badhdr.expected"
expect_rc  "smoke: a missing expectation file fails" nonzero smoke "$tmp/q/none.expected"
expect_rc  "smoke: a bad timeout fails" nonzero smoke "$tmp/q/ok.expected" SMOKE_TIMEOUT=x
# The committed expectations name the images of the examples and the two lines
# of the bare hello.
exp="$ROOT/tests/qemu/smoke.expected"
grep -q "^examples/bare_hello/bin-e51/bare_hello.elf${tab}bare hello E51 hart 0\$" "$exp" \
  && pass "smoke.expected: E51 line" || fail "smoke.expected: E51 line"
grep -q "^examples/bare_hello/bin-u54/bare_hello.elf${tab}bare hello U54 hart 1\$" "$exp" \
  && pass "smoke.expected: U54 line" || fail "smoke.expected: U54 line"

# ---------------------------------------------------------------------------
# tests/renode/smoke.sh with a stand-in for Renode. It reads $elf and $uart out of
# the -e command, like bare.resc does, and copies the "image" to the UART file.
mkdir -p "$tmp/r"
cat > "$tmp/r/renode" <<'EOF2'
#!/bin/bash
[ "$1" = --version ] && { echo "Renode fake"; exit 0; }
cmd=""; while [ $# -gt 0 ]; do [ "$1" = -e ] && cmd="$2"; shift; done
elf="$(printf '%s' "$cmd" | sed -n 's/.*\$elf=@\([^;]*\);.*/\1/p')"
uart="$(printf '%s' "$cmd" | sed -n 's/.*\$uart=@\([^;]*\);.*/\1/p')"
[ -n "$elf" ] && [ -n "$uart" ] || { echo "fake renode: no \$elf/\$uart in: $cmd" >&2; exit 2; }
[ -z "${FAKE_RENODE_ERROR:-}" ] || echo "There was an error executing command 'emulation RunFor'"
cat "$elf" > "$uart"
EOF2
chmod +x "$tmp/r/renode"
printf 'pmp entries 16\r\n' > "$tmp/r/pmp16.img"
printf 'pmp entries 8\r\n' > "$tmp/r/pmp8.img"
rsmoke () {   # rsmoke <expectation file> [env...]
  local f="$1"; shift
  env RENODE="$tmp/r/renode" SMOKE_EXPECTED="$f" "$@" bash "$ROOT/tests/renode/smoke.sh"
}
expected "$tmp/r/ok.expected" "$tmp/r/pmp16.img" "pmp entries 16"
expect_rc  "renode smoke: passes when the image prints what is expected" 0 rsmoke "$tmp/r/ok.expected"
expected "$tmp/r/wrong.expected" "$tmp/r/pmp8.img" "pmp entries 16"
expect_rc  "renode smoke: fails on another PMP count" nonzero rsmoke "$tmp/r/wrong.expected"
expect_out "renode smoke: names the missing string" 'MISSING: "pmp entries 16"' rsmoke "$tmp/r/wrong.expected"
expected "$tmp/r/silent.expected" "$tmp/q/silent.img" "pmp entries 16"
expect_rc  "renode smoke: fails on an empty console" nonzero rsmoke "$tmp/r/silent.expected"
expect_out "renode smoke: says the console was empty" "guest console: EMPTY" rsmoke "$tmp/r/silent.expected"
expect_rc  "renode smoke: an error reported by Renode fails even with the right output" nonzero rsmoke "$tmp/r/ok.expected" FAKE_RENODE_ERROR=1
expected "$tmp/r/missing.expected" "$tmp/r/none.img" "pmp entries 16"
expect_rc  "renode smoke: fails on a missing image" nonzero rsmoke "$tmp/r/missing.expected"
expect_rc  "renode smoke: fails without Renode" nonzero rsmoke "$tmp/r/ok.expected" RENODE="$tmp/r/none"
: > "$tmp/r/empty.expected"
expect_rc  "renode smoke: an empty expectation file fails" nonzero rsmoke "$tmp/r/empty.expected"
printf 'app\tstring\n%s\tx\n' "$tmp/r/pmp16.img" > "$tmp/r/badhdr.expected"
expect_rc  "renode smoke: a wrong header fails" nonzero rsmoke "$tmp/r/badhdr.expected"
rexp="$ROOT/tests/renode/smoke.expected"
grep -q "^examples/pmp_probe/bin-e51/pmp_probe.elf${tab}pmp entries 16\$" "$rexp" \
  && grep -q "^examples/pmp_probe/bin-u54/pmp_probe.elf${tab}pmp entries 16\$" "$rexp" \
  && pass "renode smoke.expected: 16 PMP entries, separate from the QEMU value" \
  || fail "renode smoke.expected: 16 PMP entries, separate from the QEMU value"
grep -q "RunFor" "$ROOT/tests/renode/bare.resc" && ! grep -q '^start' "$ROOT/tests/renode/bare.resc" \
  && pass "bare.resc: runs a fixed span of virtual time with RunFor, without start" \
  || fail "bare.resc: runs a fixed span of virtual time with RunFor, without start"
grep -Eq '^RENODE_SHA256_X86_64_LINUX=[0-9a-f]{64}$' "$ROOT/tools/toolchain.env" \
  && pass "toolchain.env pins a SHA-256 for Renode" || fail "toolchain.env pins a SHA-256 for Renode"

# ---------------------------------------------------------------------------
# metrics.sh with stand-ins for size and readelf. The "image" X.elf has a
# fixture X.elf.fx that sets TEXT DATA BSS ENTRY FLAGS ARCH COMMENT.
mkdir -p "$tmp/m/bin"
cat > "$tmp/m/bin/fake-size" <<'EOF'
#!/bin/sh
[ "$1" = --version ] && { echo "fake size"; exit 0; }
. "$1.fx" || exit 1
printf '   text\t   data\t    bss\t    dec\t    hex\tfilename\n'
printf '   %s\t      %s\t  %s\t      0\t      0\t%s\n' "$TEXT" "$DATA" "$BSS" "$1"
EOF
cat > "$tmp/m/bin/fake-readelf" <<'EOF'
#!/bin/sh
[ "$1" = --version ] && { echo "fake readelf"; exit 0; }
mode="$1"; shift
case "$mode" in
  -h) img="$1" ;;
  -A) img="$1" ;;
  -p) img="$2" ;;
esac
. "$img.fx" || exit 1
case "$mode" in
  -h) printf 'ELF Header:\n  Entry point address:               %s\n  Flags:                             %s\n' "$ENTRY" "$FLAGS" ;;
  -A) printf 'Attribute Section: riscv\nFile Attributes\n  Tag_RISCV_stack_align: 16-bytes\n  Tag_RISCV_arch: "%s"\n  Tag_RISCV_priv_spec: 1\n' "$ARCH" ;;
  -p) printf 'String dump of section .comment:\n  [     0]  %s\n' "$COMMENT" ;;
esac
EOF
cat > "$tmp/m/bin/fake-strings" <<'EOF'
#!/bin/sh
[ "$1" = --version ] && { echo "fake strings"; exit 0; }
[ "$1" = -a ] && shift
. "$1.fx" || exit 1
printf 'some string\n'
for v in ${GNATVER:-}; do printf 'GNAT Version: %s\n' "$v"; done
EOF
chmod +x "$tmp/m/bin/fake-size" "$tmp/m/bin/fake-readelf" "$tmp/m/bin/fake-strings"

E51_ARCH="rv64i2p1_m2p0_a2p1_c2p0_zicsr2p0_zifencei2p0"
U54_ARCH="rv64i2p1_m2p0_a2p1_f2p2_d2p2_c2p0_zicsr2p0_zifencei2p0"
CC="GCC: (GNAT-FSF-builds) 15.3.0"

# image <example> <hart> <name> <text> <flags> <arch> [comment [GNAT version(s)]]
image () {
  local d="$tmp/m/ex/$1/bin-$2"
  mkdir -p "$d"
  : > "$d/$3.elf"
  printf 'TEXT=%s\nDATA=0\nBSS=16384\nENTRY=0x8000000\nFLAGS="%s"\nARCH="%s"\nCOMMENT="%s"\n' \
    "$4" "$5" "$6" "${7:-$CC}" > "$d/$3.elf.fx"
  [ -z "${8:-}" ] || printf 'GNATVER="%s"\n' "$8" >> "$d/$3.elf.fx"
}
image hello e51 hello 538 "0x1, RVC, soft-float ABI"   "$E51_ARCH"
image hello u54 hello 548 "0x5, RVC, double-float ABI" "$U54_ARCH"

metrics () {   # metrics verify|bless [env...]
  local m="$1"; shift
  env RV_SIZE="$tmp/m/bin/fake-size" RV_READELF="$tmp/m/bin/fake-readelf" RV_STRINGS="$tmp/m/bin/fake-strings" \
      EXAMPLES="$tmp/m/ex" GOLDEN="$tmp/m/golden" "$@" sh "$ROOT/tools/metrics.sh" "$m"
}

expect_rc  "metrics: verify without a golden file fails" nonzero metrics verify
expect_rc  "metrics: bless writes the golden file" 0 metrics bless
[ "$(grep -vc '^#' "$tmp/m/golden")" = 3 ] && pass "metrics: golden has the header and two rows" \
  || fail "metrics: golden has the header and two rows"
expect_rc  "metrics: verify passes on the blessed images" 0 metrics verify
grep -q "^hello/e51/hello${tab}$CC${tab}538${tab}0${tab}16384${tab}0x8000000${tab}0x1, RVC, soft-float ABI${tab}$E51_ARCH${tab}" "$tmp/m/golden" \
  && pass "metrics: the row has image, compiler, sizes, entry, e_flags and the arch tag" \
  || fail "metrics: the row has image, compiler, sizes, entry, e_flags and the arch tag"
cp "$tmp/m/golden" "$tmp/m/golden.keep"
expect_rc  "metrics: bless twice writes the same file" 0 metrics bless
cmp -s "$tmp/m/golden" "$tmp/m/golden.keep" && pass "metrics: bless is idempotent" || fail "metrics: bless is idempotent"

image hello e51 hello 539 "0x1, RVC, soft-float ABI" "$E51_ARCH"
expect_rc  "metrics: a changed size fails verify" nonzero metrics verify
expect_out "metrics: the failure shows expected and actual" "expected: 538" metrics verify
image hello e51 hello 538 "0x5, RVC, double-float ABI" "$E51_ARCH"
expect_rc  "metrics: a changed e_flags fails verify" nonzero metrics verify
expect_out "metrics: the e_flags mismatch is reported" "FAIL hello/e51/hello.eflags" metrics verify
image hello e51 hello 538 "0x1, RVC, soft-float ABI" "${E51_ARCH/_c2p0/_f2p2_d2p2_c2p0}"
expect_rc  "metrics: a float extension in the arch tag fails verify" nonzero metrics verify
expect_out "metrics: the arch mismatch is reported" "FAIL hello/e51/hello.isa" metrics verify
image hello e51 hello 538 "0x1, RVC, soft-float ABI" "$E51_ARCH" "GCC: (GNAT-FSF-builds) 99.0.0"
expect_rc  "metrics: another compiler has no baseline and fails" nonzero metrics verify
expect_out "metrics: says no baseline" "no baseline" metrics verify
image hello e51 hello 538 "0x1, RVC, soft-float ABI" "$E51_ARCH"
expect_rc  "metrics: the golden file verifies again with the original image" 0 metrics verify
mv "$tmp/m/ex/hello/bin-u54/hello.elf" "$tmp/m/hello.elf.away"
expect_rc  "metrics: an image that is in the golden file but missing fails" nonzero metrics verify
expect_out "metrics: the missing image is reported" "in $tmp/m/golden but not measured" metrics verify
mv "$tmp/m/hello.elf.away" "$tmp/m/ex/hello/bin-u54/hello.elf"
image extra e51 extra 10 "0x1, RVC, soft-float ABI" "$E51_ARCH"
expect_rc  "metrics: an image that is not in the golden file fails" nonzero metrics verify
expect_out "metrics: the unknown image is reported" "absent from" metrics verify
rm -r "$tmp/m/ex/extra"
printf 'TEXT=5\n' > "$tmp/m/ex/hello/bin-e51/hello.elf.fx"
expect_rc  "metrics: an unparseable measurement fails verify" nonzero metrics verify
expect_rc  "metrics: bless refuses an unparseable measurement" nonzero metrics bless
cmp -s "$tmp/m/golden" "$tmp/m/golden.keep" && pass "metrics: a refused bless leaves the golden file alone" \
  || fail "metrics: a refused bless leaves the golden file alone"
image hello e51 hello 538 "0x1, RVC, soft-float ABI" "$E51_ARCH"
expect_rc  "metrics: a missing tool fails" nonzero metrics verify RV_SIZE="$tmp/m/bin/none"
# An image with a binder carries "GNAT Version:" (__gnat_version): that is the key, not .comment.
image hello e51 hello 538 "0x1, RVC, soft-float ABI" "$E51_ARCH" "$CC" "15.3.1"
expect_rc  "metrics: an image with a GNAT Version string has another key than its .comment" nonzero metrics verify
expect_out "metrics: the key is the GNAT Version" "GNAT 15.3.1" metrics verify
expect_rc  "metrics: bless keys it on the GNAT Version" 0 metrics bless
grep -q "^hello/e51/hello${tab}GNAT 15.3.1${tab}" "$tmp/m/golden" \
  && pass "metrics: the golden row carries 'GNAT 15.3.1' as the compiler" \
  || fail "metrics: the golden row carries 'GNAT 15.3.1' as the compiler"
expect_rc  "metrics: verify passes on it" 0 metrics verify
image hello e51 hello 538 "0x1, RVC, soft-float ABI" "$E51_ARCH" "$CC" "15.3.2"
expect_rc  "metrics: another GNAT Version has no baseline and fails" nonzero metrics verify
expect_out "metrics: says no baseline for the other GNAT Version" "no baseline" metrics verify
image hello e51 hello 538 "0x1, RVC, soft-float ABI" "$E51_ARCH" "$CC" "15.3.1 15.3.2"
expect_rc  "metrics: two GNAT Versions in one image fail" nonzero metrics verify
expect_out "metrics: says it found two" "2 different GNAT Version strings" metrics verify
expect_rc  "metrics: a missing strings tool fails" nonzero metrics verify RV_STRINGS="$tmp/m/bin/none"
image hello e51 hello 538 "0x1, RVC, soft-float ABI" "$E51_ARCH"
cp "$tmp/m/golden.keep" "$tmp/m/golden"
expect_rc  "metrics: the .comment golden verifies again after the GNAT cases" 0 metrics verify
{ grep '^#' "$tmp/m/golden"; printf 'image\tcompiler\n'; } > "$tmp/m/badgolden"
expect_rc  "metrics: a golden file without rows fails" nonzero metrics verify GOLDEN="$tmp/m/badgolden"
{ grep -v "^hello/u54" "$tmp/m/golden"; } > "$tmp/m/partial"
expect_rc  "metrics: a measured image missing from the golden file fails" nonzero metrics verify GOLDEN="$tmp/m/partial"

# ---------------------------------------------------------------------------
# The committed metrics.golden: the E51 images carry no f/d (soft-float ABI,
# e_flags 0x1), the U54 images do (double-float ABI, e_flags 0x5).
golden="$ROOT/metrics.golden"
rows="$(grep -v '^#' "$golden" | tail -n +2)"
[ -n "$rows" ] && pass "metrics.golden has rows" || fail "metrics.golden has rows"
bad=0
while IFS="$tab" read -r img comp text data bss entry eflags isa attrs; do
  case "$img" in
    */e51/*) case "$eflags" in "0x1,"*"soft-float ABI") ;; *) bad=1; echo "e51 e_flags: $img $eflags" >&2 ;; esac
             case "$isa" in *_f[0-9]*|*_d[0-9]*) bad=1; echo "e51 with f/d: $img $isa" >&2 ;; esac ;;
    */u54/*) case "$eflags" in "0x5,"*"double-float ABI") ;; *) bad=1; echo "u54 e_flags: $img $eflags" >&2 ;; esac
             case "$isa" in *_f2p2_d2p2_*) ;; *) bad=1; echo "u54 without f/d: $img $isa" >&2 ;; esac ;;
    *) bad=1; echo "unexpected image $img" >&2 ;;
  esac
  case "$comp" in GCC:*|"GNAT "*) ;; *) bad=1; echo "compiler of $img: $comp" >&2 ;; esac
done <<< "$rows"
[ $bad -eq 0 ] && pass "metrics.golden: the ABI of every image is in its e_flags and Tag_RISCV_arch" \
  || fail "metrics.golden: the ABI of every image is in its e_flags and Tag_RISCV_arch"
for img in bare_hello/e51/bare_hello bare_hello/u54/bare_hello pmp_probe/e51/pmp_probe pmp_probe/u54/pmp_probe; do
  grep -q "^$img$tab" "$golden" && pass "metrics.golden has $img" || fail "metrics.golden has $img"
done

# ---------------------------------------------------------------------------
# The linker script and the start file: every memory region the script uses is a
# literal ORIGIN with a symbolic LENGTH, and the hart gate reads the mask symbol
# that the build defines.
ld="$ROOT/examples/common/ld/mpfs-memory.ld"
if awk '/ORIGIN *= *0x[0-9A-Fa-f]+, *LENGTH *= *MPFS_/ || /ORIGIN *= *MPFS_LOCAL_ITIM_ORIGIN/ { n++ } END { exit n == 13 ? 0 : 1 }' "$ld"; then
  pass "mpfs-memory.ld: thirteen regions, literal ORIGINs (one symbolic) and symbolic LENGTHs"
else
  fail "mpfs-memory.ld: thirteen regions, literal ORIGINs (one symbolic) and symbolic LENGTHs"
fi
for sym in $(grep -o 'MPFS_[A-Z0-9_]*LENGTH' "$ld" | sort -u); do
  grep -q "defsym=$sym=" "$ROOT/examples/common/bare_build.sh" \
    && pass "bare_build.sh defines $sym" || fail "bare_build.sh defines $sym"
done
grep -q "defsym=__mpfs_harts_mask=" "$ROOT/examples/common/bare_build.sh" \
  && grep -q "__mpfs_harts_mask" "$ROOT/examples/bare_hello/start.S" \
  && pass "the hart mask goes from the build to start.S as __mpfs_harts_mask" \
  || fail "the hart mask goes from the build to start.S as __mpfs_harts_mask"

echo "summary: $fails failure(s)"
[ $fails -eq 0 ]
