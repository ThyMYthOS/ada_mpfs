#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Tests for the functions of tools/mpfs-env.sh that the shell generators share (gen_runtime.sh,
# make_packs.sh, pac.sh): the hash of stdin and of a directory, the cache key, the hash recorded in a
# file, the comparison of a regenerated hash with it and the stamp of a cache. The hashes are checked
# against sha256sum on the same bytes, so a change of the format of a key shows up here.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fails=0
. "$ROOT/tools/mpfs-env.sh"

pass () { echo "ok:   $1"; }
fail () { echo "FAIL: $1" >&2; fails=$((fails + 1)); }
# is <description> <want> <got>
is () { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (wanted '$2', got '$3')"; fi; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

sha_of () { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }

# -- mpfs_sha ------------------------------------------------------------------------------------------------------
is "mpfs_sha: the SHA-256 of stdin as a bare hex string" "$(sha_of 'abc')" "$(printf 'abc' | mpfs_sha)"
is "mpfs_sha: the hash of nothing" "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" "$(printf '' | mpfs_sha)"

# -- mpfs_tree_hash ------------------------------------------------------------------------------------------------
d="$tmp/tree"; mkdir -p "$d/sub"
printf 'one' > "$d/a.txt"; printf 'two' > "$d/sub/b.txt"
want="$(printf './a.txt %s\n./sub/b.txt %s\n' "$(sha_of one)" "$(sha_of two)" | mpfs_sha)"
is "mpfs_tree_hash: the hash of the lines '<path> <hash of the file>', files in name order" "$want" "$(mpfs_tree_hash "$d")"
h="$(mpfs_tree_hash "$d")"
mkdir -p "$tmp/tree2/sub"; printf 'two' > "$tmp/tree2/sub/b.txt"; printf 'one' > "$tmp/tree2/a.txt"
is "mpfs_tree_hash: the same files made in another order, in another directory, give the same hash" "$h" "$(mpfs_tree_hash "$tmp/tree2")"
printf 'three' > "$tmp/tree2/a.txt"
[ "$h" != "$(mpfs_tree_hash "$tmp/tree2")" ] && pass "mpfs_tree_hash: another content gives another hash" || fail "mpfs_tree_hash: another content gives another hash"
printf 'one' > "$tmp/tree2/a.txt"; mv "$tmp/tree2/a.txt" "$tmp/tree2/c.txt"
[ "$h" != "$(mpfs_tree_hash "$tmp/tree2")" ] && pass "mpfs_tree_hash: another name gives another hash" || fail "mpfs_tree_hash: another name gives another hash"
is "mpfs_tree_hash: an absent directory has the hash of nothing" "$(printf '' | mpfs_sha)" "$(mpfs_tree_hash "$tmp/absent")"
mkdir -p "$tmp/empty"
is "mpfs_tree_hash: an empty directory has the hash of nothing" "$(printf '' | mpfs_sha)" "$(mpfs_tree_hash "$tmp/empty")"

# -- mpfs_cache_key ------------------------------------------------------------------------------------------------
is "mpfs_cache_key: the hash of its arguments, one per line" "$(printf 'pack 1\npac 2\n' | mpfs_sha)" "$(mpfs_cache_key 'pack 1' 'pac 2')"
is "mpfs_cache_key: an argument with blanks and a leading dash stays one line" "$(printf -- '-n x  y\n' | mpfs_sha)" "$(mpfs_cache_key '-n x  y')"
[ "$(mpfs_cache_key a b)" != "$(mpfs_cache_key b a)" ] && pass "mpfs_cache_key: the order counts" || fail "mpfs_cache_key: the order counts"

# -- mpfs_recorded_hash --------------------------------------------------------------------------------------------
printf '%s  src/generated\n' "$(sha_of x)" > "$tmp/one.sha256"
is "mpfs_recorded_hash: the first field of a one-line file" "$(sha_of x)" "$(mpfs_recorded_hash "$tmp/one.sha256")"
printf 'aaa  light-e51.tar\nbbb  light-u54.tar\n' > "$tmp/packs.sha256"
is "mpfs_recorded_hash: the hash of a named entry" "bbb" "$(mpfs_recorded_hash "$tmp/packs.sha256" light-u54.tar)"
is "mpfs_recorded_hash: a name that is not in the file is empty" "" "$(mpfs_recorded_hash "$tmp/packs.sha256" embedded-u54.tar)"
is "mpfs_recorded_hash: a missing file is empty" "" "$(mpfs_recorded_hash "$tmp/none.sha256")"
mpfs_recorded_hash "$tmp/none.sha256" "x" >/dev/null && pass "mpfs_recorded_hash: a missing file has status 0 (callers run under set -e)" || fail "mpfs_recorded_hash: a missing file has status 0"

# -- mpfs_hash_check -----------------------------------------------------------------------------------------------
mpfs_hash_check abc abc; is "mpfs_hash_check: equal hashes are 0" 0 "$?"
mpfs_hash_check abc abd; is "mpfs_hash_check: different hashes are 1" 1 "$?"
mpfs_hash_check abc ""; is "mpfs_hash_check: nothing recorded is 2" 2 "$?"
mpfs_hash_check "" ""; is "mpfs_hash_check: nothing recorded is 2 even if nothing was computed" 2 "$?"

# -- mpfs_stamp_current --------------------------------------------------------------------------------------------
printf 'key=abc\nother=1\n' > "$tmp/stamp"
mpfs_stamp_current "$tmp/stamp" abc && pass "mpfs_stamp_current: a stamp with the key is current" || fail "mpfs_stamp_current: a stamp with the key is current"
mpfs_stamp_current "$tmp/stamp" ab && fail "mpfs_stamp_current: a prefix of the key is not the key" || pass "mpfs_stamp_current: a prefix of the key is not the key"
mpfs_stamp_current "$tmp/stamp" abd && fail "mpfs_stamp_current: another key is not current" || pass "mpfs_stamp_current: another key is not current"
mpfs_stamp_current "$tmp/none" abc && fail "mpfs_stamp_current: a missing stamp is not current" || pass "mpfs_stamp_current: a missing stamp is not current"

echo "summary: $fails failure(s)"
[ $fails -eq 0 ]
