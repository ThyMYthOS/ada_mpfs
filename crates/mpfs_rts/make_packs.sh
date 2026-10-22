#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Generate the six runtime packs (light, light-tasking, embedded for the E51 and the U54) from
# crates/bb-runtimes, bit for bit reproducible, and keep their hashes in the repository.
#
#   make_packs.sh --ensure   make build/rts/packs/<profile>-<hart>.tar.zst exist and match the
#                            hashes in crates/mpfs_rts/packs.sha256; regenerate the ones that are
#                            missing, unreadable or different (nothing else is touched). Prints a
#                            warning, exit status 0, if a regenerated pack does not match the
#                            recorded hash: the sources changed, run --update. What gen_runtime.sh
#                            and every user of the packs calls.
#   make_packs.sh --check    regenerate all six into a temporary directory and fail unless every
#                            hash equals packs.sha256 ("regenerated == committed"). Changes nothing.
#   make_packs.sh --update   regenerate all six into the output directory and write packs.sha256.
#                            Run after a change to crates/bb-runtimes, and commit the hash file.
#   --out DIR                output directory (default: build/rts/packs, not committed)
#   --hashes FILE            hash file (default: crates/mpfs_rts/packs.sha256)
#   --cells "A B"            only these packs, e.g. "light-u54 light-e51" (the host suite uses it to
#                            keep its negative cases fast); --update then rewrites the lines of
#                            these cells and keeps the others
#
# A pack holds the source text of one runtime and no objects: the directory <profile>-<hart>/
# (gnat/, gnarl/, runtime.xml, the project files) with COPYING3 and COPYING.RUNTIME. The hash file
# has one line per pack, `<sha256>  <profile>-<hart>.tar`, the SHA-256 of the uncompressed tar
# stream (so `zstd -dc <pack> | sha256sum` is the line). The stream is deterministic: build_rts.py
# output only depends on the files of crates/bb-runtimes (sorted directory listings), the entries
# are sorted by name, carry the fixed time stamp below, owner 0:0 (numeric), modes 755 for
# directories and 644 for files, and the GNU tar format (no extended headers with atime or
# ctime). The zstd compression is a cache format only: its bytes depend on the zstd release (1.5.5
# and 1.5.7 differ) and are not compared; only the decompressed stream is.
#
# Needs GNU tar (--sort), zstd, python3 and sha256sum.
# Exit status: 0 ok, 1 difference (--check), 2 set-up or usage error.

set -eu
export LC_ALL=C
export PYTHONDONTWRITEBYTECODE=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BBRT="$HERE/../bb-runtimes"
PROFILES="light light-tasking embedded"
HARTS="e51 u54"
STAMP="2026-01-01 00:00:00 UTC"
ZSTD_LEVEL=19

die () { echo "make_packs: $*" >&2; exit 2; }

out="$ROOT/build/rts/packs"
hashes="$HERE/packs.sha256"
only=""
mode=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ensure|--check|--update) [ -z "$mode" ] || die "only one of --ensure, --check, --update"; mode="${1#--}" ;;
    --out) shift; [ $# -gt 0 ] || die "--out needs a directory"; out="$1" ;;
    --cells) shift; [ $# -gt 0 ] || die "--cells needs a list"; only="$1" ;;
    --hashes) shift; [ $# -gt 0 ] || die "--hashes needs a file"; hashes="$1" ;;
    -h|--help) sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "usage: make_packs.sh --ensure | --check | --update [--out DIR] [--hashes FILE] [--cells LIST]" ;;
  esac
  shift
done
[ -n "$mode" ] || die "usage: make_packs.sh --ensure | --check | --update [--out DIR] [--hashes FILE] [--cells LIST]"

command -v zstd >/dev/null 2>&1 || die "zstd is not installed"
command -v python3 >/dev/null 2>&1 || die "python3 is not installed"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is not installed"
tar --version 2>&1 | grep -q 'GNU tar' || die "GNU tar is required"
[ -f "$BBRT/build_rts.py" ] || die "crates/bb-runtimes/build_rts.py not found"

for c in $only; do
  case " $(echo $HARTS) " in *" ${c##*-} "*) ;; *) die "no such cell: $c" ;; esac
  case " $(echo $PROFILES) " in *" ${c%-*} "*) ;; *) die "no such cell: $c" ;; esac
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

all_cells () {
  local hart profile
  for hart in $HARTS; do for profile in $PROFILES; do echo "$profile-$hart"; done; done | sort
}
# The cells to work on: all of them, or the ones of --cells (which must exist).
cells () {
  local c
  if [ -z "$only" ]; then all_cells; return; fi
  for c in $only; do
    all_cells | grep -qx "$c" || die "no such cell: $c"
    echo "$c"
  done | sort -u
}

