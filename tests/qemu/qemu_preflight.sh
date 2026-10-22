#  SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
#  SPDX-License-Identifier: Apache-2.0
#  Derived from ThyMYthOS/ada-machine rts-spikes/qemu_preflight.sh @ 2f0be23; modified for PolarFire SoC.
#
#  qemu_preflight.sh -- the QEMU preconditions shared by the QEMU test scripts.
#  SOURCED, not executed:   . tests/qemu/qemu_preflight.sh
#
#  The "QEMU too old / absent / without the machine is a FAILURE, never a skip"
#  rule lives in this one place.
#
#  The caller must define, before sourcing:
#    fail()          prints "FAIL: ..." and exits non-zero
#    QEMU            qemu-system-riscv64 binary (name on PATH, or a path)
#    QEMU_MACHINE    microchip-icicle-kit
#    QEMU_MIN        oldest acceptable QEMU, "major.minor"; "0" disables the check
#
#  POSIX sh only.

#  --- QEMU: loud preconditions ----------------------------------------------
command -v "$QEMU" >/dev/null 2>&1 \
  || fail "QEMU not found: '$QEMU'. Install qemu-system-riscv64 $QEMU_MIN or newer (Ubuntu 26.04: apt install qemu-system-riscv; macOS: brew install qemu), or pass QEMU=<path>. Nothing was booted."

qver=$("$QEMU" --version 2>&1 | head -n 1)
[ -n "$qver" ] || fail "'$QEMU --version' printed nothing; this is not a usable QEMU"
printf 'QEMU:    %s\n' "$qver"
printf 'host:    %s\n' "$(uname -sm)"

#  Version floor. Read from QEMU's source, the `-kernel` without `-dtb` path
#  (what `-bios none` relies on) first appears in 10.1.0 -- 10.0.0 and earlier
#  only boot a kernel that comes with a device tree and otherwise load HSS, so
#  on those NOTHING of ours would run. Failing here turns "mysteriously silent"
#  into a sentence.
if [ "$QEMU_MIN" != 0 ]; then
  have=$(printf '%s\n' "$qver" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+\.[0-9]+/) { split($i, v, "."); print v[1] " " v[2]; exit } }')
  if [ -z "$have" ]; then
    printf 'WARNING: could not read a version out of "%s"; the %s floor was not checked\n' "$qver" "$QEMU_MIN" >&2
  else
    set -- $have
    hmaj=$1; hmin=$2
    mmaj=${QEMU_MIN%%.*}; mmin=${QEMU_MIN#*.}
    if [ "$hmaj" -lt "$mmaj" ] || { [ "$hmaj" -eq "$mmaj" ] && [ "$hmin" -lt "$mmin" ]; }; then
      fail "QEMU $hmaj.$hmin is older than $QEMU_MIN. Before 10.1 the microchip-icicle-kit machine boots '-kernel' only together with '-dtb' and otherwise loads HSS, so '-bios none -kernel' starts nothing of ours (hw/riscv/microchip_pfsoc.c, v10.0.0 vs v10.1.0). Use a newer QEMU, or QEMU_MIN=0 to try anyway."
    fi
  fi
fi

machines=$("$QEMU" -M help 2>&1)
printf '%s\n' "$machines" | grep -q "^$QEMU_MACHINE[[:space:]]" \
  || fail "this QEMU has no machine '$QEMU_MACHINE' (qemu -M help | grep -i microchip found nothing)"
