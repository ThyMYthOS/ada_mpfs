#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
# Derived from rowsail/ada_esp32s3 x @ d75142d (Apache-2.0); modified for PolarFire SoC.
#
#  x -- one command surface for the bare-metal Ada / PolarFire SoC project.
#
#  Usage:
#    ./x help                          this text
#    ./x list [--json]                 list examples (name, default hart, dir)
#    ./x toolchain install|check       install the toolchains pinned in
#                                      tools/toolchain.env / report deviations
#    ./x build <ex> [-P PROFILE] [--hart e51|u54] [--harts 1-4] [--priv m|u]
#                                      build an example (PROFILE: light|
#                                      light-tasking|embedded|auto). --harts is
#                                      a U54 hart set, e.g. 2, 1-4 or 1,3
#    ./x clean [<ex>]                  remove build artifacts (all if omitted)
#    ./x new <name>                    scaffold examples/<name>
#    ./x qemu <ex> [--hart N]          build and run under QEMU (microchip-icicle-kit)
#                                      with a watchdog; N=0 is the E51, 1-4 a U54
#    ./x mem <ex> [--hart e51|u54]     section sizes per memory region
#    ./x test host|lib|examples|qemu|negative|metrics
#                                      everything checkable without a board
#    ./x metrics verify|bless          compare / re-bless metrics.golden
#    ./x analyze [--style] [--update-baseline]   static analysis
#    ./x stack <ex>                    static stack analysis
#    ./x svd merge|check|probe         SVD assembly and checks
#    ./x pac generate|check            register package generation and checks
#    ./x trace [--check]               requirement trace matrix
#    ./x prove                         SPARK proofs
#    ./x hw run|probe|monitor          run images on the Icicle Kit
#
#  <ex> is the directory name below examples/.  Every failure exits non-zero.

set -euo pipefail
#  BASH_SOURCE[0] (not $0) so ROOT is right when x is SOURCED as a library too.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXROOT="$ROOT/examples"
ADA_MPFS_SDK="$ROOT"; export ADA_MPFS_SDK

die () { echo "x: $*" >&2; exit 1; }

# -- toolchain ----------------------------------------------------------------
# Download the svdtools release binary for this platform into prefix $1 and
# verify its SHA-256. Returns 2 if there is no binary for this platform.
mpfs_install_svdtools_binary () {
  local pfx="$1" target want ext=gz exe=svdtools url tmp
  case "$(uname -sm)" in
    "Linux x86_64")   target=x86_64-unknown-linux-gnu; want="$SVDTOOLS_SHA256_X86_64_LINUX" ;;
    "Darwin arm64")   target=aarch64-apple-darwin;     want="$SVDTOOLS_SHA256_AARCH64_DARWIN" ;;
    MINGW*" x86_64"|MSYS*" x86_64"|CYGWIN*" x86_64")
                      target=x86_64-pc-windows-msvc;   want="$SVDTOOLS_SHA256_X86_64_WINDOWS"
                      ext=zip; exe=svdtools.exe ;;
    *) return 2 ;;
  esac
  url="https://github.com/rust-embedded/svdtools/releases/download/v$SVDTOOLS_VERSION/svdtools-$target.$ext"
  tmp="$(mktemp)" || return 1
  if curl -fsSL -o "$tmp" "$url" \
     && [ "$(openssl dgst -sha256 "$tmp" | sed 's/.* //')" = "$want" ]; then
    mkdir -p "$pfx/bin" || return 1
    if [ "$ext" = zip ]; then
      python3 -c 'import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extract("svdtools.exe", sys.argv[2])' "$tmp" "$pfx/bin"
    else
      gzip -dc "$tmp" > "$pfx/bin/$exe"
    fi && chmod +x "$pfx/bin/$exe"
  else
    echo "x: downloading or verifying $url failed" >&2
    rm -f "$tmp"; return 1
  fi
  rm -f "$tmp"
}

