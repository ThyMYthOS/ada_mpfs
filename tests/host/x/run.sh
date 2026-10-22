#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Smoke test for ./x: every verb is listed in the help, option validation rejects
# invalid and excluded combinations, and missing tool scripts fail instead of
# passing silently. Exits non-zero on any failure.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
X="$ROOT/x"
fails=0

pass () { echo "ok:   $1"; }
fail () { echo "FAIL: $1" >&2; fails=$((fails + 1)); }

# expect_rc <description> <expected exit code: 0|nonzero> <command...>
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

# Every verb appears in the help text.
help="$("$X" help)"
for verb in help list toolchain build clean new qemu mem test metrics analyze stack \
            svd pac trace prove hw completion; do
  case "$help" in *"./x $verb"*) pass "help lists $verb" ;; *) fail "help lists $verb" ;; esac
done

# MPFS_PREBUILT_IMAGES=1 builds nothing: without the images of an earlier build the QEMU and
# Renode tests fail and say which image is missing (in a tree that has none).
if [ -z "$(find "$ROOT/examples" -path '*/bin-*' -name '*.elf' 2>/dev/null | head -1)" ]; then
  out="$(MPFS_PREBUILT_IMAGES=1 "$X" test qemu 2>&1)"; rc=$?
  case "$out" in
    *"prebuilt image missing"*) [ $rc -ne 0 ] && pass "prebuilt images: a missing image fails the QEMU test" \
                                              || fail "prebuilt images: a missing image fails the QEMU test (exit 0)" ;;
    *) fail "prebuilt images: a missing image fails the QEMU test (no message)" ;;
  esac
else
  echo "skip: prebuilt images (this tree has built images)"
fi

# toolchain install alire: an installed pinned alr is reported, not fetched again
(
  . "$ROOT/tools/toolchain.env"
  alrp="$(mktemp -d)"; mkdir -p "$alrp/alr-$ALR_VERSION/bin"; printf '#!/bin/sh\nexit 0\n' > "$alrp/alr-$ALR_VERSION/bin/alr"; chmod +x "$alrp/alr-$ALR_VERSION/bin/alr"
  case "$(MPFS_TOOLS_PREFIX="$alrp" "$X" toolchain install alire 2>&1)" in
    *"already installed"*) pass "toolchain install alire reports an installed alr" ;;
    *) fail "toolchain install alire reports an installed alr" ;;
  esac
  rm -rf "$alrp"
)

# toolchain check reports the pinned alr of its prefix, not the one that comes first on PATH
(
  . "$ROOT/tools/toolchain.env"
  ap="$(mktemp -d)"; gb="$(mktemp -d)"
  mkdir -p "$ap/alr-$ALR_VERSION/bin"
  printf '#!/bin/sh\necho "alr %s"\n' "$ALR_VERSION" > "$ap/alr-$ALR_VERSION/bin/alr"
  printf '#!/bin/sh\necho "alr 0.0.1"\n' > "$gb/alr"
  chmod +x "$ap/alr-$ALR_VERSION/bin/alr" "$gb/alr"
  line="$(PATH="$gb:$PATH" MPFS_TOOLS_PREFIX="$ap" "$X" toolchain check 2>&1 | grep '^  alr ')"
  case "$line" in
    *" ok "*"$ALR_VERSION"*) pass "toolchain check reports the alr of the prefix before the one on PATH" ;;
    *) fail "toolchain check reports the alr of the prefix before the one on PATH ($line)" ;;
  esac
  rm -rf "$ap" "$gb"
)

# toolchain check finds the pinned Renode in its prefix and accepts its build number
(
  . "$ROOT/tools/toolchain.env"
  rp="$(mktemp -d)"; mkdir -p "$rp/renode-$RENODE_VERSION"
  printf '#!/bin/sh\necho "Renode v%s.7"\n' "$RENODE_VERSION" > "$rp/renode-$RENODE_VERSION/renode"; chmod +x "$rp/renode-$RENODE_VERSION/renode"
  case "$(MPFS_TOOLS_PREFIX="$rp" "$X" toolchain check 2>&1)" in
    *"renode               ok"*) pass "toolchain check finds the Renode of the prefix" ;;
    *) fail "toolchain check finds the Renode of the prefix" ;;
  esac
  rm -rf "$rp"
)

