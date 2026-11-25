#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Smoke test for ./x: every verb is listed in the help, option validation rejects
# invalid and excluded combinations, and missing tool scripts fail instead of
# passing silently; `toolchain pins` (the cache key of the CI toolchain action) and `toolchain prune`. Exits non-zero on any failure.

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

case "$help" in *"./x hw bootmode|flashpros|openocd|run|debug|probe|monitor|reset"*) pass "help lists hw bootmode" ;; *) fail "help lists hw bootmode" ;; esac

# ./x hw prints a full help (also with help, -h and --help), needs no toolchain for it, lists every command that it dispatches and
# the settings, and an unknown command is an error that points to it
hwhelp="$("$X" hw 2>&1)"
expect_rc "./x hw prints the help and exits 0" 0 "$X" hw
for c in bootmode flashpros openocd run debug probe monitor reset initialize program; do
  case "$hwhelp" in *"./x hw $c"*) pass "hw help lists $c" ;; *) fail "hw help lists $c" ;; esac
done
for a in help -h --help; do
  [ "$("$X" hw "$a" 2>&1)" = "$hwhelp" ] && pass "./x hw $a prints the same help" || fail "./x hw $a prints the same help"
done
case "$hwhelp" in *"./x hw program --scan"*) pass "hw help lists program --scan" ;; *) fail "hw help lists program --scan" ;; esac
case "$hwhelp" in *"--lab F"*"FLASHPRO_USB_LOCATION"*"OCD_TCK_MHZ"*"BOOTMODE_DIE"*) pass "hw help names the options --lab and the keys of lab.conf" ;; *) fail "hw help names the options --lab and the keys of lab.conf" ;; esac
case "$hwhelp" in *"COMMAND --help"*) pass "hw help says how to get the options of one command" ;; *) fail "hw help says how to get the options of one command" ;; esac
expect_rc "./x hw with an unknown command fails" nonzero "$X" hw nosuch
case "$("$X" hw nosuch 2>&1)" in *"unknown command 'hw nosuch'"*"./x hw help"*) pass "an unknown hw command names itself and points to ./x hw help" ;; *) fail "an unknown hw command names itself and points to ./x hw help" ;; esac

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
# toolchain check reports Microchip's OpenOCD: absent without it, ok with a working one in its prefix,
# an error with one that does not run
(
  . "$ROOT/tools/toolchain.env"
  rp="$(mktemp -d)"
  case "$(MPFS_TOOLS_PREFIX="$rp" "$X" toolchain check 2>&1)" in
    *"openocd              absent"*) pass "toolchain check reports a missing OpenOCD as absent" ;;
    *) fail "toolchain check reports a missing OpenOCD as absent" ;;
  esac
  mkdir -p "$rp/openocd-$OPENOCD_VERSION/bin"
  printf '#!/bin/sh\necho "xPack Open On-Chip Debugger 0.12.0"\n' > "$rp/openocd-$OPENOCD_VERSION/bin/openocd"; chmod +x "$rp/openocd-$OPENOCD_VERSION/bin/openocd"
  case "$(MPFS_TOOLS_PREFIX="$rp" "$X" toolchain check 2>&1)" in
    *"openocd              ok"*) pass "toolchain check finds the OpenOCD of the prefix" ;;
    *) fail "toolchain check finds the OpenOCD of the prefix" ;;
  esac
  printf '#!/bin/sh\nexit 1\n' > "$rp/openocd-$OPENOCD_VERSION/bin/openocd"
  case "$(MPFS_TOOLS_PREFIX="$rp" "$X" toolchain check 2>&1)" in
    *"openocd              ERROR"*) pass "toolchain check reports an OpenOCD that does not run" ;;
    *) fail "toolchain check reports an OpenOCD that does not run" ;;
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
[ "$(comp hw run --view '' | tr '\n' ' ')" = "auto live interleaved blocks " ] && pass "completion: --view offers the views" || fail "completion: --view offers the views"
[ "$(comp hw monitor --color '' | tr '\n' ' ')" = "auto always never " ] && pass "completion: --color offers auto, always and never" || fail "completion: --color offers auto, always and never"
for o in --view --color; do
  case " $(comp hw monitor -- | tr '\n' ' ') " in *" $o "*) pass "completion: ./x hw monitor offers $o" ;; *) fail "completion: ./x hw monitor offers $o" ;; esac
  case " $(comp hw run x -- | tr '\n' ' ') " in *" $o "*) pass "completion: ./x hw run offers $o" ;; *) fail "completion: ./x hw run offers $o" ;; esac