# Installs the pinned Alire release into $1 (bin/alr). Returns 2 where no
# release binary exists for the platform.
mpfs_install_alr () {
  local pfx="$1" asset want ext=zip url tmp
  case "$(uname -sm)" in
    "Linux x86_64")   asset=bin-x86_64-linux;    want="$ALR_SHA256_X86_64_LINUX" ;;
    "Darwin "*)       asset=bin-universal-macos; want="$ALR_SHA256_UNIVERSAL_MACOS" ;;
    MINGW*" x86_64"|MSYS*" x86_64"|CYGWIN*" x86_64")
                      asset=installer-x86_64-windows; want="$ALR_SHA256_X86_64_WINDOWS"
                      ext=exe ;;
    *) return 2 ;;
  esac
  url="https://github.com/alire-project/alire/releases/download/v$ALR_VERSION/alr-$ALR_VERSION-$asset.$ext"
  tmp="$(mktemp)" || return 1
  if curl -fsSL -o "$tmp" "$url" \
     && [ "$(openssl dgst -sha256 "$tmp" | sed 's/.* //')" = "$want" ]; then
    mkdir -p "$pfx" || return 1
    if [ "$ext" = zip ]; then
      python3 -c 'import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extract("bin/alr", sys.argv[2])' "$tmp" "$pfx" \
        && chmod +x "$pfx/bin/alr"
    else
      # Inno Setup installer: unattended, into the prefix
      mv "$tmp" "$tmp.exe" && tmp="$tmp.exe" \
        && "$tmp" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART "/DIR=$(cygpath -w "$pfx")"
    fi
  else
    echo "x: downloading or verifying $url failed" >&2
    rm -f "$tmp"; return 1
  fi
  local rc=$?
  rm -f "$tmp"; return $rc
}

cmd_toolchain () {
  local sub="${1:-}"; shift || true
  # shellcheck source=tools/mpfs-env.sh
  . "$ROOT/tools/mpfs-env.sh"
  case "$sub" in
    install)
      if ! command -v alr >/dev/null 2>&1; then
        local apfs; apfs="$(mpfs_opt_prefix alr "$ALR_VERSION")"
        [ -x "$apfs/bin/alr" ] || [ -x "$apfs/bin/alr.exe" ] || mpfs_install_alr "$apfs" \
          || die "alr not found and no Alire $ALR_VERSION could be installed; see https://alire.ada.dev"
        export PATH="$apfs/bin:$PATH"
      fi
      # `--select` is the only way to get a toolchain onto disk; one call per
      # toolchain (alr 2.1.0). Nothing in the build calls `alr`: the toolchains
      # only need to exist where MPFS_ADA_TOOLCHAINS looks.
      alr -n toolchain --select "gprbuild=$GPRBUILD_VERSION"
      alr -n toolchain --select "gnat_riscv64_elf=$GNAT_RISCV64_VERSION"
      alr -n toolchain --select "gnat_native=$GNAT_NATIVE_VERSION"
      # Optional crates are installed, not selected, each version into its own
      # prefix: no conflict with other versions, no --force, repeatable.
      local crate ver pfx
      for crate in gnatprove:"$GNATPROVE_VERSION" adalang_analyzer:"$ADALANG_ANALYZER_VERSION"; do
        ver="${crate#*:}"; crate="${crate%%:*}"
        [ -n "$ver" ] || continue
        pfx="$(mpfs_opt_prefix "$crate" "$ver")"
        if [ -d "$pfx/bin" ]; then echo "x: $crate $ver already installed in $pfx"
        else alr -n install --prefix="$pfx" "$crate=$ver" || die "installing $crate $ver failed"; fi
      done
      pfx="$(mpfs_opt_prefix svdtools "$SVDTOOLS_VERSION")"
      if [ -x "$pfx/bin/svdtools" ] || [ -x "$pfx/bin/svdtools.exe" ]; then
        echo "x: svdtools $SVDTOOLS_VERSION already installed in $pfx"
      elif mpfs_install_svdtools_binary "$pfx"; then
        echo "x: installed svdtools $SVDTOOLS_VERSION in $pfx"
      elif [ $? -ne 2 ]; then
        die "installing svdtools $SVDTOOLS_VERSION failed"
      elif ! command -v cargo >/dev/null 2>&1; then
        echo "x: cargo not found; skipping svdtools $SVDTOOLS_VERSION (install Rust with https://rustup.rs)" >&2
      else
        ver="$(mpfs_version_of rustc --version)"
        if [ -n "$ver" ] && mpfs_version_ge "$ver" "$SVDTOOLS_RUSTC_MIN"; then
          cargo install --locked --root "$pfx" svdtools --version "$SVDTOOLS_VERSION" \
            || die "installing svdtools $SVDTOOLS_VERSION failed"
        else
          echo "x: rustc ${ver:-?} is older than $SVDTOOLS_RUSTC_MIN; skipping svdtools $SVDTOOLS_VERSION" >&2
          echo "x: run 'rustup update stable' (https://rustup.rs) and repeat ./x toolchain install" >&2
        fi
      fi
      mpfs_toolchain_on_path || true
      mpfs_toolchain_check
      ;;
    check)
      mpfs_toolchain_on_path || true
      mpfs_toolchain_check
      ;;
    *) die "usage: ./x toolchain install|check" ;;
  esac
}

