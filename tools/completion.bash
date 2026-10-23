# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
#  Tab completion for ./x (bash; zsh through bashcompinit).  Printed by
#  `./x completion`; see the README for how to load it.  Verbs, sub-commands,
#  options and example names are completed; the example names are read from
#  the examples/ directory next to the x that is being completed.

_mpfs_x () {
  local cur="${COMP_WORDS[COMP_CWORD]}" prev="" verb="" sub="" xdir w i
  [ "$COMP_CWORD" -gt 0 ] && prev="${COMP_WORDS[COMP_CWORD-1]}"
  verb="${COMP_WORDS[1]:-}"; sub="${COMP_WORDS[2]:-}"
  xdir="$(dirname -- "${COMP_WORDS[0]}")"
  local verbs="help list toolchain build clean new qemu mem test metrics analyze stack svd pac trace prove hw completion"

  _mpfs_x_examples () {
    local d
    for d in "$xdir"/examples/*/; do [ -d "$d" ] && basename -- "$d"; done
  }

  if [ "$COMP_CWORD" -eq 1 ]; then
    COMPREPLY=($(compgen -W "$verbs" -- "$cur")); return
  fi

  case "$prev" in
    --hart)  COMPREPLY=($(compgen -W "e51 u54" -- "$cur")); return ;;
    --priv)  COMPREPLY=($(compgen -W "m u" -- "$cur")); return ;;
    -P)      COMPREPLY=($(compgen -W "light light-tasking embedded auto" -- "$cur")); return ;;
    --lab|--workdir|--svd) COMPREPLY=($(compgen -f -- "$cur")); return ;;
  esac

  case "$verb" in
    build)  if [ "$COMP_CWORD" -eq 2 ]; then COMPREPLY=($(compgen -W "$(_mpfs_x_examples)" -- "$cur"))
            else COMPREPLY=($(compgen -W "-P --hart --harts --priv" -- "$cur")); fi ;;
    clean|mem|qemu|stack)
            if [ "$COMP_CWORD" -eq 2 ]; then COMPREPLY=($(compgen -W "$(_mpfs_x_examples)" -- "$cur"))
            else
              case "$verb" in
                stack) COMPREPLY=($(compgen -W "--hart --top" -- "$cur")) ;;
                *)     COMPREPLY=($(compgen -W "--hart" -- "$cur")) ;;
              esac
            fi ;;
    list)   COMPREPLY=($(compgen -W "--json" -- "$cur")) ;;
    toolchain)
            if [ "$COMP_CWORD" -eq 2 ]; then COMPREPLY=($(compgen -W "install check" -- "$cur"))
            elif [ "$sub" = install ]; then
              COMPREPLY=($(compgen -W "svdtools svd2ada pac alire gnat gnatprove adalang_analyzer renode" -- "$cur"))
            fi ;;
    test)   if [ "$COMP_CWORD" -eq 2 ]; then
              COMPREPLY=($(compgen -W "host lib examples qemu renode negative metrics" -- "$cur"))
            elif [ "$sub" = qemu ] && [ "$COMP_CWORD" -eq 3 ]; then
              COMPREPLY=($(compgen -W "smoke tests" -- "$cur"))
            fi ;;
    metrics) [ "$COMP_CWORD" -eq 2 ] && COMPREPLY=($(compgen -W "verify bless" -- "$cur")) ;;
    analyze) COMPREPLY=($(compgen -W "--style --update-baseline" -- "$cur")) ;;
    svd)    if [ "$COMP_CWORD" -eq 2 ]; then COMPREPLY=($(compgen -W "merge check probe" -- "$cur"))
            elif [ "$sub" = probe ]; then COMPREPLY=($(compgen -W "--enable-clocks --all --help" -- "$cur")); fi ;;
    pac)    [ "$COMP_CWORD" -eq 2 ] && COMPREPLY=($(compgen -W "generate check" -- "$cur")) ;;
    trace)  COMPREPLY=($(compgen -W "--check" -- "$cur")) ;;
    hw)     if [ "$COMP_CWORD" -eq 2 ]; then
              COMPREPLY=($(compgen -W "bootmode openocd run probe monitor reset initialize" -- "$cur"))
            elif [ "$sub" = bootmode ]; then
              COMPREPLY=($(compgen -W "0 1 2 3 --yes --dry-run --workdir --lab" -- "$cur"))
              [ -z "$cur" ] || COMPREPLY+=($(compgen -f -- "$cur"))
            elif [ "$sub" = initialize ]; then COMPREPLY=($(compgen -W "--minimal --skip-io --dry-run --target --lab" -- "$cur"))
            elif [ "$sub" = run ]; then COMPREPLY=($(compgen -W "--expect" -- "$cur")); fi ;;
    completion) [ "$COMP_CWORD" -eq 2 ] && COMPREPLY=($(compgen -W "bash zsh" -- "$cur")) ;;
  esac
}
complete -o default -F _mpfs_x x ./x
