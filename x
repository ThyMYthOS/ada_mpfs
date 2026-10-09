#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
# Derived from rowsail/ada_esp32s3 x @ d75142d (Apache-2.0); modified for PolarFire SoC.
#
#  x -- one command surface for the bare-metal Ada / PolarFire SoC project.
#
#  Usage:
#    ./x toolchain install   install the toolchains pinned in tools/toolchain.env
#    ./x toolchain check     report installed versions; exit 1 on any deviation

set -euo pipefail
#  BASH_SOURCE[0] (not $0) so ROOT is right when x is SOURCED as a library too.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADA_MPFS_SDK="$ROOT"; export ADA_MPFS_SDK

die () { echo "x: $*" >&2; exit 1; }

# -- toolchain ----------------------------------------------------------------
cmd_toolchain () {
  local sub="${1:-}"; shift || true
  # shellcheck source=tools/mpfs-env.sh
  . "$ROOT/tools/mpfs-env.sh"
  case "$sub" in
    install)
      command -v alr >/dev/null 2>&1 || die "alr not found; install Alire $ALR_VERSION first (https://alire.ada.dev)"
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
      if command -v cargo >/dev/null 2>&1; then
        cargo install --locked svdtools --version "$SVDTOOLS_VERSION"
      else
        echo "x: cargo not found; skipping svdtools $SVDTOOLS_VERSION" >&2
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

# -- dispatch -----------------------------------------------------------------
# Skipped when this file is SOURCED, so helpers can be reused as a library.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  cmd="${1:-}"; shift || true
  case "$cmd" in
    toolchain)       cmd_toolchain "$@" ;;
    ""|-h|--help|help)
        # help = the leading comment block, from the "x --" line to its end
        awk '/^#  x --/ {p=1} p && !/^#/ {exit} p {sub(/^# {0,2}/, ""); print}' "$0" ;;
    *) die "unknown command '$cmd' (try './x help')" ;;
  esac
fi
