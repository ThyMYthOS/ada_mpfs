# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Build of a bare image: no binder, no runtime. SOURCED by the build.sh of an
# example, which runs in the example directory with the pinned toolchain on
# PATH and the scenario variables of examples/STYLE.md in the environment:
#
#   . ../common/bare_build.sh
#   bare_build <image> <object>...
#
# gprbuild only compiles (-c) the sources of app.gpr; the objects named (base
# names in obj-<hart>/) are linked with the linker script of examples/common/ld
# into bin-<hart>/<image>.elf. This is the pattern of a bootloader that is
# built against the runtime for its system.ads only: no unit of the runtime
# is bound or linked.
#
#   Harts mask   bit n set = hart n runs the image (E51 = hart 0, U54 = 1 .. 4);
#                start.S parks every other hart. It reaches start.S as the
#                absolute symbol __mpfs_harts_mask (--defsym).

bare_build () {
  local image="$1"; shift
  local hart="${MPFS_HART:-e51}" harts="${MPFS_HARTS:-}" mask objs=() o
  case "$hart" in
    e51) [ -z "$harts" ] || { echo "bare_build: --harts needs the u54" >&2; return 1; }
         mask=1 ;;
    u54) case "${harts:-1}" in
           1) mask=2 ;; 2) mask=4 ;; 3) mask=8 ;; 4) mask=16 ;;
           *) echo "bare_build: a bare image runs on one U54 hart (1-4), not '$harts'" >&2; return 1 ;;
         esac ;;
    *) echo "bare_build: invalid MPFS_HART '$hart'" >&2; return 1 ;;
  esac

  gprbuild -c -p -P app.gpr -XMPFS_HART="$hart" || return 1
  for o in "$@"; do
    [ -f "obj-$hart/$o.o" ] || { echo "bare_build: obj-$hart/$o.o was not built" >&2; return 1; }
    objs+=("obj-$hart/$o.o")
  done
  mkdir -p "bin-$hart"
  bare_link "$mask" "bin-$hart/$image" "${objs[@]}"
}

# bare_link <mask> <output base> <object>...
# Links the objects into <base>.elf (and <base>.map) with the linker script of
# examples/common/ld, from any directory. The compiler driver is BARE_CC
# (default riscv64-elf-gcc). The memory regions: literal ORIGINs in
# mpfs-memory.ld, LENGTHs by symbol; only the L2 LIM (1920 KB at reset, no setup
# needed) and the eNVM are non-zero.
bare_link () {
  local mask="$1" base="$2" ld; shift 2
  ld="$(cd "$(dirname "${BASH_SOURCE[0]}")/ld" && pwd)"
  "${BARE_CC:-riscv64-elf-gcc}" -nostdlib -static -L "$ld" -T "$ld/place-lim.ld" \
    -Wl,--gc-sections -Wl,--no-warn-rwx-segments -Wl,-Map,"$base.map" \
    -Wl,--defsym=__mpfs_harts_mask="$mask" \
    -Wl,--defsym=__stack_size=16384 \
    -Wl,--defsym=MPFS_ENVM_LENGTH=0x1ff00 \
    -Wl,--defsym=MPFS_DTIM_LENGTH=0 \
    -Wl,--defsym=MPFS_E51_ITIM_LENGTH=0 \
    -Wl,--defsym=MPFS_U54_1_ITIM_LENGTH=0 \
    -Wl,--defsym=MPFS_U54_2_ITIM_LENGTH=0 \
    -Wl,--defsym=MPFS_U54_3_ITIM_LENGTH=0 \
    -Wl,--defsym=MPFS_U54_4_ITIM_LENGTH=0 \
    -Wl,--defsym=MPFS_LOCAL_ITIM_ORIGIN=0x01800000 \
    -Wl,--defsym=MPFS_LOCAL_ITIM_LENGTH=0 \
    -Wl,--defsym=MPFS_LIM_LENGTH=0x1e0000 \
    -Wl,--defsym=MPFS_SCRATCHPAD_LENGTH=0 \
    -Wl,--defsym=MPFS_DDR_CACHED_LENGTH=0 \
    -Wl,--defsym=MPFS_DDR_NC_LENGTH=0 \
    -Wl,--defsym=MPFS_DDR_WCB_LENGTH=0 \
    "$@" -o "$base.elf"
}
