# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
# Derived from rowsail/ada_esp32s3 tools/sdk-env.sh @ d75142d (Apache-2.0); modified for PolarFire SoC.
#
# Toolchain environment for ada_mpfs. SOURCE this file, do not execute it.
#
# Resolves the RISC-V cross GNAT, gprbuild and the native GNAT from a search
# root and puts exactly the versions pinned in tools/toolchain.env on PATH.
# Unlike a "newest wins" lookup, a missing or different version is an error.
#
#   MPFS_ADA_TOOLCHAINS  search root holding the gnat_*/gprbuild_* directories.
#                        Default: Alire's install dir. A bundled
#                        $ADA_MPFS_SDK/toolchains takes precedence.

__mpfs_env_self="${BASH_SOURCE[0]:-$0}"
MPFS_TOOLS_DIR="$(cd "$(dirname "$__mpfs_env_self")" && pwd)"
unset __mpfs_env_self

set -a
# shellcheck source=tools/toolchain.env
. "$MPFS_TOOLS_DIR/toolchain.env"
set +a

: "${MPFS_ADA_TOOLCHAINS:=$HOME/.local/share/alire/toolchains}"
if [ -n "${ADA_MPFS_SDK:-}" ] && [ -d "$ADA_MPFS_SDK/toolchains" ]; then
    MPFS_ADA_TOOLCHAINS="$ADA_MPFS_SDK/toolchains"   # bundled toolchain wins
fi
export MPFS_ADA_TOOLCHAINS

# bin/ of the exactly pinned version of crate $1 ($2 = version); empty if absent.
mpfs_tc_bin () {
    { ls -d "$MPFS_ADA_TOOLCHAINS"/"$1"_"$2"_*/bin 2>/dev/null || true; } | head -1
}

# Put the pinned gprbuild, cross GNAT and native GNAT on PATH (idempotent).
# Returns 1 and names what is missing if a pinned version is not installed.
mpfs_toolchain_on_path () {
    MPFS_GPRBUILD_BIN="$(mpfs_tc_bin gprbuild "$GPRBUILD_VERSION")"
    MPFS_GNAT_RISCV64_BIN="$(mpfs_tc_bin gnat_riscv64_elf "$GNAT_RISCV64_VERSION")"
    MPFS_GNAT_NATIVE_BIN="$(mpfs_tc_bin gnat_native "$GNAT_NATIVE_VERSION")"
    export MPFS_GPRBUILD_BIN MPFS_GNAT_RISCV64_BIN MPFS_GNAT_NATIVE_BIN
    local d rc=0
    for d in "$MPFS_GPRBUILD_BIN" "$MPFS_GNAT_RISCV64_BIN" "$MPFS_GNAT_NATIVE_BIN"; do
        [ -n "$d" ] || continue
        case ":$PATH:" in *":$d:"*) ;; *) PATH="$d:$PATH" ;; esac
    done
    export PATH
    [ -n "$MPFS_GPRBUILD_BIN" ]      || { echo "mpfs: gprbuild $GPRBUILD_VERSION not installed in $MPFS_ADA_TOOLCHAINS" >&2; rc=1; }
    [ -n "$MPFS_GNAT_RISCV64_BIN" ]  || { echo "mpfs: gnat_riscv64_elf $GNAT_RISCV64_VERSION not installed in $MPFS_ADA_TOOLCHAINS" >&2; rc=1; }
    [ -n "$MPFS_GNAT_NATIVE_BIN" ]   || { echo "mpfs: gnat_native $GNAT_NATIVE_VERSION not installed in $MPFS_ADA_TOOLCHAINS" >&2; rc=1; }
    return $rc
}

# First x.y[.z] version number in the output of a command line ($@), or empty.
mpfs_version_of () {
    "$@" 2>&1 | head -5 | grep -Eo '[0-9]+(\.[0-9]+)+' | head -1
}

# True if version $1 >= $2.
mpfs_version_ge () {
    [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]
}