expect_rc "help exits 0"            0       "$X" help
expect_rc "list exits 0"            0       "$X" list
expect_rc "list --json exits 0"     0       "$X" list --json
expect_rc "unknown verb fails"      nonzero "$X" no-such-verb
expect_rc "toolchain rejects an unknown install target" nonzero "$X" toolchain install bogus
case "$("$X" toolchain install bogus 2>&1)" in
  *"svdtools|svd2ada|pac"*) pass "toolchain usage names the pac target" ;;
  *) fail "toolchain usage names the pac target" ;;
esac
case "$help" in
  *"svdtools|svd2ada|pac"*) pass "help names the pac target" ;;
  *) fail "help names the pac target" ;;
esac
expect_rc "svd without a mode fails" nonzero "$X" svd
expect_rc "svd rejects an unknown mode" nonzero "$X" svd bogus
expect_rc "svd probe needs a peripheral" nonzero "$X" svd probe

# Option validation happens before the toolchain is touched, so these hold on any host.
# A throwaway example is needed to get past the example lookup.
tmp="$(mktemp -d)"
trap 'rm -r "$tmp"' EXIT
mkdir -p "$tmp/tools"
cp "$X" "$tmp/x"
cp "$ROOT/tools/mpfs-env.sh" "$ROOT/tools/toolchain.env" "$tmp/tools/"
TX="$tmp/x"
expect_rc "new creates an example"      0       "$TX" new smoke
expect_rc "new refuses an existing one" nonzero "$TX" new smoke
expect_rc "new rejects a bad name"      nonzero "$TX" new Bad-Name
expect_rc "list shows the new example"  0       "$TX" list
"$TX" list | grep -q '^smoke ' && pass "list contains smoke" || fail "list contains smoke"

expect_rc "build: invalid hart"           nonzero "$TX" build smoke --hart foo
expect_rc "build: invalid priv"           nonzero "$TX" build smoke --priv x
expect_rc "build: invalid profile"        nonzero "$TX" build smoke -P bad
expect_rc "build: harts without u54"      nonzero "$TX" build smoke --harts 1-4
expect_rc "build: SMP with the E51"       nonzero "$TX" build smoke --hart e51 --harts 1,2
expect_rc "build: hart out of range"      nonzero "$TX" build smoke --hart u54 --harts 5
expect_rc "build: descending range"       nonzero "$TX" build smoke --hart u54 --harts 3-1
expect_rc "build: unknown option"         nonzero "$TX" build smoke --bogus
expect_rc "build: unknown example"        nonzero "$TX" build nope
expect_rc "qemu: invalid hart number"     nonzero "$TX" qemu smoke --hart 9
expect_rc "clean exits 0"                 0       "$TX" clean smoke

# Verbs with a missing implementation script must fail, not succeed silently.
for v in "analyze" "stack smoke" "prove" "svd merge" "pac generate" "hw probe" "metrics verify" "test qemu"; do
  # shellcheck disable=SC2086
  expect_rc "missing script: $v fails" nonzero "$TX" $v
done
expect_rc "bad subcommand: svd"   nonzero "$TX" svd bogus
expect_rc "bad subcommand: pac"   nonzero "$TX" pac bogus
expect_rc "bad subcommand: test"  nonzero "$TX" test bogus

