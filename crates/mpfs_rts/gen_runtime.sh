#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Build one variant of the runtime from its pack: build/rts/<profile>-<hart>-cpus<n>-<priv>/.
#
#   gen_runtime.sh [options] <profile> <hart> <cpus> <priv>
#
#   profile   light | light-tasking | embedded
#   hart      e51 | u54          hart class (-march and -mabi come from the pack's runtime.xml)
#   cpus      1                  (SMP: P8)
#   priv      m                  (U mode: P7)
#
#   --check          do not build; exit 0 if the variant is up to date, 1 if it would be rebuilt
#   --force          rebuild even if the variant is up to date
#   --out DIR        root of the variants (default: $MPFS_RTS_ROOT, else build/rts)
#   --packs DIR      the packs (default: $MPFS_RTS_PACKS, else build/rts/packs)
#   --hashes FILE    the hash file of the packs (default: crates/mpfs_rts/packs.sha256)
#   --port-dir DIR   own port units (default: crates/mpfs_rts/mpfs)
#   --overlay-dir DIR  the overlays (default: crates/mpfs_rts/overlays)
#   --ld-dir DIR     the linker scripts (default: crates/mpfs_rts/ld)
#   --pac-dir DIR    the generated register packages (default: libs/mpfs_pac/src/generated)
#
# Environment: MPFS_RTS_BUILD = Production (default) | Debug | Assert, the BUILD switch of the
# pack's target_options.gpr.
#
# What it does:
#   1. get the pack: make_packs.sh --ensure --cells <profile>-<hart> makes
#      <packs>/<profile>-<hart>.tar.zst exist and match packs.sha256 (it generates the pack, about
#      20 s, only if it is missing, unreadable or different), and unpack it into a work directory
#      next to the result; --check does not generate, a missing pack is "not up to date";
#   2. lay the own port units (--port-dir) and then the overlays (--overlay-dir, one directory
#      per overlay, in the order of their names) over it: <dir>/gnat/*, <dir>/gnarl/* replace
#      or add sources, <dir>/ld/* goes to ld/; the files named in <dir>/remove.list (paths in the
#      pack, one per line) are deleted from the pack first, which is how an own port unit
#      replaces a source of the pack that has another name (start.S for start-ram.S);
#      then the linker scripts (--ld-dir) go to ld/, whatever the overlays brought; the
#      register packages that the port units use (MPFS_Registers, .PLIC and .CLINT of
#      --pac-dir: the PAC of libs/mpfs_pac, not a copy in the repository) go to gnat/;
#   3. build libgnat.a with runtime_build.gpr and, except for light, libgnarl.a with
#      ravenscar_build.gpr. Both are ordinary library projects (static, no binder, no ar by hand);
#   4. leave the result as a runtime directory: adainclude/ (all sources), adalib/ (.ali files,
#      libgnat.a, libgnarl.a), ld/ (-L directory of the link; the partition data brings the linker
#      scripts), runtime.xml, the license texts, and the stamp .mpfs_rts.stamp.
#
# Cache: the stamp holds the key, the sha256 of everything that goes into the result: the pack,
# the port units, the overlays, the switches (variant, build mode, this script) and the toolchain
# (the directory name of the installed GNAT, which carries the Alire version and a hash, and the
# versions reported by gcc and gprbuild). A variant whose stamp has the same key and whose files
# are all there is reused; anything else is rebuilt into a work directory and then moved into
# place, so an aborted build leaves no half variant behind.
#
# Exit status: 0 ok, 1 not up to date (--check), 2 set-up or build error.

set -eu
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

die () { echo "gen_runtime: $*" >&2; exit 2; }