# Report on all tools, one line each; returns 1 if any check failed.
#   ok       installed and equal to the pin
#   ERROR    installed but different, or a required tool is missing
#   absent   optional tool (not needed yet) not installed
#   unpinned pin in tools/toolchain.env is empty
mpfs_toolchain_check () {
    local rc=0
    _mpfs_row () { printf '  %-20s %-9s %s\n' "$1" "$2" "$3"; }
    # _exact <name> <pinned> <found> <required: 1|0>
    _exact () {
        if [ -z "$2" ]; then _mpfs_row "$1" unpinned "no pin in tools/toolchain.env"
        elif [ -z "$3" ]; then
            if [ "$4" = 1 ]; then _mpfs_row "$1" ERROR "not found (want $2)"; rc=1
            else _mpfs_row "$1" absent "(want $2)"; fi
        elif [ "$3" = "$2" ]; then _mpfs_row "$1" ok "$3"
        else _mpfs_row "$1" ERROR "found $3, want $2"; rc=1; fi
    }
    # _min <name> <minimum> <found> <required>
    _min () {
        if [ -z "$3" ]; then
            if [ "$4" = 1 ]; then _mpfs_row "$1" ERROR "not found (want >= $2)"; rc=1
            else _mpfs_row "$1" absent "(want >= $2)"; fi
        elif mpfs_version_ge "$3" "$2"; then _mpfs_row "$1" ok "$3 (>= $2)"
        else _mpfs_row "$1" ERROR "found $3, want >= $2"; rc=1; fi
    }
    echo "Toolchain (pins: $MPFS_TOOLS_DIR/toolchain.env, search root: $MPFS_ADA_TOOLCHAINS)"

    local v
    v=; command -v alr >/dev/null 2>&1 && v="$(mpfs_version_of alr --version)"
    _exact alr "$ALR_VERSION" "$v" 1

    local b
    for spec in "gprbuild:$GPRBUILD_VERSION:gprbuild" \
                "gnat_riscv64_elf:$GNAT_RISCV64_VERSION:riscv64-elf-gcc" \
                "gnat_native:$GNAT_NATIVE_VERSION:gcc"; do
        local crate="${spec%%:*}" rest="${spec#*:}"
        local want="${rest%%:*}" exe="${rest#*:}"
        b="$(mpfs_tc_bin "$crate" "$want")"
        # The pin is the Alire package version, which is not the version the
        # binary reports (package gnat_*_15.3.1 contains GCC 15.3.0). So the
        # binary found on PATH must be the one from the pinned package.
        if [ -n "$b" ] && [ "$(command -v "$exe" 2>/dev/null)" = "$b/$exe" ]; then
            v="$want"
        elif [ -n "$b" ]; then
            _mpfs_row "$crate" ERROR "installed but not first on PATH (source export.sh)"; rc=1; continue
        elif command -v "$exe" >/dev/null 2>&1; then
            _mpfs_row "$crate" ERROR "pinned $want not installed; PATH has $(command -v "$exe")"; rc=1; continue
        else
            v=
        fi
        _exact "$crate" "$want" "$v" 1
    done

    v=; command -v python3 >/dev/null 2>&1 && v="$(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])')"
    _min python3 "$PYTHON_MIN" "$v" 1
    v=; command -v qemu-system-riscv64 >/dev/null 2>&1 && v="$(mpfs_version_of qemu-system-riscv64 --version)"
    _min qemu-system-riscv64 "$QEMU_MIN" "$v" 0
    v=; command -v svdtools >/dev/null 2>&1 && v="$(mpfs_version_of svdtools --version)"
    _exact svdtools "$SVDTOOLS_VERSION" "$v" 0
    v=; command -v gnatprove >/dev/null 2>&1 && v="$(mpfs_version_of gnatprove --version)"
    _exact gnatprove "$GNATPROVE_VERSION" "$v" 0
    v=; command -v adalang_analyzer >/dev/null 2>&1 && v="$(mpfs_version_of adalang_analyzer --version)"
    _exact adalang_analyzer "$ADALANG_ANALYZER_VERSION" "$v" 0
    v=; command -v renode >/dev/null 2>&1 && v="$(mpfs_version_of renode --version)"
    _exact renode "$RENODE_VERSION" "$v" 0
    if [ -n "${MPFS_SVD2ADA:-}" ] || command -v svd2ada >/dev/null 2>&1; then
        _mpfs_row svd2ada ok "built from source, pin $SVD2ADA_COMMIT is verified by 'pac check'"
    else
        _mpfs_row svd2ada absent "(pin ${SVD2ADA_COMMIT:0:7})"
    fi
    unset -f _mpfs_row _exact _min
    return $rc
}
