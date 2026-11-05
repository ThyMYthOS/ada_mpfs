#!/bin/bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# SessionStart hook for Claude Code cloud sessions: makes the pinned toolchain
# of tools/toolchain.env available, so that ./x build, ./x test host,
# ./x test qemu, ./x prove and ./x pac work.
#
#   - GNAT (riscv64-elf and native), gprbuild, gnatprove, svdtools, svd2ada,
#     Renode, adalang_analyzer: ./x toolchain install (idempotent; each is
#     installed into a per-version prefix and skipped when present).
#   - QEMU 10.1 or newer (QEMU_MIN): the system package of the image is older,
#     and ./x test qemu refuses to run with it. The pinned release is built
#     from source (riscv64-softmmu only) into $HOME/.local/opt and linked into
#     /usr/local/bin.
#   - System packages the image lacks: libgmp-dev, the external dependency
#     libgmp of gnatcoll_gmp (needed by adalang_analyzer; the image has only the
#     shared library), and zstd, which the runtime packs need (without it the
#     host tests skip every image build).
#
# GitHub tag archives: Alire fetches most AdaCore crates (xmlada for svd2ada;
# gnatcoll, libgpr, langkit, ... for adalang_analyzer) as
# github.com/<owner>/<repo>/archive/refs/tags/<tag>.zip. The proxy of the cloud
# session answers 403 to these downloads (also codeload.github.com and the API),
# whatever the list of allowed domains says, and add_repo does not change that;
# `git clone` of a public repository works. alire_git_index.py therefore writes
# an index with the same releases fetched as git checkouts of the tag commits
# (a binary release such as gprconfig_kb as an archive packed locally from the
# tag), and the hook registers it in front of the community index (name mpfs_git).
set -euo pipefail

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0

cd "${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

QEMU_VERSION=10.2.1
# git archive of the tag; download.qemu.org and github.com/archive are refused
# by the proxy of the cloud session, gitlab.com is not
QEMU_URL="https://gitlab.com/qemu-project/qemu/-/archive/v$QEMU_VERSION/qemu-v$QEMU_VERSION.tar.gz"
QEMU_SHA256=93878bb2a9dcbe8dbcb818ae582396d5145bb8b1a25986126613d9f4360b9098
QEMU_PREFIX="$HOME/.local/opt/qemu-$QEMU_VERSION"


# QEMU_MIN from the pin file ("10.1")
qemu_min="$(sed -n 's/^QEMU_MIN=//p' tools/toolchain.env)"
have_qemu () {
  local v
  v="$(qemu-system-riscv64 --version 2>/dev/null | sed -n '1s/.* version \([0-9][0-9.]*\).*/\1/p')"
  [ -n "$v" ] && [ "$(printf '%s\n%s\n' "$qemu_min" "$v" | sort -V | head -1)" = "$qemu_min" ]
}

if have_qemu; then
  echo "session-start: qemu-system-riscv64 is new enough" >&2
else
  if [ ! -x "$QEMU_PREFIX/bin/qemu-system-riscv64" ]; then
    echo "session-start: building QEMU $QEMU_VERSION (riscv64-softmmu)" >&2
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    curl -fsSL -o "$work/qemu.tar.gz" "$QEMU_URL"
    echo "$QEMU_SHA256  $work/qemu.tar.gz" | sha256sum -c - >&2
    tar -C "$work" -xzf "$work/qemu.tar.gz"
    mkdir "$work/build"
    ( cd "$work/build" \
      && "../qemu-v$QEMU_VERSION/configure" --prefix="$QEMU_PREFIX" \
           --target-list=riscv64-softmmu --disable-docs --disable-user \
           --disable-guest-agent --disable-tools >&2 \
      && make -j"$(nproc)" >&2 \
      && make install >&2 )
  fi
  ln -sf "$QEMU_PREFIX/bin/qemu-system-riscv64" /usr/local/bin/qemu-system-riscv64
  if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
    echo "export PATH=\"$QEMU_PREFIX/bin:\$PATH\"" >> "$CLAUDE_ENV_FILE"
  fi
fi
packages=()
[ -e /usr/include/gmp.h ] || [ -e /usr/include/x86_64-linux-gnu/gmp.h ] || packages+=(libgmp-dev)
command -v zstd >/dev/null 2>&1 || packages+=(zstd)
if [ "${#packages[@]}" -gt 0 ]; then
  echo "session-start: installing ${packages[*]}" >&2
  { apt-get install -y --no-install-recommends "${packages[@]}" >&2 \
    || { apt-get update >&2 && apt-get install -y --no-install-recommends "${packages[@]}" >&2; }; } \
    || echo "session-start: installing ${packages[*]} failed (adalang_analyzer needs libgmp-dev, the image builds zstd)" >&2
fi

echo "session-start: toolchains" >&2
problem () { echo "session-start: $1 reported problems (see above)" >&2; }

# gnat first: it installs alr, which the git index needs
./x toolchain install gnat || problem "./x toolchain install gnat"

git_index="$HOME/.local/share/ada_mpfs/alire-git-index"
analyzer_version="$(sed -n 's/^ADALANG_ANALYZER_VERSION=//p' tools/toolchain.env)"
# xmlada: the dependency of svd2ada (./x toolchain install pac builds it)
if ( . ./export.sh >/dev/null 2>&1
     python3 .claude/hooks/alire_git_index.py "$git_index" "adalang_analyzer=$analyzer_version" xmlada
     alr index --list | grep -q '^[0-9]* *mpfs_git ' \
       || alr -n index --add "file://$git_index" --name mpfs_git --before community >&2 ); then
  :
else
  problem "the git index for the GitHub tag archives"
fi

# The tail of "install pac" is a check that also reports tools installed after
# it (adalang_analyzer, renode), so its status is not the result.
for what in gnatprove pac renode adalang_analyzer; do
  ./x toolchain install "$what" || problem "./x toolchain install $what"
done
echo "session-start: done" >&2