# -- examples -----------------------------------------------------------------
#  An example is a directory examples/<name>/ with an app.gpr (build contract:
#  examples/STYLE.md) and optionally an example.conf (KEY=value lines).
list_dirs () {
  local d
  for d in "$EXROOT"/*/; do
    [ -f "${d}app.gpr" ] && basename "$d"
  done | sort
}

#  conf_get <dir> <KEY> <default>
conf_get () {
  local v=""
  if [ -f "$EXROOT/$1/example.conf" ]; then
    v="$(sed -n "s/^$2=//p" "$EXROOT/$1/example.conf" | head -1)"
  fi
  echo "${v:-$3}"
}

resolve () {
  local n="${1:-}"
  [ -n "$n" ] || die "missing <example> (try './x list')"
  case "$n" in */*|.*) die "invalid example name '$n'" ;; esac
  [ -f "$EXROOT/$n/app.gpr" ] || die "no such example: $n (try './x list')"
  echo "$n"
}

cmd_list () {
  local d first=1
  if [ "${1:-}" = --json ]; then
    printf '['
    for d in $(list_dirs); do
      [ $first -eq 1 ] || printf ','; first=0
      printf '{"name":"%s","dir":"examples/%s","hart":"%s"}' \
             "$d" "$d" "$(conf_get "$d" HART e51)"
    done
    printf ']\n'
  else
    printf '%-24s %-6s %s\n' NAME HART DIR
    for d in $(list_dirs); do
      printf '%-24s %-6s %s\n' "$d" "$(conf_get "$d" HART e51)" "examples/$d"
    done
  fi
}

# -- build --------------------------------------------------------------------
#  Option values are validated here even where a build does not use them yet:
#  an invalid or excluded combination must fail early and the same way everywhere.
valid_hart ()    { case "$1" in e51|u54) ;; *) die "invalid --hart '$1' (e51|u54)" ;; esac; }
valid_priv ()    { case "$1" in m|u) ;; *) die "invalid --priv '$1' (m|u)" ;; esac; }
valid_profile () {
  case "$1" in
    auto|light|light-tasking|embedded) ;;
    *) die "invalid profile '$1' (light|light-tasking|embedded|auto)" ;;
  esac
}
#  A set of U54 harts: N, N-M or a comma list of those, each in 1..4.
valid_harts () {
  local item a b
  [ -n "$1" ] || die "empty --harts"
  local IFS=,
  for item in $1; do
    case "$item" in
      [1-4]) ;;
      [1-4]-[1-4]) a="${item%-*}"; b="${item#*-}"
                   [ "$a" -lt "$b" ] || die "invalid --harts range '$item'" ;;
      *) die "invalid --harts '$1' (harts 1-4, e.g. 2, 1-4 or 1,3)" ;;
    esac
  done
}

B_PROF=auto; B_HART=""; B_HARTS=""; B_PRIV=m
parse_build_opts () {   # sets B_*; call with the options after <example>
  B_PROF=auto; B_HART=""; B_HARTS=""; B_PRIV=m
  while [ $# -gt 0 ]; do
    case "$1" in
      -P|--profile) [ $# -ge 2 ] || die "$1 needs a value"; B_PROF="$2"; shift 2 ;;
      --hart)       [ $# -ge 2 ] || die "$1 needs a value"; B_HART="$2"; shift 2 ;;
      --harts)      [ $# -ge 2 ] || die "$1 needs a value"; B_HARTS="$2"; shift 2 ;;
      --priv)       [ $# -ge 2 ] || die "$1 needs a value"; B_PRIV="$2"; shift 2 ;;
      *) die "unknown option '$1'" ;;
    esac
  done
}

