#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Register package generation:
#
#   pac.sh generate   regenerate libs/mpfs_pac/src/generated from the merged SVD and
#                     record its hash in libs/mpfs_pac/MPFS_Registers.sha256
#   pac.sh ensure     regenerate unless src/generated exists and has the recorded hash
#                     (what `./x test lib` and `./x analyze` call, like `svd.py ensure`)
#   pac.sh check      regenerate into a temporary directory, fail if its hash is not the
#                     recorded one, check the LO/HI base addresses and compile the
#                     package (-gnatc) for the E51 and the U54 ABI
#
# The generated package is not committed (.gitignore); its hash is, like the hash of the
# merged SVD in svd/PolarfireSoC.sha256. The generator is the svd2ada built at the commit pinned in tools/toolchain.env
# (./x toolchain install); the steps after it are in tools/pac_gen.py.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAC="$ROOT/libs/mpfs_pac"
GENERATED="$PAC/src/generated"
HASH_FILE="$PAC/MPFS_Registers.sha256"

die () { echo "pac: $*" >&2; exit 1; }

# shellcheck source=tools/mpfs-env.sh
. "$ROOT/tools/mpfs-env.sh"
mpfs_find_python
# Only what generates or compiles the package needs the pinned toolchain: `ensure` of a package that has the
# recorded hash (a restored cache) needs Python only.
need_toolchain () { mpfs_toolchain_on_path || die "pinned toolchain missing (try './x toolchain install')"; }

# generate_into <dir>: svd2ada and the post-processing, into an empty <dir>
generate_into () {
  local out="$1" want got sha log
  need_toolchain
  want="$(mpfs_opt_prefix svd2ada "$SVD2ADA_COMMIT")/bin/svd2ada"
  got="$(command -v svd2ada 2>/dev/null || true)"
  [ -x "$want" ] || die "svd2ada ${SVD2ADA_COMMIT:0:7} is not installed (try './x toolchain install svd2ada')"
  [ "$got" = "$want" ] || die "svd2ada on PATH is $got, not the pinned build $want"
  "$MPFS_PYTHON" "$ROOT/tools/svd.py" ensure
  sha="$(cut -d' ' -f1 "$ROOT/svd/PolarfireSoC.sha256")"
  rm -rf "$out"; mkdir -p "$out"
  log="$(mktemp)"
  "$want" "$ROOT/build/svd/PolarfireSoC.svd" -o "$out" -p MPFS_Registers \
      --boolean --gen-uint-always --no-uint-subtypes >"$log" 2>&1 \
    || { cat "$log" >&2; rm -f "$log"; die "svd2ada failed"; }
  rm -f "$log"
  "$MPFS_PYTHON" "$ROOT/tools/pac_gen.py" postprocess "$out" \
      --svd "$ROOT/build/svd/PolarfireSoC.svd" --svd-sha256 "$sha" --svd2ada-commit "$SVD2ADA_COMMIT"
  "$MPFS_PYTHON" "$ROOT/tools/pac_gen.py" bases "$out" "$PAC/src/mpfs_registers-bases.ads"
}

# every hand-written source needs the strict switches in mpfs_pac.gpr
check_project_lists_sources () {
  local f rc=0
  for f in "$PAC"/src/*.ad[sb]; do
    [ -f "$f" ] || continue
    grep -q "\"$(basename "$f")\"" "$PAC/mpfs_pac.gpr" \
      || { echo "pac: $(basename "$f") is not listed in mpfs_pac.gpr (Compiler switches)" >&2; rc=1; }
  done
  return $rc
}

# compile_abi <hart> <-march> <-mabi>: -gnatc on the whole package
compile_abi () {
  local hart="$1" march="$2" mabi="$3"
  need_toolchain
  echo "pac: compiling for $hart ($march/$mabi)"
  gprbuild -q -f -c -p -j0 -P "$PAC/mpfs_pac.gpr" -XMPFS_HART="$hart" \
      --target=riscv64-elf --RTS=light-polarfiresoc \
      -cargs:Ada -gnatc "-march=$march" "-mabi=$mabi" \
    || die "the package does not compile for $hart"
}

TMP=""
cleanup () { [ -z "$TMP" ] || rm -rf "$TMP"; }
trap cleanup EXIT

digest () { "$MPFS_PYTHON" "$ROOT/tools/pac_gen.py" hash "$1"; }

recorded () { [ -f "$HASH_FILE" ] && cut -d' ' -f1 "$HASH_FILE" || true; }

# install <dir>: <dir> becomes src/generated
install_generated () {
  rm -rf "$GENERATED"; mkdir -p "$GENERATED"
  cp "$1"/*.ads "$GENERATED/"
}

cmd_generate () {
  local tmp; tmp="$(mktemp -d)"; TMP="$tmp"
  generate_into "$tmp/generated"
  install_generated "$tmp/generated"
  printf '%s  src/generated\n' "$(digest "$GENERATED")" > "$HASH_FILE"
  echo "pac: generated $(ls "$GENERATED" | wc -l) files in ${GENERATED#"$ROOT"/} and wrote ${HASH_FILE#"$ROOT"/}"
}

cmd_ensure () {
  local want; want="$(recorded)"
  if [ -d "$GENERATED" ] && [ -n "$want" ] && [ "$(digest "$GENERATED" 2>/dev/null || true)" = "$want" ]; then
    return 0
  fi
  echo "pac: ${GENERATED#"$ROOT"/} is missing or does not have the recorded hash; regenerating"
  local tmp; tmp="$(mktemp -d)"; TMP="$tmp"
  generate_into "$tmp/generated"
  install_generated "$tmp/generated"
  [ "$(digest "$GENERATED")" = "$want" ] \
    || echo "pac: warning: the regenerated package does not match ${HASH_FILE#"$ROOT"/}; run ./x pac generate" >&2
}

cmd_check () {
  local tmp got want; tmp="$(mktemp -d)"; TMP="$tmp"
  generate_into "$tmp/generated"
  got="$(digest "$tmp/generated")"; want="$(recorded)"
  [ -n "$want" ] || die "${HASH_FILE#"$ROOT"/} does not exist (run './x pac generate')"
  if [ "$got" != "$want" ]; then
    [ ! -d "$GENERATED" ] || diff -r "$tmp/generated" "$GENERATED" 2>&1 | head -40 >&2 || true
    die "${HASH_FILE#"$ROOT"/} does not match a regeneration (run './x pac generate')"
  fi
  echo "pac: ${HASH_FILE#"$ROOT"/} matches a regeneration"
  # the compile below needs exactly this package in src/generated
  [ -d "$GENERATED" ] && [ "$(digest "$GENERATED" 2>/dev/null || true)" = "$want" ] || install_generated "$tmp/generated"
  check_project_lists_sources || exit 1
  compile_abi e51 rv64imac_zicsr_zifencei lp64
  compile_abi u54 rv64imafdc_zicsr_zifencei lp64d
  echo "pac: ok"
}

case "${1:-}" in
  generate) cmd_generate ;;
  ensure)   cmd_ensure ;;
  check)    cmd_check ;;
  *) die "usage: pac.sh generate|ensure|check" ;;
esac
