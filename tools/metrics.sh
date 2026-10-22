#!/bin/sh
#  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
#  SPDX-License-Identifier: Apache-2.0
#
#  metrics.sh -- measure the built images, and either compare to or rewrite
#  metrics.golden.   Driven by `./x metrics verify|bless` and `./x test metrics`.
#
#  usage: sh tools/metrics.sh verify|bless
#
#  The images are every examples/<example>/bin-<hart>/*.elf; an image is named
#  <example>/<hart>/<file name without .elf>. They must be built (./x metrics
#  builds the examples that name their harts in BUILD_HARTS of example.conf).
#
#  Inputs, all from the environment (./x sets them):
#    RV_SIZE RV_READELF RV_STRINGS   riscv64-elf-* tools (default: from PATH)
#    GOLDEN                  path of the golden file (default: metrics.golden
#                            in the repository root)
#    EXAMPLES                directory of the examples (default: examples/)
#    MEASURED                verify only: where to write this host's measured
#                            rows, in golden format (CI uploads it as an artifact)
#
#  KEYED ON THE COMPILER, NOT THE HOST. Every row carries the compiler that built
#  the image, and a measurement is compared only against the row for the same
#  (image, compiler). The key is the "GNAT Version: <v>" string that the binder
#  embeds (__gnat_version) when the image has one, shown as "GNAT <v>"; an image
#  without a binder (the bare examples) has none, and then the key is the string
#  the linker recorded in its .comment section ("GCC: (GNAT-FSF-builds) 15.3.0"
#  for the pinned toolchain), the only record of what built it. A host whose compiler has no baseline FAILS with "no
#  baseline" and prints the rows to seed it, rather than comparing against
#  another compiler's numbers or silently passing.
#
#  DESIGN RULES (each one closes a way a check could report success while
#  checking nothing):
#
#    - A missing image is an ERROR, never a skip.
#    - A missing/unusable tool is an ERROR before anything is measured.
#    - Every field is validated against the shape it must have; an empty or
#      unparseable field is an ERROR, so it can never compare "equal".
#    - The image set is compared, not just the values: an image in the golden
#      file but not measured, or measured but not in the golden file, is a
#      failure.
#    - `bless` refuses to write unless every image measured cleanly, so a
#      half-built tree cannot produce a half-empty golden file.
#    - Exact string match. No tolerances.
#
#  Plain /bin/sh + awk only: this runs on macOS (BSD userland).
# @req BLD-003

set -u

mode=${1:-}
case "$mode" in verify|bless) ;; *) echo "usage: sh tools/metrics.sh verify|bless" >&2; exit 2 ;; esac

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
: "${GOLDEN:=$root/metrics.golden}"
: "${EXAMPLES:=$root/examples}"
RV_SIZE=${RV_SIZE:-riscv64-elf-size}
RV_READELF=${RV_READELF:-riscv64-elf-readelf}
RV_STRINGS=${RV_STRINGS:-riscv64-elf-strings}

errors=0
err() { printf 'ERROR: %s\n' "$*" >&2; errors=$((errors + 1)); }

tmp=$(mktemp "${TMPDIR:-/tmp}/metrics.XXXXXX") || { echo "ERROR: mktemp failed" >&2; exit 2; }
trap 'rm -f "$tmp" "$tmp.new" "$tmp.kept"' EXIT HUP INT TERM

#  --- toolchain: fail loudly, before measuring anything ----------------------
#  Executing each tool proves it exists and runs; a name that merely looks
#  plausible does not pass.
check_tool() {   # path  what
  if ! command -v "$1" >/dev/null 2>&1 || ! "$1" --version >/dev/null 2>&1; then
    err "$2 not usable: '$1'"
    return 1
  fi
}
tools_ok=1
check_tool "$RV_SIZE"    "RISC-V size"    || tools_ok=0
check_tool "$RV_READELF" "RISC-V readelf" || tools_ok=0
check_tool "$RV_STRINGS" "RISC-V strings" || tools_ok=0
if [ "$tools_ok" = 0 ]; then
  echo "       Run './x toolchain install' (installs the pinned cross compiler), or use ./x metrics, which puts it on PATH." >&2
  echo "FAIL: toolchain missing; nothing was measured" >&2
  exit 1