# make_pack <cell> <destination directory>: writes <cell>.tar.zst there and prints the SHA-256 of
# the tar stream.
make_pack () {
  local name="$1" dest="$2" profile hart gen stage sum
  hart="${name##*-}"; profile="${name%-*}"
  gen="$work/gen-$name"; stage="$work/stage-$name"
  python3 "$BBRT/build_rts.py" --hart "$hart" --profiles "$profile" -o "$gen" mpfs >"$work/log-$name" 2>&1 \
    || { cat "$work/log-$name" >&2; die "build_rts.py failed for $name"; }
  [ -d "$gen/$profile-mpfs" ] || die "build_rts.py did not produce $profile-mpfs"
  mkdir -p "$stage" "$dest"
  mv "$gen/$profile-mpfs" "$stage/$name"
  cp "$BBRT/COPYING3" "$BBRT/COPYING.RUNTIME" "$stage/$name/"
  find "$stage" -type d -exec chmod 755 {} +
  find "$stage" -type f -exec chmod 644 {} +
  tar --sort=name --format=gnu --mtime="$STAMP" --owner=0 --group=0 --numeric-owner \
      -C "$stage" -cf "$work/$name.tar" "$name"
  sum="$(sha256sum < "$work/$name.tar" | cut -d' ' -f1)"
  zstd -q -$ZSTD_LEVEL --single-thread -f "$work/$name.tar" -o "$work/$name.tar.zst"
  mv "$work/$name.tar.zst" "$dest/$name.tar.zst"
  rm -rf "$gen" "$stage" "$work/$name.tar"
  echo "$sum"
}

# recorded <cell>: the hash in the hash file, or nothing.
recorded () {
  [ -f "$hashes" ] || return 0
  awk -v n="$1.tar" '$2 == n { print $1 }' "$hashes"
}

# stream_hash <pack file>: the SHA-256 of the decompressed stream, or nothing if it cannot be read.
stream_hash () {
  local h
  if h="$(set -o pipefail; zstd -dc "$1" 2>/dev/null | sha256sum 2>/dev/null | cut -d' ' -f1)"; then echo "$h"; fi
}

case "$mode" in
  update)
    mkdir -p "$out"
    : > "$work/new.sha256"
    for name in $(cells); do
      sum="$(make_pack "$name" "$out")"
      echo "$sum  $name.tar" >> "$work/new.sha256"
      echo "make_packs: $out/$name.tar.zst"
    done
    if [ -n "$only" ] && [ -f "$hashes" ]; then
      # keep the lines of the other cells
      awk -v keep="$(cells | sed 's/$/.tar/' | tr '\n' ' ')" 'BEGIN { n = split(keep, a, " "); for (i = 1; i <= n; i++) skip[a[i]] = 1 } !($2 in skip)' "$hashes" >> "$work/new.sha256"
      sort -k2 "$work/new.sha256" > "$work/sorted.sha256"; mv "$work/sorted.sha256" "$work/new.sha256"
    fi
    cp "$work/new.sha256" "$hashes"
    echo "make_packs: wrote $hashes"
    ;;
  check)
    [ -f "$hashes" ] || { echo "FAIL: $hashes is missing (run make_packs.sh --update)" >&2; exit 1; }
    rc=0
    : > "$work/new.sha256"
    for name in $(cells); do
      sum="$(make_pack "$name" "$work/fresh")"
      echo "$sum  $name.tar" >> "$work/new.sha256"
      want="$(recorded "$name")"
      if [ -z "$want" ]; then
        echo "FAIL: $name: no hash in $hashes" >&2; rc=1
      elif [ "$want" = "$sum" ]; then
        echo "ok:   $name: regenerated == committed hash"
      else
        echo "FAIL: $name: the regenerated tar stream ($sum) differs from the committed hash ($want); run make_packs.sh --update and commit packs.sha256" >&2; rc=1
      fi
    done
    # a hash for a pack that no cell produces is stale
    for n in $(awk '{ print $2 }' "$hashes"); do
      all_cells | grep -qx "${n%.tar}" || { echo "FAIL: $n: no such cell, remove it from $hashes" >&2; rc=1; }
    done
    if [ $rc -eq 0 ] && [ -z "$only" ]; then
      if cmp -s "$work/new.sha256" "$hashes"; then echo "ok:   $hashes == regenerated"
      else echo "FAIL: $hashes is not in the format of --update (one line per cell, sorted by name)" >&2; rc=1; fi
    fi
    exit $rc
    ;;
  ensure)
    mkdir -p "$out"
    for name in $(cells); do
      want="$(recorded "$name")"
      have=""
      [ -f "$out/$name.tar.zst" ] && have="$(stream_hash "$out/$name.tar.zst")"
      if [ -n "$want" ] && [ "$have" = "$want" ]; then
        echo "ok:   $name: $out/$name.tar.zst has the recorded hash"
        continue
      fi
      echo "make_packs: $name is missing or does not have the recorded hash; regenerating"
      sum="$(make_pack "$name" "$out")"
      if [ "$sum" != "$want" ]; then
        echo "make_packs: warning: the sources do not match $hashes for $name; run make_packs.sh --update" >&2
      fi
    done
    exit 0
    ;;
esac