# `toolchain install pac` selects the three toolchains and installs no optional crate
# (gnatprove, adalang_analyzer); the full install does. alr is a stub that logs its
# arguments, the other tools are already "installed" in a throwaway prefix.
stub="$(mktemp -d)"
trap 'rm -r "$tmp" "$stub"' EXIT
(
  . "$ROOT/tools/toolchain.env"
  mkdir -p "$stub/bin" "$stub/tools/svdtools-$SVDTOOLS_VERSION/bin" "$stub/tools/svd2ada-$SVD2ADA_COMMIT/bin" "$stub/tools/venv/bin"
  printf '#!/bin/sh\necho "$*" >> "$STUB_ALR_LOG"\n' > "$stub/bin/alr"
  printf '#!/bin/sh\nexit 0\n' > "$stub/tools/svdtools-$SVDTOOLS_VERSION/bin/svdtools"
  printf '#!/bin/sh\nexit 0\n' > "$stub/tools/svd2ada-$SVD2ADA_COMMIT/bin/svd2ada"
  printf '#!/bin/sh\nexit 1\n' > "$stub/tools/venv/bin/python"
  cp "$ROOT/tools/requirements.txt" "$stub/tools/venv/requirements.txt"
  chmod +x "$stub/bin/alr" "$stub/tools"/*/bin/*
  for target in pac full gnatprove adalang_analyzer; do
    : > "$stub/$target.log"
    arg="$target"; [ "$target" = full ] && arg=
    # shellcheck disable=SC2086
    PATH="$stub/bin:$PATH" STUB_ALR_LOG="$stub/$target.log" MPFS_TOOLS_PREFIX="$stub/tools" \
      MPFS_ADA_TOOLCHAINS="$stub/none" "$X" toolchain install $arg >/dev/null 2>&1 || true
  done
)
for tc in "gprbuild=" "gnat_riscv64_elf=" "gnat_native="; do
  for target in pac full; do
    grep -q "^-n toolchain --select $tc" "$stub/$target.log" \
      && pass "toolchain install ($target) selects $tc" || fail "toolchain install ($target) selects $tc"
  done
done
grep -q "gnatprove\|adalang_analyzer" "$stub/pac.log" \
  && fail "toolchain install pac installs no optional crate" || pass "toolchain install pac installs no optional crate"
grep -q "gnatprove" "$stub/full.log" && grep -q "adalang_analyzer" "$stub/full.log" \
  && pass "toolchain install (full) installs gnatprove and adalang_analyzer" \
  || fail "toolchain install (full) installs gnatprove and adalang_analyzer"

# Installing one optional crate installs that crate only.
grep -q "^-n install --prefix=.*gnatprove-.* gnatprove=" "$stub/gnatprove.log" && ! grep -q "adalang_analyzer" "$stub/gnatprove.log" \
  && pass "toolchain install gnatprove installs gnatprove only" || fail "toolchain install gnatprove installs gnatprove only"
grep -q "^-n install --prefix=.*adalang_analyzer-.* adalang_analyzer=" "$stub/adalang_analyzer.log" && ! grep -q "gnatprove=" "$stub/adalang_analyzer.log" \
  && pass "toolchain install adalang_analyzer installs adalang_analyzer only" || fail "toolchain install adalang_analyzer installs adalang_analyzer only"

# Tab completion: ./x completion prints a script that completes verbs, sub-commands and examples.
comp () {   # comp <words...> : completions for the command line "./x <words...>" (last word is partial)
  bash -c 'source <("$1" completion bash); shift; COMP_WORDS=(./x "$@"); COMP_CWORD=$(( ${#COMP_WORDS[@]} - 1 ));
           _mpfs_x; printf "%s\n" "${COMPREPLY[@]}"' _ "$X" "$@" 2>&1
}
expect_rc "completion zsh prints a script" 0 "$X" completion zsh
expect_rc "completion rejects another shell" nonzero "$X" completion fish
case " $(comp hw b | tr '\n' ' ') " in *" bootmode "*) pass "completion: ./x hw b -> bootmode" ;; *) fail "completion: ./x hw b -> bootmode" ;; esac
case " $(comp build bare_h | tr '\n' ' ') " in *" bare_hello "*) pass "completion: ./x build bare_h -> bare_hello" ;; *) fail "completion: ./x build bare_h -> bare_hello" ;; esac
case " $(comp te | tr '\n' ' ') " in *" test "*) pass "completion: ./x te -> test" ;; *) fail "completion: ./x te -> test" ;; esac
[ "$(comp build bare_hello --hart '' | tr '\n' ' ')" = "e51 u54 " ] && pass "completion: --hart offers e51 and u54" || fail "completion: --hart offers e51 and u54"
for verb in help list toolchain build clean new qemu mem test metrics analyze stack svd pac trace prove hw completion; do
  case " $(comp '' | tr '\n' ' ') " in *" $verb "*) ;; *) fail "completion: verb $verb missing"; break ;; esac
done

# export.sh loads the completion in an interactive bash only.
[ "$(bash -ic ". '$ROOT/export.sh' >/dev/null 2>&1; complete -p x" 2>/dev/null)" = "complete -o default -F _mpfs_x x" ] \
  && pass "export.sh enables the completion in an interactive bash" || fail "export.sh enables the completion in an interactive bash"
bash -c ". '$ROOT/export.sh' >/dev/null 2>&1; type _mpfs_x" >/dev/null 2>&1 \
  && fail "export.sh leaves a non-interactive shell alone" || pass "export.sh leaves a non-interactive shell alone"

# export.sh puts x on PATH; it runs this repository's ./x from any directory.
[ "$(cd / && bash -c ". '$ROOT/export.sh' >/dev/null 2>&1; x help" | head -1)" = "$("$X" help | head -1)" ] \
  && pass "export.sh puts x on PATH" || fail "export.sh puts x on PATH"

echo "summary: $fails failure(s)"
[ $fails -eq 0 ]
