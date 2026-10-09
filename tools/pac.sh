#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Register package generation:
#
#   pac.sh generate   regenerate libs/mpfs_pac/src/generated from the merged SVD
#   pac.sh check      regenerate into a temporary directory, fail on any difference
#                     from the committed files, check the LO/HI base addresses and
#                     compile the package (-gnatc) for the E51 and the U54 ABI
#
# The generator is the svd2ada built at the commit pinned in tools/toolchain.env
# (./x toolchain install); the steps after it are in tools/pac_gen.py.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAC="$ROOT/libs/mpfs_pac"
GENERATED="$PAC/src/generated"

die () { echo "pac: $*" >&2; exit 1; }

# shellcheck source=tools/mpfs-env.sh
. "$ROOT/tools/mpfs-env.sh"
mpfs_toolchain_on_path || die "pinned toolchain missing (try './x toolchain install')"
mpfs_find_python

# generate_into <dir>: svd2ada and the post-processing, into an empty <dir>
generate_into () {
  local out="$1" want got sha log
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
  echo "pac: compiling for $hart ($march/$mabi)"
  gprbuild -q -f -c -p -j0 -P "$PAC/mpfs_pac.gpr" -XMPFS_HART="$hart" \
      --target=riscv64-elf --RTS=light-polarfiresoc \
      -cargs:Ada -gnatc "-march=$march" "-mabi=$mabi" \
    || die "the package does not compile for $hart"
}

TMP=""
cleanup () { [ -z "$TMP" ] || rm -rf "$TMP"; }
trap cleanup EXIT

cmd_generate () {
  local tmp; tmp="$(mktemp -d)"; TMP="$tmp"
  generate_into "$tmp/generated"
  rm -rf "$GENERATED"; mkdir -p "$GENERATED"
  cp "$tmp/generated"/*.ads "$GENERATED/"
  echo "pac: generated $(ls "$GENERATED" | wc -l) files in ${GENERATED#"$ROOT"/}"
}

cmd_check () {
  local tmp; tmp="$(mktemp -d)"; TMP="$tmp"
  generate_into "$tmp/generated"
  diff -r "$tmp/generated" "$GENERATED" > "$tmp/diff" \
    || { head -40 "$tmp/diff" >&2; die "${GENERATED#"$ROOT"/} differs from a regeneration (run './x pac generate')"; }
  echo "pac: ${GENERATED#"$ROOT"/} is reproduced"
  check_project_lists_sources || exit 1
  compile_abi e51 rv64imac_zicsr_zifencei lp64
  compile_abi u54 rv64imafdc_zicsr_zifencei lp64d
  echo "pac: ok"
}

case "${1:-}" in
  generate) cmd_generate ;;
  check)    cmd_check ;;
  *) die "usage: pac.sh generate|check" ;;
esac