out="${MPFS_RTS_ROOT:-$ROOT/build/rts}"
packs="${MPFS_RTS_PACKS:-$ROOT/build/rts/packs}"
hashes="$HERE/packs.sha256"
port_dir="$HERE/mpfs"
overlay_dir="$HERE/overlays"
ld_dir="$HERE/ld"
pac_dir="$ROOT/libs/mpfs_pac/src/generated"
# The register packages of the PAC that the port units of the runtime use (s-bbripl, s-bbsuti).
pac_files="mpfs_registers.ads mpfs_registers-plic.ads mpfs_registers-clint.ads"
check=0
force=0
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --check) check=1 ;;
    --force) force=1 ;;
    --out)         shift; [ $# -gt 0 ] || die "--out needs a directory"; out="$1" ;;
    --packs)       shift; [ $# -gt 0 ] || die "--packs needs a directory"; packs="$1" ;;
    --hashes)      shift; [ $# -gt 0 ] || die "--hashes needs a file"; hashes="$1" ;;
    --port-dir)    shift; [ $# -gt 0 ] || die "--port-dir needs a directory"; port_dir="$1" ;;
    --overlay-dir) shift; [ $# -gt 0 ] || die "--overlay-dir needs a directory"; overlay_dir="$1" ;;
    --ld-dir)      shift; [ $# -gt 0 ] || die "--ld-dir needs a directory"; ld_dir="$1" ;;
    --pac-dir)     shift; [ $# -gt 0 ] || die "--pac-dir needs a directory"; pac_dir="$1" ;;
    -h|--help) sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option '$1'" ;;
    *) args+=("$1") ;;
  esac
  shift
done
[ ${#args[@]} -eq 4 ] || die "usage: gen_runtime.sh [options] <profile> <hart> <cpus> <priv>"
profile="${args[0]}"; hart="${args[1]}"; cpus="${args[2]}"; priv="${args[3]}"

case "$profile" in light|light-tasking|embedded) ;; *) die "invalid profile '$profile' (light|light-tasking|embedded)" ;; esac
case "$hart" in e51|u54) ;; *) die "invalid hart '$hart' (e51|u54)" ;; esac
case "$cpus" in
  1) ;;
  2|3|4) die "cpus $cpus: the runtime is single-CPU until the SMP work package (P8)" ;;
  *) die "invalid cpus '$cpus' (1)" ;;
esac
case "$priv" in
  m) ;;
  u) die "priv u: the runtime runs in M mode until the U-mode work package (P7)" ;;
  *) die "invalid priv '$priv' (m)" ;;
esac
build="${MPFS_RTS_BUILD:-Production}"
case "$build" in Production|Debug|Assert) ;; *) die "invalid MPFS_RTS_BUILD '$build' (Production|Debug|Assert)" ;; esac

variant="$profile-$hart-cpus$cpus-$priv"
pack="$packs/$profile-$hart.tar.zst"
command -v zstd >/dev/null 2>&1 || die "zstd is not installed"
tar --version 2>&1 | grep -q 'GNU tar' || die "GNU tar is required"

# shellcheck source=tools/mpfs-env.sh
. "$ROOT/tools/mpfs-env.sh"
mpfs_toolchain_on_path >/dev/null 2>&1 || mpfs_toolchain_on_path || die "pinned toolchain missing (./x toolchain install gnat)"
command -v riscv64-elf-gcc >/dev/null 2>&1 || die "riscv64-elf-gcc not found"
command -v gprbuild >/dev/null 2>&1 || die "gprbuild not found"