done
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

# ./x test lib (tools/test_lib.sh) with a stand-in gprbuild: both ABIs per project, a warning or an
# error fails, *_prove.gpr is skipped, warnings from src/generated do not count.
tl="$(mktemp -d)"; mkdir -p "$tl/libs/good" "$tl/libs/warn" "$tl/libs/bad" "$tl/libs/gen" "$tl/libs/good_prove"
for l in good warn bad gen; do : > "$tl/libs/$l/$l.gpr"; done; : > "$tl/libs/good_prove/good_prove.gpr"
cat > "$tl/gprbuild" <<'GB'
#!/bin/sh
echo "$*" >> "$TL_LOG"
case "$*" in
  *warn.gpr*) echo "warn_pkg.adb:3:4: warning: unused variable" ;;
  *bad.gpr*)  echo "bad_pkg.adb:1:1: error: syntax"; exit 4 ;;
  *gen.gpr*)  echo "src/generated/x.ads:1:1: warning: ignored" ;;
esac
GB
chmod +x "$tl/gprbuild"
tlib () { TL_LOG="$tl/log" LIBS="$tl/libs" GPRBUILD="$tl/gprbuild" "$@"; }
: > "$tl/log"
expect_rc  "test lib: a clean library passes on both ABIs" 0 tlib "$X" test lib good
[ "$(grep -c 'MPFS_HART=' "$tl/log")" = 2 ] && grep -q -- '-XMPFS_HART=e51.*-march=rv64imac_zicsr_zifencei -mabi=lp64' "$tl/log" \
  && grep -q -- '-XMPFS_HART=u54.*-march=rv64imafdc_zicsr_zifencei -mabi=lp64d' "$tl/log" \
  && pass "test lib: e51 and u54 get their march and mabi" || fail "test lib: e51 and u54 get their march and mabi"
expect_rc  "test lib: a warning fails" nonzero tlib "$X" test lib warn
case "$(tlib "$X" test lib warn 2>&1)" in *"unused variable"*) pass "test lib: the warning is shown" ;; *) fail "test lib: the warning is shown" ;; esac
expect_rc  "test lib: an error fails" nonzero tlib "$X" test lib bad
expect_rc  "test lib: a warning from src/generated does not count" 0 tlib "$X" test lib gen
expect_rc  "test lib: an unknown library is an error" nonzero tlib "$X" test lib nosuch
: > "$tl/log"; tlib "$X" test lib good warn >/dev/null 2>&1
grep -q good_prove "$tl/log" && fail "test lib: *_prove.gpr is skipped" || pass "test lib: *_prove.gpr is skipped"
: > "$tl/log"; rm -rf "$tl/libs/warn" "$tl/libs/bad"; tlib "$X" test lib >/dev/null 2>&1
[ "$(grep -c 'MPFS_HART=' "$tl/log")" = 4 ] && pass "test lib: without a name every library is built" || fail "test lib: without a name every library is built"
rm -rf "$tl"

