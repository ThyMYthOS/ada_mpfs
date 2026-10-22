#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
# Derived from rowsail/ada_esp32s3 x (cmd_test lib, build_lib_clean) @ d75142d (Apache-2.0); modified for PolarFire SoC.
#
#  test_lib.sh -- ./x test lib: every library project below libs/ compiles for
#  the E51 and the U54 ABI, and any warning is a failure (gprbuild's exit
#  status ignores warnings, so its output is searched).
#
#  usage: sh tools/test_lib.sh [name...]     (default: every libs/*/<name>.gpr)
#
#  A project is libs/<dir>/<name>.gpr; *_prove.gpr is left to ./x prove.  A
#  library selects the hart through the external MPFS_HART, as mpfs_pac.gpr
#  does.  Warnings from machine-generated sources (src/generated) are not
#  counted: ./x pac check owns those.  Environment:
#    LIBS    directory holding the libraries (default: libs/ of the repository)
#    GPRBUILD  the build command (default: the pinned gprbuild); the tests replace it

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${LIBS:=$ROOT/libs}"

# shellcheck source=tools/mpfs-env.sh
. "$ROOT/tools/mpfs-env.sh"
#  A GPRBUILD from the environment (the tests) is used as it is.
[ -n "${GPRBUILD:-}" ] || {
  mpfs_toolchain_on_path || { echo "test_lib: pinned toolchain missing (try './x toolchain install')" >&2; exit 2; }
  GPRBUILD=gprbuild
}

# hart march mabi
ABIS=("e51 rv64imac_zicsr_zifencei lp64" "u54 rv64imafdc_zicsr_zifencei lp64d")

# build_clean <gpr> <hart> <march> <mabi>: compile, fail on an error or a warning
build_clean () {
  local gpr="$1" hart="$2" march="$3" mabi="$4" out warned
  out="$("$GPRBUILD" -q -f -c -p -j0 -P "$gpr" -XMPFS_HART="$hart" \
           --target=riscv64-elf --RTS=light-polarfiresoc \
           -cargs:Ada "-march=$march" "-mabi=$mabi" 2>&1)" \
    || { printf '%s\n' "$out" | tail -20 | sed 's/^/      /'; return 1; }
  warned="$(printf '%s\n' "$out" | grep 'warning:' | grep -v 'src/generated/' || true)"
  [ -z "$warned" ] || { printf '%s\n' "$warned" | sed 's/^/      /'; return 1; }
}

gprs=()
if [ $# -gt 0 ]; then
  for n in "$@"; do
    g="$(ls "$LIBS"/*/"$n.gpr" 2>/dev/null | head -1)"
    [ -n "$g" ] || { echo "test_lib: no library project '$n' below ${LIBS#"$ROOT"/}" >&2; exit 2; }
    gprs+=("$g")
  done
else
  for g in "$LIBS"/*/[a-z]*.gpr; do
    [ -f "$g" ] || continue
    case "$(basename "$g")" in *_prove.gpr) continue ;; esac
    gprs+=("$g")
  done
fi
[ ${#gprs[@]} -gt 0 ] || { echo "test_lib: no library projects below ${LIBS#"$ROOT"/}" >&2; exit 2; }

# The register package is not committed: generate it (or check its hash) before it is compiled.
for g in "${gprs[@]}"; do
  case "$g" in "$ROOT/libs/mpfs_pac/"*) bash "$ROOT/tools/pac.sh" ensure || exit 2; break ;; esac
done

echo "== libraries (E51 and U54 ABI; warnings are failures) =="
failures=0; ran=0
for g in "${gprs[@]}"; do
  for abi in "${ABIS[@]}"; do
    # shellcheck disable=SC2086
    set -- $abi
    ran=$((ran + 1))
    if build_clean "$g" "$1" "$2" "$3"; then echo "ok:   $(basename "${g%.gpr}") [$1]"
    else echo "FAIL: $(basename "${g%.gpr}") [$1]" >&2; failures=$((failures + 1)); fi
  done
done
echo "test_lib: $ran build(s), $failures failure(s)"
[ $failures -eq 0 ]