sha () { sha256sum | cut -d' ' -f1; }
# The content of a directory as one hash: names, modes and bytes of its files; an absent or an
# empty directory has the hash of nothing.
tree_hash () {
  if [ -d "$1" ]; then
    ( cd "$1" && find . -type f | sort | while IFS= read -r f; do
        printf '%s %s\n' "$f" "$(sha < "$f")"
      done ) | sha
  else
    printf '' | sha
  fi
}
# The overlays are applied in the order of their names, so the names are part of the hash.
overlay_hash () {
  local d
  if [ -d "$1" ]; then
    for d in "$1"/*/; do
      [ -d "$d" ] || continue
      printf '%s %s\n' "$(basename "$d")" "$(tree_hash "$d")"
    done | sha
  else
    printf '' | sha
  fi
}

gcc_bin="$(command -v riscv64-elf-gcc)"
gcc_bin="$(readlink -f "$gcc_bin")"
toolchain_id="$(basename "$(dirname "$(dirname "$gcc_bin")")")"
toolchain="$toolchain_id | $(riscv64-elf-gcc --version | head -1) | $(gprbuild --version | head -1)"

# The pack: the hash that identifies its content is the SHA-256 of the uncompressed tar stream,
# which is what packs.sha256 records (the compressed bytes depend on the zstd release). It is
# taken from the pack itself, so the key follows the pack that was really generated.
stream_sha () { zstd -dc "$1" | sha256sum | cut -d' ' -f1; }
if [ "$check" = 1 ]; then
  [ -f "$pack" ] || { echo "gen_runtime: $variant is not up to date (pack $profile-$hart is not generated)"; exit 1; }
else
  ens="$(bash "$HERE/make_packs.sh" --ensure --cells "$profile-$hart" --out "$packs" --hashes "$hashes" 2>&1)" \
    || { echo "$ens" >&2; die "make_packs.sh --ensure failed for $profile-$hart"; }
  case "$ens" in *regenerating*|*warning*) echo "$ens" | grep -v '^ok: ' ;; esac
fi
pack_sha="$(stream_sha "$pack")" || die "cannot read the pack $pack"

for f in $pac_files; do
  [ -f "$pac_dir/$f" ] || die "no $pac_dir/$f (./x pac generate)"
done
pac_hash () { for f in $pac_files; do printf '%s %s\n' "$f" "$(sha < "$pac_dir/$f")"; done | sha; }

key="$( {
  echo "pack $pack_sha"
  echo "pac $(pac_hash)"
  echo "port-units $(tree_hash "$port_dir")"
  echo "overlays $(overlay_hash "$overlay_dir")"
  echo "ld $(tree_hash "$ld_dir")"
  echo "switches $variant build=$build"
  echo "script $(sha < "${BASH_SOURCE[0]}")"
  echo "toolchain $toolchain"
} | sha )"

final="$out/$variant"
stamp="$final/.mpfs_rts.stamp"

up_to_date () {
  [ -f "$stamp" ] && grep -qx "key=$key" "$stamp" \
    && [ -f "$final/adalib/libgnat.a" ] \
    && { [ "$profile" = light ] || [ -f "$final/adalib/libgnarl.a" ]; } \
    && [ -d "$final/adainclude" ] && [ -f "$final/runtime.xml" ] && [ -d "$final/ld" ]
}

short="${key:0:12}"
if [ "$force" = 0 ] && up_to_date; then
  echo "gen_runtime: $variant is up to date (key $short)"
  exit 0
fi
if [ "$check" = 1 ]; then
  echo "gen_runtime: $variant is not up to date (key $short)"
  exit 1
fi

echo "gen_runtime: building $variant (key $short, $build)"
mkdir -p "$out"
work="$(mktemp -d "$out/.$variant.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# 1. unpack
tar --zstd -xf "$pack" -C "$work" --strip-components=1 || die "unpacking $pack failed"
for f in runtime_build.gpr target_options.gpr runtime.xml gnat; do
  [ -e "$work/$f" ] || die "$(basename "$pack") has no $f"
done
if [ "$profile" != light ]; then
  [ -f "$work/ravenscar_build.gpr" ] || die "$(basename "$pack") has no ravenscar_build.gpr"
fi

# 2. port units, then the overlays
overlay_from () {   # overlay_from <directory>
  local sub
  for sub in gnat gnarl ld; do
    [ -d "$1/$sub" ] || continue
    mkdir -p "$work/$sub"
    cp -R "$1/$sub/." "$work/$sub/"
  done
}
# Files of the pack that an own port unit replaces under another name.
if [ -f "$port_dir/remove.list" ]; then
  while IFS= read -r f; do
    case "$f" in ''|'#'*) continue ;; esac
    case "$f" in /*|*..*) die "$port_dir/remove.list: '$f' is not a path inside the pack" ;; esac
    [ -f "$work/$f" ] || die "$port_dir/remove.list: $(basename "$pack") has no $f"
    rm -f "$work/$f"
  done <"$port_dir/remove.list"
fi
overlay_from "$port_dir"
if [ -d "$overlay_dir" ]; then
  for d in "$overlay_dir"/*/; do
    [ -d "$d" ] && overlay_from "${d%/}"
  done
fi

# The register packages of the PAC: the port units that use them are compiled with the runtime,
# so the registers have one definition, the SVD, for the runtime and for the application. They
# replace nothing of the pack.
mkdir -p "$work/gnat"
for f in $pac_files; do
  [ ! -e "$work/gnat/$f" ] || die "the pack has a gnat/$f of its own"
  # Byte for byte the file of the PAC: an application that compiles the PAC itself (mpfs_pac.gpr)
  # has the same units, and the binder compares their checksums.
  cp "$pac_dir/$f" "$work/gnat/$f"
done
# The runtime is compiled with -gnatg, whose style checks reject the header of the generated
# files (a line longer than 79, also when a unit that withs them is compiled): the line length
# limit is 120 for the runtime. The other style checks of -gnatg stay.
sed -i 's|^  ADAFLAGS := ("-gnatg", |  ADAFLAGS := ("-gnatg", "-gnatyM120", |' "$work/target_options.gpr"
grep -q 'gnatyM120' "$work/target_options.gpr" || die "target_options.gpr of $(basename "$pack") has no ADAFLAGS to extend"

# The linker scripts of the runtime (the partition data brings the values, not the scripts).
if [ -d "$ld_dir" ]; then
  mkdir -p "$work/ld"
  cp -R "$ld_dir/." "$work/ld/"
fi

# The link directory of the runtime is ld/ (the pack names it ld_user).
sed -i 's|/ld_user"|/ld"|' "$work/runtime.xml"
grep -q '/ld"' "$work/runtime.xml" || die "runtime.xml of $(basename "$pack") has no link directory to rename"
mkdir -p "$work/ld"

# 3. build. The debug info and __FILE__ name the sources where the result keeps them
# (adainclude/ of the variant), and a variant below the repository root is named relative to it
# ("./build/rts/..."), as the examples do with ADA_MPFS_SDK: the directory of the checkout, and the
# random work directory, must not reach an image (./x repro builds in two directories). The
# switches are not recorded in the debug info either: they name the work directory and a
# temporary file of gprbuild.
shown="$final"
case "$final" in "$ROOT"/*) shown="./${final#"$ROOT"/}" ;; esac
maps=(-gno-record-gcc-switches)
for d in gnat gnarl gnat_user gnarl_user; do
  maps+=("-ffile-prefix-map=$work/$d=$shown/adainclude")
done
maps+=("-ffile-prefix-map=$work=$shown")
log="$work/build.log"
gpr () {   # gpr <project>
  ( cd "$work" && gprbuild -p -j0 -P "$1" -XBUILD="$build" -XLIBRARY_TYPE=static \
      -cargs "${maps[@]}" ) >>"$log" 2>&1 || { tail -n 40 "$log" >&2; die "building $variant failed ($1)"; }
}
: >"$log"
gpr runtime_build.gpr
[ -f "$work/adalib/libgnat.a" ] || { cat "$log" >&2; die "building $variant produced no adalib/libgnat.a"; }
if [ "$profile" != light ]; then
  gpr ravenscar_build.gpr
  [ -f "$work/adalib/libgnarl.a" ] || { cat "$log" >&2; die "building $variant produced no adalib/libgnarl.a"; }
fi

# 4. the runtime directory: adainclude/ takes the sources (what the first directory of a
# project's Source_Dirs has, wins), the build leftovers go.
mkdir -p "$work/adainclude"
for d in gnarl gnat gnarl_user gnat_user; do
  [ -d "$work/$d" ] && cp -R "$work/$d/." "$work/adainclude/"
done
rm -rf "$work/gnat" "$work/gnarl" "$work/gnat_user" "$work/gnarl_user" "$work/obj" "$work/ld_user" \
       "$work/ada_source_path" "$work/ada_object_path" "$work"/*.gpr "$work/build.log"
{
  echo "key=$key"
  echo "pack=$(basename "$pack")"
  echo "pack_sha256=$pack_sha"
  echo "variant=$variant"
  echo "build=$build"
  echo "toolchain=$toolchain"
} >"$work/.mpfs_rts.stamp"
chmod 755 "$work"

rm -rf "$final"
mv "$work" "$final"
trap - EXIT
echo "gen_runtime: built $variant in ${final#"$ROOT"/}"