#  Validate B_* ($1 = default hart of the example).
check_build_opts () {
  [ -n "$B_HART" ] || B_HART="$1"
  valid_hart "$B_HART"; valid_priv "$B_PRIV"; valid_profile "$B_PROF"
  if [ -n "$B_HARTS" ]; then
    valid_harts "$B_HARTS"
    [ "$B_HART" = u54 ] || die "--harts needs --hart u54 (SMP with the E51 is excluded)"
  fi
}

toolchain_ready () {
  # shellcheck source=tools/mpfs-env.sh
  . "$ROOT/tools/mpfs-env.sh"
  mpfs_toolchain_on_path || die "pinned toolchain missing (try './x toolchain install')"
}

#  Build one example; leaves the ELF path in B_ELF.  Warnings are errors: the
#  project files set -gnatwe, and any compiler warning outside generated/ that
#  still gets through fails the build as well.
B_ELF=""
build_example () {
  local e="$1"; shift
  parse_build_opts "$@"
  check_build_opts "$(conf_get "$e" HART e51)"
  toolchain_ready
  local log rc=0
  log="$(mktemp)"
  ( cd "$EXROOT/$e" && gprbuild -p -P app.gpr \
        -XMPFS_HART="$B_HART" -XMPFS_PRIV="$B_PRIV" -XMPFS_PROFILE="$B_PROF" \
        -XMPFS_HARTS="$B_HARTS" ) >"$log" 2>&1 || rc=$?
  cat "$log"
  #  Compiler warnings only (file.ad[sb]:line:col: warning:); linker notes about
  #  the shipped runtime's link script are not ours to fix.
  if [ $rc -eq 0 ] && grep -E '\.ad[sb]:[0-9]+:[0-9]+: (\(style\) )?warning:' "$log" \
       | grep -qv '/generated/'; then
    echo "x: warnings are errors" >&2; rc=1
  fi
  rm -f "$log"
  [ $rc -eq 0 ] || die "build of $e failed"
  B_ELF="$(find "$EXROOT/$e/bin-$B_HART" -maxdepth 1 -name '*.elf' 2>/dev/null | sort | head -1)"
  [ -n "$B_ELF" ] || die "build of $e produced no bin-$B_HART/*.elf (see examples/STYLE.md)"
}

cmd_build () {
  local e; e="$(resolve "${1:-}")"; shift || true
  build_example "$e" "$@"
  echo "x: built ${B_ELF#"$ROOT"/}"
}

cmd_clean () {
  local dirs d
  if [ -n "${1:-}" ]; then dirs="$(resolve "$1")"; else dirs="$(list_dirs)"; fi
  for d in $dirs; do
    [ -n "$d" ] || continue
    find "$EXROOT/$d" -maxdepth 1 \( -name 'obj-*' -o -name 'bin-*' \) -exec rm -r {} +
    echo "x: cleaned examples/$d"
  done
}

# -- new ----------------------------------------------------------------------
cmd_new () {
  local name="${1:-}"
  [ -n "$name" ] || die "usage: ./x new <name>   (lowercase letter first, then [a-z0-9_])"
  case "$name" in
    [!a-z]*|*[!a-z0-9_]*) die "invalid name '$name' -- lowercase letter first, then [a-z0-9_]" ;;
  esac
  local dir="$EXROOT/$name"
  [ -e "$dir" ] && die "examples/$name already exists"
  mkdir -p "$dir/src"
  #  The tag is assembled so that REUSE does not read it as a tag of this file.
  local spdx="SPDX"
  local hdr="--  ${spdx}-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
--  ${spdx}-License-Identifier: Apache-2.0"
  cat > "$dir/app.gpr" <<EOF
$hdr
--
--  Build contract: see examples/STYLE.md.

