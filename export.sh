# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
# Derived from rowsail/ada_esp32s3 export.sh @ d75142d (Apache-2.0); modified for PolarFire SoC.
#
# Set up the ada_mpfs environment. SOURCE this file, do not execute it:
#
#     . /path/to/ada_mpfs/export.sh
#
# Exports ADA_MPFS_SDK (the repository root), puts tools/bin and the pinned
# toolchains on PATH and the runtime and library projects on GPR_PROJECT_PATH, so
# gprbuild and the Ada Language Server resolve `with "mpfs_pac.gpr"` and friends.
# In an interactive bash or zsh it also loads the tab completion for ./x
# (tools/completion.bash, the same script `./x completion` prints).

# Resolve this script's directory whether sourced from bash or zsh.
if [ -n "${BASH_SOURCE:-}" ]; then __mpfs_self="${BASH_SOURCE[0]}"
elif [ -n "${ZSH_VERSION:-}" ]; then __mpfs_self="${(%):-%N}"
else __mpfs_self="$0"; fi

ADA_MPFS_SDK="$(cd "$(dirname "$__mpfs_self")" && pwd)"
export ADA_MPFS_SDK
unset __mpfs_self

case ":$PATH:" in
  *":$ADA_MPFS_SDK/tools/bin:"*) ;;
  *) PATH="$ADA_MPFS_SDK/tools/bin:$PATH"; export PATH ;;
esac

. "$ADA_MPFS_SDK/tools/mpfs-env.sh"
mpfs_toolchain_on_path || echo "warning: pinned toolchain missing; run './x toolchain install'" >&2

for __gpp in "$ADA_MPFS_SDK/crates/mpfs_rts" "$ADA_MPFS_SDK"/libs/*/; do
  __gpp="${__gpp%/}"; [ -d "$__gpp" ] || continue
  case ":${GPR_PROJECT_PATH:-}:" in
    *":$__gpp:"*) ;;
    *) GPR_PROJECT_PATH="$__gpp${GPR_PROJECT_PATH:+:$GPR_PROJECT_PATH}"; export GPR_PROJECT_PATH ;;
  esac
done
unset __gpp

case "$-" in
  *i*)
    if [ -n "${BASH_VERSION:-}" ]; then
      . "$ADA_MPFS_SDK/tools/completion.bash"
    elif [ -n "${ZSH_VERSION:-}" ]; then
      autoload -U +X compinit && compinit
      autoload -U +X bashcompinit && bashcompinit
      . "$ADA_MPFS_SDK/tools/completion.bash"
    fi ;;
esac

echo "ada_mpfs SDK: $ADA_MPFS_SDK"
