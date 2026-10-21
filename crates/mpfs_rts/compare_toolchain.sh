#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Compare the common GNAT and GNARL sources of the runtime packs with the runtimes shipped with
# the pinned toolchain (the same principle as assert_identical in ada-machine populate.sh): the
# fork of bb-runtimes must produce the sources of the toolchain's own runtimes, or the runtime
# and the compiler (GNAT_RISCV64_VERSION in tools/toolchain.env) do not match.
#
#   compare_toolchain.sh [--packs DIR] [--toolchain DIR]
#
# The packs are those of build/rts/packs: without --packs the script first runs
# `make_packs.sh --ensure`, so they exist and match the committed hashes (packs.sha256). With
# --packs DIR it takes the packs of DIR as they are.
#
# For every pack <profile>-<hart> the directories gnat/ and gnarl/ are compared file by file
# with a shipped runtime of $TOOLCHAIN/riscv64-elf/lib/gnat:
#
#   U54, every profile      <profile>-polarfiresoc (the upstream board of the same ISA)
#   E51, light              light-rv64imac         (no FPU, the generic RV64IMAC board)
#   E51, light-tasking and  <profile>-polarfiresoc, except the sources that depend on the FPU
#   embedded                (the files in which light-rv64imac and light-rv64imafdc differ); of
#                           those, ours must be the ones of light-rv64imac
#
# A file may differ from the reference, or be missing on one side, only if it is a port unit
# listed in port_units.list (board files: start code, board parameters, trap handler, ...).
# Everything else must be byte-identical; a difference means the sources of the fork do not
# match the toolchain, and the source from the toolchain is to be preferred.
#
# Exit status: 0 identical, 1 differences, 2 set-up error (no toolchain, no packs).

set -eu
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PACKS="$ROOT/build/rts/packs"
ENSURE=1
TOOLCHAIN=""
PROFILES="light light-tasking embedded"
HARTS="e51 u54"

die () { echo "compare_toolchain: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --packs) shift; [ $# -gt 0 ] || die "--packs needs a directory"; PACKS="$1"; ENSURE=0 ;;
    --toolchain) shift; [ $# -gt 0 ] || die "--toolchain needs a directory"; TOOLCHAIN="$1" ;;
    -h|--help) sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "usage: compare_toolchain.sh [--packs DIR] [--toolchain DIR]" ;;
  esac
  shift
done

if [ -z "$TOOLCHAIN" ]; then
  # shellcheck source=tools/mpfs-env.sh
  . "$ROOT/tools/mpfs-env.sh"
  bin="$(mpfs_tc_bin gnat_riscv64_elf "$GNAT_RISCV64_VERSION")"
  [ -n "$bin" ] || die "gnat_riscv64_elf $GNAT_RISCV64_VERSION is not installed in $MPFS_ADA_TOOLCHAINS (./x toolchain install gnat)"
  TOOLCHAIN="$(cd "$bin/.." && pwd)"
fi
SHIPPED="$TOOLCHAIN/riscv64-elf/lib/gnat"
[ -d "$SHIPPED" ] || die "no shipped runtimes in $SHIPPED"
for r in light-rv64imac light-rv64imafdc light-polarfiresoc light-tasking-polarfiresoc embedded-polarfiresoc; do
  [ -d "$SHIPPED/$r" ] || die "the toolchain has no runtime $r in $SHIPPED"
done
command -v zstd >/dev/null 2>&1 || die "zstd is not installed"
[ "$ENSURE" = 0 ] || bash "$HERE/make_packs.sh" --ensure >&2 || die "make_packs.sh --ensure failed"

# Port units: the first word of every line that is not a comment.
units="$(sed -e 's/#.*//' "$HERE/port_units.list" | awk 'NF { print $1 }')"
[ -n "$units" ] || die "port_units.list is empty"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
rc=0

is_unit () { printf '%s\n' "$units" | grep -qxF -- "$1"; }

# The sources that depend on the FPU: where the soft-float and the hard-float runtime differ.
fpu_files="$(cd "$SHIPPED/light-rv64imac/gnat" && for f in *; do
               cmp -s "$f" "$SHIPPED/light-rv64imafdc/gnat/$f" 2>/dev/null || echo "$f"
             done)"
[ -n "$fpu_files" ] || die "light-rv64imac and light-rv64imafdc have no FPU-dependent source: the toolchain is not what this check expects"

# compare <label> <our runtime dir> <reference dir> <extra allowed names, one per line>
compare () {
  local label="$1" ours="$2" ref="$3" extra="$4" lib f n=0 bad=0 units_differing=""
  for lib in gnat gnarl; do
    [ -d "$ours/$lib" ] || [ -d "$ref/$lib" ] || continue
    for f in $( { [ -d "$ours/$lib" ] && (cd "$ours/$lib" && find . -type f | sed 's#^\./##'); \
                  [ -d "$ref/$lib" ]  && (cd "$ref/$lib"  && find . -type f | sed 's#^\./##'); } | sort -u ); do
      n=$((n + 1))
      if [ ! -f "$ours/$lib/$f" ] || [ ! -f "$ref/$lib/$f" ] || ! cmp -s "$ours/$lib/$f" "$ref/$lib/$f"; then
        if is_unit "$f"; then
          units_differing="$units_differing $f"
        elif printf '%s\n' "$extra" | grep -qxF -- "$f" && [ -f "$ours/$lib/$f" ] && [ -f "$ref/$lib/$f" ]; then
          :
        else
          if [ ! -f "$ours/$lib/$f" ]; then echo "FAIL: $label: $lib/$f is in the toolchain runtime but not in the pack" >&2
          elif [ ! -f "$ref/$lib/$f" ]; then echo "FAIL: $label: $lib/$f is in the pack but not in the toolchain runtime (and not a port unit)" >&2
          else echo "FAIL: $label: $lib/$f differs from the toolchain runtime" >&2; fi
          bad=$((bad + 1))
        fi
      fi
    done
  done
  if [ $bad -eq 0 ]; then
    echo "ok:   $label: $n sources compared with $(basename "$ref"), port units that differ:${units_differing:- none}"
  else
    rc=1
  fi
}

for hart in $HARTS; do
  for profile in $PROFILES; do
    name="$profile-$hart"
    [ -f "$PACKS/$name.tar.zst" ] || { echo "FAIL: $name: no pack in $PACKS" >&2; rc=1; continue; }
    mkdir -p "$work/$name"
    zstd -dc "$PACKS/$name.tar.zst" | tar -x -C "$work/$name" || die "cannot unpack $name"
    ours="$work/$name/$name"
    [ -d "$ours" ] || { echo "FAIL: $name: the pack has no directory $name" >&2; rc=1; continue; }
    case "$hart:$profile" in
      u54:*)
        compare "$name" "$ours" "$SHIPPED/$profile-polarfiresoc" "" ;;
      e51:light)
        compare "$name" "$ours" "$SHIPPED/light-rv64imac" "" ;;
      e51:*)
        compare "$name" "$ours" "$SHIPPED/$profile-polarfiresoc" "$fpu_files"
        # The FPU-dependent sources must be those of the soft-float runtime.
        for f in $fpu_files; do
          if [ -f "$ours/gnat/$f" ] && ! cmp -s "$ours/gnat/$f" "$SHIPPED/light-rv64imac/gnat/$f"; then
            echo "FAIL: $name: gnat/$f is not the soft-float source of light-rv64imac" >&2; rc=1
          fi
        done ;;
    esac
  done
done

[ $rc -eq 0 ] && echo "ok:   the common sources of all packs match the toolchain runtimes ($(basename "$TOOLCHAIN"))"
exit $rc