project App is
   type Hart_Kind is ("e51", "u54");
   type Priv_Kind is ("m", "u");
   Hart : Hart_Kind := external ("MPFS_HART", "e51");
   Priv : Priv_Kind := external ("MPFS_PRIV", "m");

   for Target use "riscv64-elf";
   for Runtime ("Ada") use "light-polarfiresoc";
   for Source_Dirs use ("src");
   for Object_Dir use "obj-" & Hart;
   for Exec_Dir use "bin-" & Hart;
   for Main use ("main.adb");

   package Builder is
      for Executable_Suffix use ".elf";
   end Builder;

   package Compiler is
      for Default_Switches ("Ada") use
        ("-O2", "-g", "-gnat2022", "-gnatwa", "-gnatwe", "-gnaty");
   end Compiler;
end App;
EOF
  cat > "$dir/src/main.adb" <<EOF
$hdr
--
--  $name: TODO describe the purpose.

procedure Main is
begin
   null;
end Main;
EOF
  cat > "$dir/example.conf" <<EOF
# ${spdx}-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# ${spdx}-License-Identifier: Apache-2.0
HART=e51
EOF
  cat > "$dir/README.md" <<EOF
# $name

TODO: what this example shows, how to build and run it:

    ./x build $name
    ./x qemu $name
EOF
  echo "x: created examples/$name"
}

# -- qemu ---------------------------------------------------------------------
cmd_qemu () {
  local e n="" timeout="${QEMU_TIMEOUT:-20}" opts=()
  e="$(resolve "${1:-}")"; shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --hart) [ $# -ge 2 ] || die "--hart needs a value"; n="$2"; shift 2 ;;
      *) die "unknown option '$1'" ;;
    esac
  done
  case "$n" in
    "")    ;;
    0)     opts=(--hart e51) ;;
    [1-4]) opts=(--hart u54 --harts "$n") ;;
    *)     die "invalid --hart '$n' (0 = E51, 1-4 = U54)" ;;
  esac
  command -v qemu-system-riscv64 >/dev/null 2>&1 || die "qemu-system-riscv64 not found"
  build_example "$e" "${opts[@]}"
  echo "x: qemu-system-riscv64 -M microchip-icicle-kit (watchdog ${timeout}s)"
  #  A -kernel image never exits by itself; the watchdog ends the run, and its
  #  expiry is the normal end here.
  local rc=0
  timeout -s KILL "$timeout" qemu-system-riscv64 -M microchip-icicle-kit -m 2G \
      -nographic -serial mon:stdio -bios none -kernel "$B_ELF" -no-reboot || rc=$?
  case $rc in 0|124|137) ;; *) die "qemu failed (exit $rc)" ;; esac
}

# -- mem ----------------------------------------------------------------------
#  Loaded section sizes per memory region (region windows: the MPFS memory map
  #  as used by the linker scripts; addresses are decimal because mawk has no hex).
cmd_mem () {
  local e hart=""
  e="$(resolve "${1:-}")"; shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --hart) [ $# -ge 2 ] || die "--hart needs a value"; hart="$2"; shift 2 ;;
      *) die "unknown option '$1'" ;;
    esac
  done
  [ -n "$hart" ] || hart="$(conf_get "$e" HART e51)"
  valid_hart "$hart"
  toolchain_ready
  local elf
  elf="$(find "$EXROOT/$e/bin-$hart" -maxdepth 1 -name '*.elf' 2>/dev/null | sort | head -1)"
  [ -n "$elf" ] || die "no ELF for $e/$hart; build it first (./x build $e --hart $hart)"
  echo "== Loaded sections of $e ($hart), by region =="
  riscv64-elf-size -A "$elf" | awk '
    function region(a) {
      if (a >= 539033600 && a < 539164672) return "envm"
      if (a >= 16777216 && a < 16785408) return "dtim"
      if (a >= 25165824 && a < 25329664) return "itim"
      if (a >= 134217728 && a < 167772160) return "lim"
      if (a >= 167772160 && a < 201326592) return "scratchpad"
      if (a >= 2147483648) return "ddr"
      return "other"
    }
    $1 ~ /^\./ && $1 !~ /^\.(debug|comment|riscv|note|symtab|strtab|shstrtab)/ {
      size = $2 + 0; addr = $3 + 0
      if (size > 0 && addr > 0) {
        r = region(addr); used[r] += size
        printf "   %-20s %9d B  %s\n", $1, size, r
      }
    }
    END {
      print ""
      n = split("envm dtim itim lim scratchpad ddr other", order, " ")
      for (i = 1; i <= n; i++) if (used[order[i]] > 0)
        printf "   %-12s %9d B\n", order[i], used[order[i]]
    }'
}