fi

#  --- measurement ------------------------------------------------------------
#  One TSV row per image:
#    image compiler text data bss entry eflags isa attrs
#  See the header written by `bless` for what each field is and why.
nonblank() { [ -n "$1" ]; }
shape() {   # value regexp  -> 0 if the whole value matches
  printf '%s\n' "$1" | awk -v re="$2" '$0 ~ re { ok = 1 } END { exit ok ? 0 : 1 }'
}

measure() {   # name path
  app=$1; img=$2

  sz=$("$RV_SIZE" "$img") || { err "$app: $RV_SIZE failed on $img"; return; }
  hd=$("$RV_READELF" -h "$img") || { err "$app: $RV_READELF -h failed on $img"; return; }
  at=$("$RV_READELF" -A "$img") || { err "$app: $RV_READELF -A failed on $img"; return; }
  cm=$("$RV_READELF" -p .comment "$img") || { err "$app: $RV_READELF -p .comment failed on $img"; return; }

  #  The compiler that built THIS image -- not whatever happens to be installed.
  #  The "GNAT Version:" string of the binder (__gnat_version) if the image has
  #  one, else what the linker recorded in .comment. Exactly one distinct value
  #  is required: none means the key would be empty, more than one would mean
  #  objects from two compilers.
  st=$("$RV_STRINGS" -a "$img") || { err "$app: $RV_STRINGS failed on $img"; return; }
  compiler=$(printf '%s\n' "$st" | sed -n 's/^GNAT Version: /GNAT /p' | sort -u)
  src="GNAT Version"
  if [ -z "$compiler" ]; then
    compiler=$(printf '%s\n' "$cm" | sed -n 's/^[ \t]*\[[ \t]*[0-9a-f]*\][ \t]*//p' | sort -u)
    src=".comment"
  fi
  ncomp=$(printf '%s' "$compiler" | awk 'END { print NR }')
  if [ "$ncomp" -gt 1 ]; then
    err "$app: $ncomp different $src strings in one image: $(printf '%s' "$compiler" | tr '\n' '|')"
    return
  fi

  #  size -B: line 2 is `text data bss dec hex filename`.
  set -- $(printf '%s\n' "$sz" | awk 'NR==2 { print $1, $2, $3 }')
  text=${1:-}; data=${2:-}; bss=${3:-}
  entry=$(printf '%s\n' "$hd" | awk '/Entry point address:/ { print $4 }')
  #  Raw e_flags with readelf's decoding: "0x5, RVC, double-float ABI". This is
  #  the float-ABI authority -- ld refuses to link mixed values.
  eflags=$(printf '%s\n' "$hd" | awk '/^[ \t]*Flags:/ { sub(/^[ \t]*Flags:[ \t]*/, ""); print }')

  #  Every build-attribute tag, verbatim. The ISA tag (the full architecture
  #  string) gets its own column so a diff shows it; everything else, in
  #  readelf's order, is joined as Tag=value;Tag=value. Nothing is summarised.
  parsed=$(printf '%s\n' "$at" | awk '
    /^[ \t]*Tag_[A-Za-z0-9_]+:/ {
      line = $0; sub(/^[ \t]+/, "", line)
      i = index(line, ":"); k = substr(line, 1, i - 1); v = substr(line, i + 1)
      sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v); gsub(/"/, "", v)
      if (k == "Tag_RISCV_arch") isa = v
      else rest = rest (rest == "" ? "" : ";") k "=" v
    }
    END { printf "%s\t%s\n", isa, rest }')
  isa=${parsed%%	*}
  attrs=${parsed#*	}

  bad=
  nonblank "$compiler" || bad="$bad compiler(neither a GNAT Version string nor a .comment string in the image)"
  shape "$text"   '^[0-9]+$'    || bad="$bad text"
  shape "$data"   '^[0-9]+$'    || bad="$bad data"
  shape "$bss"    '^[0-9]+$'    || bad="$bad bss"
  shape "$entry"  '^0x[0-9a-f]+$' || bad="$bad entry"
  shape "$eflags" '^0x[0-9a-f]+' || bad="$bad eflags"
  nonblank "$isa"   || bad="$bad isa(Tag_RISCV_arch)"
  nonblank "$attrs" || bad="$bad attrs"
  if [ -n "$bad" ]; then
    err "$app: could not parse:$bad"
    return
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$app" "$compiler" "$text" "$data" "$bss" "$entry" "$eflags" "$isa" "$attrs" >> "$tmp"
}

#  Every image of every example, in a fixed order.
imgs=$(ls "$EXAMPLES"/*/bin-*/*.elf 2>/dev/null | sort)
if [ -z "$imgs" ]; then
  err "no images found (examples/*/bin-*/*.elf): build them first (./x metrics does)"
fi
for img in $imgs; do
  dir=${img%/bin-*}; rest=${img#"$dir"/bin-}
  name="$(basename "$dir")/${rest%%/*}/$(basename "$img" .elf)"
  measure "$name" "$img"
done

#  --- bless ------------------------------------------------------------------
if [ "$mode" = bless ]; then
  if [ "$errors" != 0 ]; then
    echo "FAIL: $errors error(s); $GOLDEN NOT written (a golden file is only blessed from a complete, clean measurement)" >&2
    exit 1
  fi
  if [ ! -s "$tmp" ]; then
    echo "FAIL: no images measured; $GOLDEN NOT written" >&2
    exit 1
  fi
  #  Rows for OTHER compilers are kept -- they are another host's baseline, which
  #  this host cannot measure -- but only for images that still exist, so a
  #  removed image does not linger and fail the other host. Rows for this host's
  #  (image, compiler) pairs are replaced. Kept rows come first, in their
  #  existing order, then this host's rows in build order: running bless twice
  #  on an unchanged tree writes an identical file.
  kept="$tmp.kept"
  : > "$kept"
  if [ -f "$GOLDEN" ]; then
    awk -F'\t' -v measured="$tmp" '
      BEGIN { while ((getline l < measured) > 0) { split(l, f, "\t"); M[f[1]] = 1; K[f[1], f[2]] = 1 } }
      /^[ \t]*#/ || /^[ \t]*$/ { next }
      !hdr { hdr = 1; next }
      NF == 9 && ($1 in M) && !(($1, $2) in K)' "$GOLDEN" > "$kept" ||
      { echo "FAIL: could not read existing $GOLDEN; NOT written" >&2; rm -f "$kept"; exit 1; }
  fi
  {
    cat <<'EOF'
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: CC-BY-4.0
#
# metrics.golden -- the expected size/ABI of every built image.  GENERATED by
# `./x metrics bless`; read by `./x metrics verify`.  Do not edit by hand.
#
# WORKFLOW.  change code -> `./x metrics verify` fails and shows expected vs.
# actual -> inspect that the change is the one you meant -> `./x metrics bless`
# -> commit this file's diff TOGETHER WITH the change that caused it.
#
# KEYED ON (image, compiler). A measurement is compared only with the row for
# the compiler that built it, so each host checks its own rows and `bless`
# rewrites only those. Rows for a compiler no longer pinned are deleted with the
# pin change. A compiler with no rows here fails verify with "no baseline", and
# prints the rows to add. Rows for another host's compiler are seeded from that
# host's verify output.
#
# One tab-separated row per (image, compiler):
#   image    <example>/<hart>/<elf name>, the ELF at examples/<example>/bin-<hart>/
#   compiler the image's own .comment string, i.e. the compiler that actually
#            built it, not whatever is installed
#   text     `size` text column: code + rodata (flash footprint, together with data)
#   data     `size` data column: initialised data. Not derivable from text/bss,
#            and not covered by them: a change that only grows .data would
#            otherwise pass unseen
#   bss      `size` bss column (the stack of a bare image is part of it)
#   entry    ELF entry point (e_entry): where the boot flow jumps
#   eflags   ELF e_flags, raw hex plus readelf's decoding. The float-ABI
#            authority: the linker refuses to mix values, and 'soft'/'double' is
#            read off this
#   isa      full Tag_RISCV_arch string, verbatim -- dropping zicsr, or adding a
#            Z-extension, shows up here. An E51 image has no f/d in it.
#   attrs    every other build-attribute tag (stack alignment, privileged spec,
#            ...) as Tag=value;Tag=value
# Exact string match; no tolerances.
image	compiler	text	data	bss	entry	eflags	isa	attrs
EOF
    cat "$kept" "$tmp"
  } > "$tmp.new" && mv "$tmp.new" "$GOLDEN" || { echo "FAIL: could not write $GOLDEN" >&2; rm -f "$kept"; exit 1; }
  n=$(wc -l < "$tmp" | tr -d ' ')
  k=$(wc -l < "$kept" | tr -d ' ')
  echo "blessed $n image(s) into $GOLDEN, for: $(cut -f2 "$tmp" | sort -u | tr '\n' '|' | sed 's/|$//')"
  if [ "$k" -gt 0 ]; then
    echo "kept $k row(s) for other compilers, unchecked on this host: $(cut -f2 "$kept" | sort -u | tr '\n' '|' | sed 's/|$//')"
    echo "  (delete any no host builds with any more -- nothing else will)"
  fi
  rm -f "$kept"
  exit 0
fi

#  --- verify -----------------------------------------------------------------
if [ ! -f "$GOLDEN" ]; then
  echo "FAIL: golden file '$GOLDEN' does not exist (run './x metrics bless' once, and commit it)" >&2
  exit 1
fi

#  This host's measurement, in golden format, for a CI artifact: on a host with
#  no baseline yet these are exactly the rows to review and add.
if [ -n "${MEASURED:-}" ]; then
  cp "$tmp" "$MEASURED" 2>/dev/null || echo "warning: could not write $MEASURED" >&2
fi

#  Say WHERE, and WITH WHAT, this was measured. The compiler line is the key the
#  comparison below uses.
printf 'measured on: %s\n' "$(uname -sm)"
printf 'compiler(s): %s\n' "$(cut -f2 "$tmp" | sort -u | tr '\n' '|' | sed 's/|$//')"

#  awk reads the golden file, then the measurement. It prints the human table
#  and every mismatch, and exits non-zero on any of: a malformed or empty
#  golden row, a duplicate (image, compiler), an image on one side only, an
#  image built by a compiler with no baseline row, or any differing field.
#  Golden rows for OTHER compilers are another host's baseline and are not
#  compared here.
awk -v golden="$GOLDEN" -v measure_errors="$errors" '
BEGIN {
  FS = "\t"
  nf = split("text data bss entry eflags isa attrs", fname, " ")
  printf "%-32s %-8s %-9s %-11s %s\n", "IMAGE", "TEXT", "BSS", "ENTRY", "FLOAT"
}
function label(eflags) {
  if (eflags ~ /soft-float/) return "soft"
  if (eflags ~ /double-float/) return "double"
  if (eflags ~ /single-float/) return "single"
  return "?"
}
FILENAME == golden {
  if ($0 ~ /^[ \t]*#/ || $0 ~ /^[ \t]*$/) next
  if (!seen_hdr) {
    seen_hdr = 1
    if ($1 != "image" || $2 != "compiler") { printf "FAIL: %s: first non-comment line must be the header row (image, compiler, ...)\n", golden; bad++ }
    next
  }
  if (NF != 9) { printf "FAIL: %s: malformed row (%d fields, want 9): %s\n", golden, NF, $0; bad++; next }
  if ($1 == "" || $2 == "") { printf "FAIL: %s: row with empty image or compiler: %s\n", golden, $0; bad++; next }
  if (($1, $2) in G) { printf "FAIL: %s: duplicate row for %s under compiler %s\n", golden, $1, $2; bad++; next }
  for (i = 3; i <= 9; i++)
    if ($i == "") { printf "FAIL: %s: %s (%s) has an empty %s field\n", golden, $1, $2, fname[i - 2]; bad++ }
  G[$1, $2] = 1
  if (!($1 in GA)) gorder[++ng] = $1
  GA[$1] = 1
  comps[$1] = comps[$1] (comps[$1] == "" ? "" : " | ") $2
  for (i = 3; i <= 9; i++) G[$1, $2, i - 2] = $i
  rows++
  next
}
{
  if (NF != 9) { printf "FAIL: internal: malformed measurement row: %s\n", $0; bad++; next }
  app = $1; A[app] = 1; aorder[++na] = app; C[app] = $2; row[app] = $0
  for (i = 3; i <= 9; i++) V[app, i - 2] = $i
}
END {
  if (rows == 0) { printf "FAIL: %s contains no image rows\n", golden; bad++ }
  for (k = 1; k <= na; k++) {
    app = aorder[k]; st = ""
    if (!(app in GA)) st = "FAIL (not in golden file)"
    else if (!((app, C[app]) in G)) st = "FAIL (no baseline for this compiler)"
    else for (i = 1; i <= nf; i++) if (V[app, i] != G[app, C[app], i]) { st = "FAIL"; break }
    printf "%-32s %-8s %-9s %-11s %s%s\n", app, V[app, 1], V[app, 3], V[app, 4], label(V[app, 5]), (st == "" ? "" : "   <-- " st)
  }
  for (k = 1; k <= ng; k++) {
    app = gorder[k]
    if (!(app in A)) printf "%-32s (no measurement)   <-- FAIL\n", app
  }
  print ""
  for (k = 1; k <= na; k++) {
    app = aorder[k]
    if (!(app in GA)) { printf "FAIL %s: built but absent from %s (new image? run ./x metrics bless)\n", app, golden; bad++; continue }
    if (!((app, C[app]) in G)) {
      printf "FAIL %s: no baseline for the compiler that built it\n    built by:      %s\n    baselines for: %s\n", app, C[app], comps[app]
      bad++; unseeded[++nu] = app; continue
    }
    for (i = 1; i <= nf; i++)
      if (V[app, i] != G[app, C[app], i]) {
        printf "FAIL %s.%s:\n    expected: %s\n    actual:   %s\n", app, fname[i], G[app, C[app], i], V[app, i]; bad++
      }
  }
  for (k = 1; k <= ng; k++) {
    app = gorder[k]
    if (!(app in A)) { printf "FAIL %s: in %s but not measured (image missing, or not built)\n", app, golden; bad++ }
  }
  if (nu > 0) {
    printf "\nNo baseline exists yet for the compiler that built %d image(s). These are the rows\n", nu
    printf "measured here, in %s format. Check they are what you expect, then add them --\n", golden
    printf "on this host `./x metrics bless` does exactly that and keeps every other compiler'\''s rows:\n"
    printf "----- 8< -----\n"
    for (k = 1; k <= nu; k++) print row[unseeded[k]]
    printf "----- >8 -----\n"
  }
  if (measure_errors > 0) { printf "FAIL: %d measurement error(s) above\n", measure_errors; bad++ }
  if (bad > 0) { printf "verify FAILED (%d problem(s)). If the change is intended: ./x metrics bless, and commit %s with it.\n", bad, golden; exit 1 }
  printf "verify OK: %d image(s) match %s exactly\n", na, golden
}' "$GOLDEN" "$tmp" || {
  rc=$?
  echo "hint: 'no baseline' means a different compiler built these images (see 'compiler(s):' above) -- seed its rows. A field mismatch under the SAME compiler means the source, the flags or the build changed." >&2
  exit $rc
}
