# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""The command line and the output of a generator: `--check`, `--output`, compare, diff, atomic write.

  add_check(parser), add_output(parser, default)   the two common arguments
  state(text, path)                                "current", "stale" or "missing"
  check_output(text, path, tool=, command=)        the --check of a generator: status 0 or 1
  write_output(text, path)                         write the file, creating its directory
  write_atomic(path, text)                         write a file so that a reader never sees half of it

A generator with --check renders the text first, then either checks it against the committed file or
writes it. The output is deterministic (no time stamp, a fixed order), so "current" means byte for byte.
"""
import argparse
import difflib
import os
import shutil
import sys
from pathlib import Path

from .errors import NOT_CURRENT, OK

CURRENT = "current"
STALE = "stale"
MISSING = "missing"
DIFF_LINES = 40


def add_check(parser: argparse.ArgumentParser, help: str = "compare with --output instead of writing it") -> None:
    """--check: do not write, say whether the committed output is current."""
    parser.add_argument("--check", action="store_true", help=help)


def add_output(parser: argparse.ArgumentParser, default: Path, help: str | None = None) -> None:
    """--output FILE: the committed output, by default <default>."""
    parser.add_argument("--output", type=Path, default=default, help=help)


def state(text: str, path: Path) -> str:
    """Whether the file <path> is <text>: CURRENT, STALE (another content) or MISSING (cannot be read)."""
    try:
        have = path.read_text(encoding="utf-8")
    except OSError:
        return MISSING
    return CURRENT if have == text else STALE


def write_atomic(path: Path, text: str) -> None:
    """Write <text> to <path> through a temporary file in the same directory, so that the file is
    either the old one or the new one. An existing file keeps its permissions."""
    tmp = path.with_name(path.name + ".tmp")
    try:
        tmp.write_text(text, encoding="utf-8")
        if path.exists():
            shutil.copymode(path, tmp)
        os.replace(tmp, path)
    except BaseException:
        tmp.unlink(missing_ok=True)
        raise


def write_output(text: str, path: Path) -> None:
    """Write <text> to <path>, making its directory if needed."""
    path.parent.mkdir(parents=True, exist_ok=True)
    write_atomic(path, text)


def check_output(text: str, path: Path, *, tool: str, command: str) -> int:
    """The --check of a generator: OK if <path> is <text>, else NOT_CURRENT, with a diff on stderr
    (at most DIFF_LINES lines; the file against what the generator makes) and `tool: ... run <command>`.
    Nothing is written."""
    found = state(text, path)
    if found == CURRENT:
        return OK
    if found == MISSING:
        print(f"{tool}: {path} is missing; run {command}", file=sys.stderr)
        return NOT_CURRENT
    have = path.read_text(encoding="utf-8")
    diff = difflib.unified_diff(have.splitlines(), text.splitlines(), str(path), "generated", lineterm="", n=1)
    print("\n".join(list(diff)[:DIFF_LINES]), file=sys.stderr)
    print(f"{tool}: {path} is not current; run {command}", file=sys.stderr)
    return NOT_CURRENT