# toolchain pins <target>: the pins that the install of a target reads, which CI hashes into the
# cache key of .github/actions/toolchain. A copy of x and the pin files in a scratch tree, so that
# the pins can be changed.
pt="$(mktemp -d)"; mkdir -p "$pt/tools"
cp "$X" "$pt/x"; cp "$ROOT/tools/mpfs-env.sh" "$ROOT/tools/toolchain.env" "$pt/tools/"
PX="$pt/x"
targets="svdtools svd2ada pac alire gnat gnatprove adalang_analyzer renode openocd"
# The variables of tools/toolchain.env that no install reads (the OS provides the tool).
unused="QEMU_MIN"
pin_names () { "$PX" toolchain pins "$1" 2>/dev/null | cut -d= -f1 | tr '\n' ' '; }
want_names () {
  case "$1" in
    alire)            echo "ALR_SHA256_UNIVERSAL_MACOS ALR_SHA256_X86_64_LINUX ALR_SHA256_X86_64_WINDOWS ALR_VERSION " ;;
    gnat)             echo "$(want_names alire)GNAT_NATIVE_VERSION GNAT_RISCV64_VERSION GPRBUILD_VERSION " ;;
    gnatprove)        echo "$(want_names gnat)GNATPROVE_VERSION " ;;
    adalang_analyzer) echo "$(want_names gnat)ADALANG_ANALYZER_VERSION " ;;
    svdtools)         echo "SVDTOOLS_RUSTC_MIN SVDTOOLS_SHA256_AARCH64_DARWIN SVDTOOLS_SHA256_X86_64_LINUX SVDTOOLS_SHA256_X86_64_WINDOWS SVDTOOLS_VERSION " ;;
    svd2ada)          echo "$(want_names gnat)SVD2ADA_COMMIT SVD2ADA_REF SVD2ADA_REPO " ;;
    pac)              echo "$(want_names gnat)PYTHON_MIN SVD2ADA_COMMIT SVD2ADA_REF SVD2ADA_REPO $(want_names svdtools)" ;;
    renode)           echo "RENODE_SHA256_AARCH64_DARWIN RENODE_SHA256_X86_64_LINUX RENODE_VERSION " ;;
    openocd)          echo "OPENOCD_SHA256_X86_64_LINUX OPENOCD_VERSION OPENOCD_XPACK " ;;
  esac | tr ' ' '\n' | grep . | LC_ALL=C sort | tr '\n' ' '
}

# the lines of each target: the variables it reads, sorted, with the values of the pin file
for t in $targets; do
  out="$("$PX" toolchain pins "$t" 2>&1)"
  [ "$(pin_names "$t")" = "$(want_names "$t")" ] && pass "pins $t: the variables it reads" \
    || fail "pins $t: the variables it reads (got: $(pin_names "$t"))"
  [ "$out" = "$(printf '%s\n' "$out" | LC_ALL=C sort)" ] && pass "pins $t: sorted" || fail "pins $t: sorted"
  ( . "$ROOT/tools/toolchain.env"
    ok=1; while IFS== read -r n v; do [ "${!n}" = "$v" ] || ok=0; done <<<"$out"; [ "$ok" = 1 ] ) \
    && pass "pins $t: NAME=value of tools/toolchain.env" || fail "pins $t: NAME=value of tools/toolchain.env"
done

# an unknown target, none and two targets fail and print no pins
for bad in nosuch "" "gnat pac"; do
  out="$("$PX" toolchain pins $bad 2>/dev/null)"; rc=$?
  [ $rc -ne 0 ] && [ -z "$out" ] && pass "pins '$bad': fails without output" || fail "pins '$bad': fails without output (exit $rc)"
done

# comments, blank lines, quoting and the order of the lines do not change any target
declare -A base
for t in $targets; do base[$t]="$("$PX" toolchain pins "$t")"; done
{ echo "# another comment"; echo; grep -v '^#' "$ROOT/tools/toolchain.env" | grep . | tac \
    | sed -E 's/^(ALR_VERSION|RENODE_VERSION)=(.*)$/\1="\2"/'; echo "# last"; } > "$pt/tools/toolchain.env"
same=1; for t in $targets; do [ "$("$PX" toolchain pins "$t")" = "${base[$t]}" ] || same=0; done
[ $same = 1 ] && pass "pins: comments, blank lines, quoting and order change no target" \
  || fail "pins: comments, blank lines, quoting and order change no target"
cp "$ROOT/tools/toolchain.env" "$pt/tools/toolchain.env"

# every variable: it changes the output of the targets that read it and of no other target; every
# variable but the unused ones is read by some target
all_vars="$(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$ROOT/tools/toolchain.env")"
for v in $all_vars; do
  sed -E "s/^$v=.*/$v=9.9/" "$ROOT/tools/toolchain.env" > "$pt/tools/toolchain.env"
  readers=""; wrong=""
  for t in $targets; do
    got="$("$PX" toolchain pins "$t")"
    case " $(want_names "$t")" in *" $v "*) reads=1; readers="$readers $t" ;; *) reads=0 ;; esac
    if [ "$reads" = 1 ] && [ "$got" = "${base[$t]}" ]; then wrong="$wrong $t(unchanged)"; fi
    if [ "$reads" = 0 ] && [ "$got" != "${base[$t]}" ]; then wrong="$wrong $t(changed)"; fi
  done
  case " $unused " in
    *" $v "*) [ -z "$readers" ] || wrong="$wrong read-by:$readers" ;;
    *) [ -n "$readers" ] || wrong="$wrong read-by-nobody" ;;
  esac
  [ -z "$wrong" ] && pass "pins: $v changes${readers:- no target}" || fail "pins: $v:$wrong"
