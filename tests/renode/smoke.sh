#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# smoke.sh -- run every image named in smoke.expected on the Icicle Kit model of
# Renode (bare.resc, a fixed span of virtual time) and ASSERT that it printed
# what the file says. Driven by `./x test renode`.
#
#   RENODE           the renode binary (default: renode on PATH, else the pinned
#                    release installed by `./x toolchain install renode`)
#   SMOKE_EXPECTED   the expectation file (default smoke.expected next to this script)
#   RENODE_SPAN      virtual time to run each image (default 00:00:00.5)
#   RENODE_TIMEOUT   wall-clock limit per image in seconds (default 180)
#
# As in tests/qemu/smoke.sh, nothing passes vacuously: a missing Renode, a missing
# image, an empty or malformed expectation file, an empty console and any error
# Renode reports while running the script are failures, never skips. The
# strings are searched on the UART file only, never on Renode's own log.

set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
expected="${SMOKE_EXPECTED:-$here/smoke.expected}"
span="${RENODE_SPAN:-00:00:00.5}"
limit="${RENODE_TIMEOUT:-180}"

fail () { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

renode="${RENODE:-}"
if [ -z "$renode" ]; then
  # shellcheck source=tools/mpfs-env.sh
  . "$root/tools/mpfs-env.sh"
  if command -v renode >/dev/null 2>&1; then renode="$(command -v renode)"
  elif [ -x "$(mpfs_opt_prefix renode "$RENODE_VERSION")/renode" ]; then renode="$(mpfs_opt_prefix renode "$RENODE_VERSION")/renode"
  fi
fi
[ -n "$renode" ] && [ -x "$renode" ] || fail "Renode not found (./x toolchain install renode, or set RENODE=<path>). Nothing was run."
case "$limit" in ''|*[!0-9]*) fail "RENODE_TIMEOUT must be a whole number of seconds, got '$limit'" ;; esac

[ -f "$expected" ] || fail "expectation file '$expected' does not exist"
rows="$(awk -F'\t' '
  /^[ \t]*#/ || /^[ \t]*$/ { next }
  !hdr { hdr = 1; if ($1 != "image") { print "BADHEADER"; bad = 1 } ; next }
  NF != 2 || $1 == "" || $2 == "" { print "BADROW\t" $0; bad = 1; next }
  { print }
  END { exit bad ? 1 : 0 }' "$expected")" \
  || fail "$expected is malformed: the first non-comment line must be the 'image<TAB>string' header, and every row needs both fields, TAB-separated"
[ -n "$rows" ] || fail "$expected contains no expectations; an empty file would make this test pass vacuously"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
echo "renode:  $("$renode" --version 2>&1 | head -n 1)"

failures=0; n=0
for img in $(printf '%s\n' "$rows" | cut -f1 | awk '!seen[$0]++'); do
  n=$((n + 1))
  printf '==> %s\n' "$img"
  case "$img" in /*) path="$img" ;; *) path="$root/$img" ;; esac
  if [ ! -f "$path" ]; then
    printf 'FAIL %s: image %s not found (run ./x build, or ./x test renode which builds it)\n' "$img" "$path" >&2
    failures=$((failures + 1)); continue
  fi
  uart="$tmp/$n.uart"; log="$tmp/$n.log"
  : > "$uart"
  timeout -s KILL "$limit" "$renode" --console --disable-gui \
      -e "\$elf=@$path; \$uart=@$uart; \$span=\"$span\"; include @$here/bare.resc" \
      </dev/null >"$log" 2>&1
  rc=$?
  bad=0
  if [ $rc -ne 0 ]; then
    printf '    Renode exited with status %s\n' "$rc" >&2; bad=1
  fi
  if grep -q "There was an error\|No such command\|Could not" "$log"; then
    printf '    Renode reported an error:\n' >&2
    grep -A2 "There was an error\|No such command\|Could not" "$log" | head -n 6 | sed 's/^/    | /' >&2
    bad=1
  fi
  while IFS="$(printf '\t')" read -r _ needle; do
    if grep -qF -- "$needle" "$uart"; then
      printf '    ok:      "%s"\n' "$needle"
    else
      printf '    MISSING: "%s"\n' "$needle" >&2; bad=1
    fi
  done <<EOF
$(printf '%s\n' "$rows" | awk -F'\t' -v a="$img" '$1 == a')
EOF
  if [ ! -s "$uart" ]; then
    echo "  guest console: EMPTY -- the image wrote nothing to MMUART0" >&2
  fi
  if [ $bad -ne 0 ]; then
    printf 'FAIL %s\n' "$img" >&2
    failures=$((failures + 1))
  fi
done

if [ $failures -ne 0 ]; then
  printf 'renode smoke FAILED: %d of %d image(s)\n' "$failures" "$n" >&2
  exit 1
fi
printf 'renode smoke OK: %d image(s) printed every string %s expects\n' "$n" "$expected"
