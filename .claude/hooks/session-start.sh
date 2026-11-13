#!/bin/bash
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# SessionStart hook for Claude Code cloud sessions: makes the pinned toolchain
# of tools/toolchain.env available, so that ./x build, ./x test host,
# ./x test qemu, ./x prove and ./x pac work.
#
#   - GNAT (riscv64-elf and native), gprbuild, gnatprove, svdtools, svd2ada,
#     Renode: ./x toolchain install (idempotent; each is installed into a
#     per-version prefix and skipped when present).
#   - QEMU 10.1 or newer (QEMU_MIN): the system package of the image is older,
#     and ./x test qemu refuses to run with it. The pinned release is built
#     from source (riscv64-softmmu only) into $HOME/.local/opt and linked into
#     /usr/local/bin.
#
# Not installed: adalang_analyzer. Alire downloads each of its dependencies
# (libadalang, adasat, the gnatcoll packages, ...) as a source archive from
# its own GitHub repository, and a cloud session may read only the
# repositories that were added to it (add_repo): the download answers 403,
# whatever the list of allowed domains says. CI runs the analyzer; to run it in
# a session, add those repositories and run
# `./x toolchain install adalang_analyzer` by hand.
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
echo "session-start: toolchains" >&2
# The tail of "install pac" is a check that also reports tools this hook does
# not install (alr, adalang_analyzer, renode), so its status is not the result.
for what in gnat gnatprove pac renode; do
  ./x toolchain install "$what" || echo "session-start: ./x toolchain install $what reported problems (see above)" >&2
done
echo "session-start: done" >&2
