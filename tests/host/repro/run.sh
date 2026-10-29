#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Tests for tools/repro.sh on a fixture tree with a stand-in ./x and stand-ins for the
# pinned toolchain directories, without a compiler: the same input twice passes; a build
# that embeds its directory, its time or something that changes from run to run fails and
# names the image; a missing toolchain, a failing build, a build without an image, an
# image in one copy only, no example and no epoch fail. Exits non-zero on any failure.
#
# What this does not show: that the real images are reproducible (that is `./x repro`,
# and the job `repro` of the bare workflow).

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
REPRO="$ROOT/tools/repro.sh"
fails=0

pass () { echo "ok:   $1"; }
fail () { echo "FAIL: $1" >&2; fails=$((fails + 1)); }

expect_rc () {
  local desc="$1" want="$2"; shift 2
  "$@" >/dev/null 2>&1
  local rc=$?
  if { [ "$want" = 0 ] && [ $rc -eq 0 ]; } || { [ "$want" = nonzero ] && [ $rc -ne 0 ]; } \
     || { [ "$rc" = "$want" ]; }; then
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

# expect_no_out <description> <fixed string> <command...>
expect_no_out () {
  local desc="$1" needle="$2"; shift 2
  local out
  out="$("$@" 2>&1)"
  case "$out" in *"$needle"*) fail "$desc ('$needle' in: $out)" ;; *) pass "$desc" ;; esac
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# A failed run keeps its work directory; keep it inside the temporary directory.
mkdir "$tmp/tmpdir"; export TMPDIR="$tmp/tmpdir"

# The pinned toolchain directories, as tools/mpfs-env.sh looks for them (empty stand-ins).
# shellcheck source=tools/toolchain.env
. "$ROOT/tools/toolchain.env"
tc="$tmp/toolchains"
mkdir -p "$tc/gprbuild_${GPRBUILD_VERSION}_x/bin" \
         "$tc/gnat_riscv64_elf_${GNAT_RISCV64_VERSION}_x/bin" \
         "$tc/gnat_native_${GNAT_NATIVE_VERSION}_x/bin"
mkdir -p "$tmp/no-toolchains"

# The fixture tree: two examples, one with two harts. The stand-in ./x builds an "image"
# from the sources and SOURCE_DATE_EPOCH; FAKE_MODE selects what else goes into it.
tree="$tmp/tree"
mkdir -p "$tree/examples/alpha/src" "$tree/examples/beta" "$tree/examples/gamma"
printf 'project App is end App;\n' > "$tree/examples/alpha/app.gpr"
printf 'project App is end App;\n' > "$tree/examples/beta/app.gpr"
printf 'project App is end App;\n' > "$tree/examples/gamma/app.gpr"
# gamma: the image of one U54 hart, an entry u54-h<N> of BUILD_HARTS (x build --hart u54 --harts N)
printf 'HART=u54\nBUILD_HARTS=u54-h3\n' > "$tree/examples/gamma/example.conf"
printf 'HART=e51\nBUILD_HARTS=e51 u54\n' > "$tree/examples/alpha/example.conf"
printf 'HART=u54\n' > "$tree/examples/beta/example.conf"
printf 'procedure Alpha is begin null; end;\n' > "$tree/examples/alpha/src/alpha.adb"
cat > "$tree/x" <<'XEOF'
#!/usr/bin/env bash
# Stand-in for ./x build <example> --hart <hart> [--harts <N>].
set -eu
[ "$1" = build ] || exit 2
ex="$2"; hart="$4"
if [ "${5:-}" = --harts ]; then hart="$hart-h$6"; fi
case "${FAKE_MODE:-same}" in
  fail) echo "fake build failed" >&2; exit 1 ;;
  nothing) exit 0 ;;
esac
out="examples/$ex/bin-$hart"
mkdir -p "$out"
{
  echo "image $ex $hart epoch=${SOURCE_DATE_EPOCH:-unset}"
  cat "examples/$ex/app.gpr"
  case "${FAKE_MODE:-same}" in
    embed)      [ "$ex$hart" = alphau54 ] && echo "built in $PWD" ;;
    embed-all)  echo "built in $PWD" ;;
    random)     [ "$ex" = beta ] && echo "$RANDOM$RANDOM$$" ;;
    one-sided)  [ "$PWD" != "${FAKE_FIRST:-}" ] && [ "$ex$hart" = betau54 ] && echo "only the second copy" ;;
  esac
} > "$out/$ex.elf"
[ "${FAKE_MODE:-same}" = extra ] && [ "$(basename "$PWD")" = tree ] && echo x > "$out/extra.elf"
exit 0
XEOF
chmod +x "$tree/x"

repro () {   # repro [env...]: SOURCE_DATE_EPOCH fixed, the stand-in toolchain
  env MPFS_ADA_TOOLCHAINS="$tc" REPRO_ROOT="$tree" SOURCE_DATE_EPOCH=1700000000 "$@" \
      bash "$REPRO"
}

expect_rc  "the same input twice passes" 0 repro
expect_out "it reports the images it compared" "4 image(s) identical" repro
expect_out "it compares the harts named in BUILD_HARTS and HART" "examples/beta/bin-u54/beta.elf" repro
expect_out "an entry u54-h3 is built with --harts 3 into bin-u54-h3" "examples/gamma/bin-u54-h3/gamma.elf" repro