# -- delegation to tool scripts ----------------------------------------------
#  Verbs whose implementation lives in tools/ or tests/.  A missing script is a
#  failure, never a silent success.
delegate () {   # delegate <script> [args...]
  local script="$1"; shift
  [ -f "$ROOT/$script" ] || die "not available yet: $script is missing"
  case "$script" in
    *.py) python3 "$ROOT/$script" "$@" ;;
    *)    bash "$ROOT/$script" "$@" ;;
  esac
}

cmd_test () {
  local sub="${1:-}"; shift || true
  case "$sub" in
    host)
      local s rc=0 n=0
      for s in "$ROOT"/tests/host/*/run.sh; do
        [ -f "$s" ] || continue
        n=$((n + 1))
        echo "== host suite $(basename "$(dirname "$s")")"
        bash "$s" || rc=1
      done
      [ $n -gt 0 ] || echo "x: no host suites found"
      [ $rc -eq 0 ] || die "host tests failed"
      ;;
    examples)
      local e rc=0 n=0
      for e in $(list_dirs); do
        n=$((n + 1))
        ( build_example "$e" ) || rc=1
      done
      [ $n -gt 0 ] || echo "x: no examples found"
      [ $rc -eq 0 ] || die "example builds failed"
      ;;
    lib)        delegate tools/test_lib.sh "$@" ;;
    qemu)       delegate tests/qemu/run_tests.sh "$@" ;;
    negative)   delegate tests/negative/run_negative.sh "$@" ;;
    metrics)    delegate tools/metrics.sh verify ;;
    *) die "usage: ./x test host|lib|examples|qemu|negative|metrics" ;;
  esac
}

cmd_metrics () {
  case "${1:-}" in
    verify|bless) delegate tools/metrics.sh "$@" ;;
    *) die "usage: ./x metrics verify|bless" ;;
  esac
}

cmd_svd () {
  case "${1:-}" in
    merge|check|probe) delegate tools/svd.sh "$@" ;;
    *) die "usage: ./x svd merge|check|probe" ;;
  esac
}

cmd_pac () {
  case "${1:-}" in
    generate|check) delegate tools/pac.sh "$@" ;;
    *) die "usage: ./x pac generate|check" ;;
  esac
}

cmd_trace () {
  case "${1:-}" in
    ""|--check) delegate tools/trace.py "$@" ;;
    *) die "usage: ./x trace [--check]" ;;
  esac
}

cmd_hw () {
  case "${1:-}" in
    run|probe|monitor) delegate tools/hw.sh "$@" ;;
    *) die "usage: ./x hw run|probe|monitor" ;;
  esac
}

# -- dispatch -----------------------------------------------------------------
# Skipped when this file is SOURCED, so helpers can be reused as a library.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  cmd="${1:-}"; shift || true
  case "$cmd" in
    list)            cmd_list "$@" ;;
    toolchain)       cmd_toolchain "$@" ;;
    build)           cmd_build "$@" ;;
    clean)           cmd_clean "$@" ;;
    new)             cmd_new "$@" ;;
    qemu)            cmd_qemu "$@" ;;
    mem)             cmd_mem "$@" ;;
    test)            cmd_test "$@" ;;
    metrics)         cmd_metrics "$@" ;;
    analyze)         delegate tools/analyze.sh "$@" ;;
    stack)           delegate tools/stack.sh "$@" ;;
    svd)             cmd_svd "$@" ;;
    pac)             cmd_pac "$@" ;;
    trace)           cmd_trace "$@" ;;
    prove)           delegate tools/prove.sh "$@" ;;
    hw)              cmd_hw "$@" ;;
    ""|-h|--help|help)
        # help = the leading comment block, from the "x --" line to its end
        awk '/^#  x --/ {p=1} p && !/^#/ {exit} p {sub(/^# {0,2}/, ""); print}' "$0" ;;
    *) die "unknown command '$cmd' (try './x help')" ;;
  esac
fi
