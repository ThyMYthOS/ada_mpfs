#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# repro.sh -- reproducible images: build every image of every example twice, in two
# directories with different absolute paths and the same SOURCE_DATE_EPOCH, and compare
# the SHA-256 of the ELFs. Driven by `./x repro`.
#
#   usage: tools/repro.sh
#
#   REPRO_ROOT         the tree to build (default: the repository of this script)
#   SOURCE_DATE_EPOCH  the build time of both builds (default: the commit time of
#                      HEAD of REPRO_ROOT)
#   REPRO_WORK         the directory for the two copies and the build logs (default:
#                      a new temporary directory, removed after a pass; kept after a
#                      failure, and its name printed)
#
# The images are those of the harts named in BUILD_HARTS of example.conf (HART, then e51,
# if absent), as for ./x metrics. Each copy is built with its own ./x build, so the paths
# the compiler sees differ by the directory name and its length.
#
# Rules that close a way this script could pass without comparing anything:
#
#   - A missing pinned toolchain is a FAILURE (exit 2), not a skip.
#   - A build that fails, or that leaves no image, is a FAILURE.
#   - No example, or no image at all, is a FAILURE.
#   - The two copies must have built the same set of images; an image in one copy
#     only is a FAILURE.
#   - A difference is reported with the image, both hashes, the number of differing
#     bytes, and whether the image contains the path of one of the copies. The
#     exit status is 1; nothing is excluded from the comparison.
#
# Exit status: 0 every image is identical; 1 a difference or a failed build; 2 set-up
# error (usage, missing toolchain, no example, no epoch).

set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
root="${REPRO_ROOT:-$repo}"

die () { echo "repro: $*" >&2; exit 2; }

[ $# -eq 0 ] || die "usage: tools/repro.sh   (no arguments; see the header)"
[ -d "$root/examples" ] || die "$root has no examples/"

# The toolchain pinned in tools/toolchain.env must be there before anything is built:
# ./x build would fail too, but then the message would come twice per example.
# shellcheck source=tools/mpfs-env.sh
. "$here/mpfs-env.sh"
mpfs_toolchain_on_path || die "pinned toolchain missing (try './x toolchain install')"

if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
  SOURCE_DATE_EPOCH="$(git -C "$root" log -1 --format=%ct 2>/dev/null)" \
    || SOURCE_DATE_EPOCH=""
fi
case "${SOURCE_DATE_EPOCH:-}" in
  ""|*[!0-9]*) die "SOURCE_DATE_EPOCH is not set and $root has no commit time" ;;
esac
export SOURCE_DATE_EPOCH

sha256 () {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | sed 's/ .*//'
  else openssl dgst -sha256 "$1" | sed 's/.* //'; fi
}

# conf_get <example> <KEY> <default>, as in ./x
conf_get () {
  local v=""
  [ -f "$root/examples/$1/example.conf" ] \
    && v="$(sed -n "s/^$2=//p" "$root/examples/$1/example.conf" | head -1)"
  echo "${v:-$3}"
}

# The (example, hart) pairs.
pairs=()
for d in "$root"/examples/*/; do
  [ -f "${d}app.gpr" ] || continue
  e="$(basename "$d")"
  harts="$(conf_get "$e" BUILD_HARTS "$(conf_get "$e" HART e51)")"
  for h in $harts; do pairs+=("$e:$h"); done
done
[ ${#pairs[@]} -gt 0 ] || die "no example with an app.gpr in $root/examples"

if [ -n "${REPRO_WORK:-}" ]; then
  work="$REPRO_WORK"; mkdir -p "$work" || die "cannot create $work"
else
  work="$(mktemp -d "${TMPDIR:-/tmp}/repro.XXXXXX")" || die "mktemp failed"
fi
# Two names that differ in value and length.
dirs=("$work/one/ada_mpfs" "$work/second-build-dir/tree")
fails=0

for t in "${dirs[@]}"; do
  mkdir -p "$t" || die "cannot create $t"
  # No build products, no VCS state: each copy starts from the sources.
  tar -C "$root" --exclude=./.git --exclude='obj-*' --exclude='bin-*' --exclude=./build \
      --exclude=__pycache__ --exclude=.venv -cf - . | tar -C "$t" -xf - \
    || die "copying $root to $t failed"
done

echo "repro: SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH, ${#pairs[@]} image set(s), copies in ${dirs[0]} and ${dirs[1]}"
n=0
for t in "${dirs[@]}"; do
  n=$((n + 1))
  for p in "${pairs[@]}"; do
    log="$work/build-$n-${p%:*}-${p#*:}.log"
    if ! ( cd "$t" && bash ./x build "${p%:*}" --hart "${p#*:}" ) >"$log" 2>&1; then
      echo "FAIL: build of ${p%:*} (${p#*:}) in $t failed; see $log" >&2
      tail -n 20 "$log" >&2
      fails=$((fails + 1))
    fi
  done
done

listing () {   # images of a copy, relative, sorted
  ( cd "$1" && find examples -path '*/bin-*/*.elf' -type f 2>/dev/null | LC_ALL=C sort )
}
listing "${dirs[0]}" > "$work/images.1"
listing "${dirs[1]}" > "$work/images.2"

if [ ! -s "$work/images.1" ] || [ ! -s "$work/images.2" ]; then
  echo "FAIL: a build left no image" >&2; fails=$((fails + 1))
elif ! cmp -s "$work/images.1" "$work/images.2"; then
  echo "FAIL: the two builds produced different sets of images:" >&2
  diff "$work/images.1" "$work/images.2" | sed 's/^/    /' >&2
  fails=$((fails + 1))
fi

same=0; differ=0
while IFS= read -r img; do
  a="${dirs[0]}/$img"; b="${dirs[1]}/$img"
  [ -f "$b" ] || continue
  ha="$(sha256 "$a")"; hb="$(sha256 "$b")"
  if [ -n "$ha" ] && [ "$ha" = "$hb" ]; then
    same=$((same + 1))
    printf 'ok:   %s %s\n' "$ha" "$img"
  else
    differ=$((differ + 1))
    printf 'DIFF: %s\n      %s\n      %s\n' "$img" "${ha:-no hash}" "${hb:-no hash}" >&2
    printf '      %s bytes differ' "$(cmp -l "$a" "$b" 2>/dev/null | wc -l | tr -d ' ')" >&2
    for t in "${dirs[@]}"; do
      if grep -aqF "$t" "$a" "$b" 2>/dev/null; then printf '; contains %s' "$t" >&2; fi
    done
    echo >&2
  fi
done < "$work/images.1"

[ $((same + differ)) -gt 0 ] || { echo "FAIL: nothing was compared" >&2; fails=$((fails + 1)); }
[ $differ -eq 0 ] || fails=$((fails + 1))

if [ $fails -eq 0 ]; then
  echo "repro: $same image(s) identical"
  [ -n "${REPRO_WORK:-}" ] || rm -rf "$work"
  exit 0
fi
echo "repro: FAILED ($differ differing image(s), $same identical); the copies and logs are in $work" >&2
exit 1