# The comparison is not vacuous: the copies are built in different directories.
expect_rc  "an image that embeds its build directory fails" 1 repro FAKE_MODE=embed
expect_out "the failure names the image" "DIFF: examples/alpha/bin-u54/alpha.elf" repro FAKE_MODE=embed
expect_out "the failure says that the image contains the build directory" "; contains " repro FAKE_MODE=embed
expect_out "the identical images are still listed as ok" "ok:   " repro FAKE_MODE=embed
expect_no_out "only the differing image is named" "DIFF: examples/beta" repro FAKE_MODE=embed
expect_rc  "every image can differ" 1 repro FAKE_MODE=embed-all
expect_rc  "an image that changes from run to run fails" 1 repro FAKE_MODE=random
expect_out "that failure names the image, too" "DIFF: examples/beta/bin-u54/beta.elf" repro FAKE_MODE=random

# The two builds get the same epoch, and a given epoch reaches the build.
mkdir -p "$tmp/keep"
repro REPRO_WORK="$tmp/keep" >/dev/null 2>&1
grep -q 'epoch=1700000000' "$tmp/keep/one/ada_mpfs/examples/alpha/bin-e51/alpha.elf" \
  && grep -q 'epoch=1700000000' "$tmp/keep/second-build-dir/tree/examples/alpha/bin-e51/alpha.elf" \
  && pass "both builds get SOURCE_DATE_EPOCH" || fail "both builds get SOURCE_DATE_EPOCH"
[ -f "$tmp/keep/one/ada_mpfs/examples/alpha/bin-e51/alpha.elf" ] \
  && pass "REPRO_WORK keeps the copies" || fail "REPRO_WORK keeps the copies"
# The copies do not start from the build products of the original.
mkdir -p "$tree/examples/alpha/bin-e51" "$tree/examples/alpha/obj-e51"
echo stale > "$tree/examples/alpha/bin-e51/stale.elf"
expect_rc  "a stale image of the original is not compared" 0 repro
expect_no_out "a stale image is not listed" "stale.elf" repro
rm -r "$tree/examples/alpha/bin-e51" "$tree/examples/alpha/obj-e51"
# Without SOURCE_DATE_EPOCH the commit time of the tree is used.
git_tree="$tmp/git-tree"
cp -r "$tree" "$git_tree"
( cd "$git_tree" && git init -q . && git add -A \
    && GIT_AUTHOR_DATE="@1234567890 +0000" GIT_COMMITTER_DATE="@1234567890 +0000" \
       git -c user.name=t -c user.email=t@example.com commit -q -m fixture ) >/dev/null 2>&1
expect_out "the default epoch is the commit time" "SOURCE_DATE_EPOCH=1234567890" \
  env -u SOURCE_DATE_EPOCH MPFS_ADA_TOOLCHAINS="$tc" REPRO_ROOT="$git_tree" bash "$REPRO"
expect_rc  "a tree with a .git directory is copied without it" 0 \
  env -u SOURCE_DATE_EPOCH MPFS_ADA_TOOLCHAINS="$tc" REPRO_ROOT="$git_tree" bash "$REPRO"

# Fail closed.
expect_rc  "a missing toolchain fails" 2 repro MPFS_ADA_TOOLCHAINS="$tmp/no-toolchains"
expect_out "it says the toolchain is missing" "not installed" repro MPFS_ADA_TOOLCHAINS="$tmp/no-toolchains"
rmdir "$tc/gnat_native_${GNAT_NATIVE_VERSION}_x/bin"
expect_rc  "a toolchain with one part missing fails" 2 repro
mkdir "$tc/gnat_native_${GNAT_NATIVE_VERSION}_x/bin"
expect_rc  "a failing build fails" 1 repro FAKE_MODE=fail
expect_out "a failing build is reported" "FAIL: build of alpha (e51)" repro FAKE_MODE=fail
expect_rc  "a build that leaves no image fails" 1 repro FAKE_MODE=nothing
expect_out "that says what happened" "left no image" repro FAKE_MODE=nothing
expect_rc  "an image in one copy only fails" 1 repro FAKE_MODE=extra
expect_out "that names the different sets" "different sets of images" repro FAKE_MODE=extra
expect_rc  "an argument is refused" 2 env MPFS_ADA_TOOLCHAINS="$tc" REPRO_ROOT="$tree" SOURCE_DATE_EPOCH=1 bash "$REPRO" extra

mkdir -p "$tmp/empty/examples"
expect_rc  "no example fails" 2 repro REPRO_ROOT="$tmp/empty"
expect_rc  "a tree without examples/ fails" 2 repro REPRO_ROOT="$tmp/none"
expect_rc  "no epoch fails" 2 env -u SOURCE_DATE_EPOCH MPFS_ADA_TOOLCHAINS="$tc" REPRO_ROOT="$tree" bash "$REPRO"

# The verb exists and the examples carry the switch that makes the images reproducible.
grep -q 'repro)  *delegate tools/repro.sh' "$ROOT/x" \
  && pass "./x repro delegates to tools/repro.sh" || fail "./x repro delegates to tools/repro.sh"
for g in "$ROOT"/examples/*/app.gpr; do
  grep -q 'ffile-prefix-map' "$g" \
    && pass "${g#"$ROOT"/} maps the build directory" || fail "${g#"$ROOT"/} maps the build directory"
done

echo "summary: $fails failure(s)"
[ $fails -eq 0 ]