done
cp "$ROOT/tools/toolchain.env" "$pt/tools/toolchain.env"
rm -rf "$pt"

# A cache restored from an older pin never supplies the old version: the install looks for the
# pinned version only, installs it next to the old one, and prune removes the old one.
(
  . "$ROOT/tools/toolchain.env"
  rp="$(mktemp -d)"; tp="$rp/tools"; tc="$rp/toolchains"; sb="$rp/bin"
  mkdir -p "$sb" "$tp/alr-$ALR_VERSION/bin" "$tp/gnatprove-0.0.1/bin" "$tp/svdtools-0.0.1/bin" "$tp/venv" \
           "$tc/gnat_native_0.0.1_abc/bin" "$tc/gnat_native_${GNAT_NATIVE_VERSION}_def/bin" "$tc/unrelated"
  printf '#!/bin/sh\necho "gnatprove 0.0.1"\n' > "$tp/gnatprove-0.0.1/bin/gnatprove"; chmod +x "$tp/gnatprove-0.0.1/bin/gnatprove"
  # a stand-in for alr: records the calls and creates the prefix of an install
  cat > "$sb/alr" <<'ALR'
#!/bin/sh
echo "$*" >> "$ALR_LOG"
case "$*" in *"install --prefix="*) p="${*#*--prefix=}"; mkdir -p "${p%% *}/bin" ;; esac
ALR
  chmod +x "$sb/alr"
  line="$(PATH="$sb:$PATH" MPFS_TOOLS_PREFIX="$tp" MPFS_ADA_TOOLCHAINS="$tc" "$X" toolchain check 2>&1 | grep '^  gnatprove ')"
  case "$line" in *0.0.1*) fail "restored cache: the older gnatprove is not used by check ($line)" ;;
                  *) pass "restored cache: the older gnatprove is not used by check" ;; esac
  : > "$rp/log"
  ALR_LOG="$rp/log" PATH="$sb:$PATH" MPFS_TOOLS_PREFIX="$tp" MPFS_ADA_TOOLCHAINS="$tc" "$X" toolchain install gnatprove >/dev/null 2>&1
  grep -q -- "install --prefix=$tp/gnatprove-$GNATPROVE_VERSION gnatprove=$GNATPROVE_VERSION" "$rp/log" \
    && pass "restored cache: the pinned gnatprove is installed next to the older one" \
    || fail "restored cache: the pinned gnatprove is installed next to the older one ($(tr '\n' ';' < "$rp/log"))"
  [ -d "$tp/gnatprove-0.0.1" ] && pass "install keeps an older version in its prefix" || fail "install keeps an older version in its prefix"
  out="$(MPFS_TOOLS_PREFIX="$tp" MPFS_ADA_TOOLCHAINS="$tc" "$X" toolchain prune 2>&1)"; rc=$?
  gone=1; for d in "$tp/gnatprove-0.0.1" "$tp/svdtools-0.0.1" "$tc/gnat_native_0.0.1_abc"; do [ ! -e "$d" ] || gone=0; done
  kept=1; for d in "$tp/alr-$ALR_VERSION" "$tp/gnatprove-$GNATPROVE_VERSION" "$tp/venv" "$tc/gnat_native_${GNAT_NATIVE_VERSION}_def" "$tc/unrelated"; do [ -e "$d" ] || kept=0; done
  [ $rc -eq 0 ] && [ $gone = 1 ] && pass "prune removes the versions that are not pinned" || fail "prune removes the versions that are not pinned ($out)"
  [ $kept = 1 ] && pass "prune keeps the pinned versions, the venv and unknown directories" || fail "prune keeps the pinned versions, the venv and unknown directories"
  rm -rf "$rp"
)

echo "summary: $fails failure(s)"
[ $fails -eq 0 ]
