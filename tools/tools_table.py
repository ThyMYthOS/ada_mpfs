#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Pinned-version table of docs/assurance/tools.md.

  tools_table.py            rewrite the table between the markers of docs/assurance/tools.md
  tools_table.py --check    fail if the committed table differs from the one generated, or if a
                            tool of the table has no row in the descriptive table; write nothing
  tools_table.py --root DIR work on another tree (the tests do)

The versions come from tools/toolchain.env (plain NAME=VALUE lines) and tools/requirements.txt
(`package==version`); nothing is copied by hand. The text of docs/assurance/tools.md outside the
two marker comments

  <!-- tools-table:begin -->
  <!-- tools-table:end -->

is not touched. Every tool of the generated table must also have a row of its own (first cell =
the tool name) in the rest of the file, so that a tool added to the pins cannot go undocumented.
A pin that is missing or empty is an error, not an empty cell.
Exit status: 0 ok, 1 the check failed, 2 usage or an unreadable input.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ENV = Path("tools/toolchain.env")
REQ = Path("tools/requirements.txt")
DOC = Path("docs/assurance/tools.md")
BEGIN = "<!-- tools-table:begin -->"
END = "<!-- tools-table:end -->"

# (tool name, kind, variable, prefix of the SHA-256 variables or None, kind of tool). kind:
# "exact" = a version that must match, "min" = a minimum version, "commit" = a git commit.
TOOLS = (
    ("alr", "exact", "ALR_VERSION", "ALR_SHA256_", "Alire release binary, used when alr is not on PATH"),
    ("gnat_riscv64_elf", "exact", "GNAT_RISCV64_VERSION", None, "Alire crate version"),
    ("gnat_native", "exact", "GNAT_NATIVE_VERSION", None, "Alire crate version"),
    ("gprbuild", "exact", "GPRBUILD_VERSION", None, "Alire crate version"),
    ("gnatprove", "exact", "GNATPROVE_VERSION", None, "Alire crate version"),
    ("adalang_analyzer", "exact", "ADALANG_ANALYZER_VERSION", None, "Alire crate version"),
    ("svd2ada", "commit", "SVD2ADA_COMMIT", None, "built from source"),
    ("svdtools", "exact", "SVDTOOLS_VERSION", "SVDTOOLS_SHA256_", "release binary, or cargo"),
    ("rustc", "min", "SVDTOOLS_RUSTC_MIN", None, "only for a source build of svdtools"),
    ("Renode", "exact", "RENODE_VERSION", "RENODE_SHA256_", "release asset"),
    ("QEMU", "min", "QEMU_MIN", None, "from the operating system"),
    ("Python", "min", "PYTHON_MIN", None, "from the operating system"),
)


class Problem(Exception):
    pass


def read_env(root: Path, path: Path) -> dict:
    try:
        text = (root / path).read_text(encoding="utf-8")
    except OSError as e:
        raise Problem(f"cannot read {path}: {e.strerror}")
    env = {}
    for n, line in enumerate(text.splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = re.fullmatch(r"([A-Z][A-Z0-9_]*)=(\S*)", line)
        if not m:
            raise Problem(f"{path}:{n}: not a NAME=VALUE line: {line!r}")
        env[m.group(1)] = m.group(2)
    return env


def read_requirements(root: Path, path: Path) -> list:
    try:
        text = (root / path).read_text(encoding="utf-8")
    except OSError as e:
        raise Problem(f"cannot read {path}: {e.strerror}")
    pkgs = []
    for n, line in enumerate(text.splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = re.fullmatch(r"([A-Za-z0-9_.-]+)==([A-Za-z0-9_.+-]+)", line)
        if not m:
            raise Problem(f"{path}:{n}: not a pinned requirement (name==version): {line!r}")
        pkgs.append((m.group(1), m.group(2)))
    return pkgs


def platform(var: str, prefix: str) -> str:
    return var[len(prefix):].lower().replace("_", "-")


def render(env: dict, pkgs: list) -> str:
    rows = []
    for name, kind, var, sha_prefix, note in TOOLS:
        value = env.get(var, "")
        if not value:
            raise Problem(f"{ENV}: {var} is missing or empty (needed for {name})")
        version = {"exact": f"`{value}`", "min": f">= {value}", "commit": f"commit `{value}`"}[kind]
        shas = []
        if sha_prefix:
            for k in sorted(env):
                if k.startswith(sha_prefix) and env[k]:
                    shas.append(f"{platform(k, sha_prefix)}: `{env[k][:12]}`")
            if not shas:
                raise Problem(f"{ENV}: no {sha_prefix}* checksum for {name}")
        rows.append((name, version, f"`{var}`", "<br>".join(shas) or "none", note))
    for pkg, ver in pkgs:
        rows.append((pkg, f"`{ver}`", f"`{REQ}`", "none", "Python package"))
    lines = ["| Tool | Pinned version | Pinned in | SHA-256 of the download (first 12 digits) | Kind |",
             "|---|---|---|---|---|"]
    lines += [f"| {' | '.join(r)} |" for r in rows]
    return "\n".join(lines)


def split(text: str):
    """(before, block, after) around the marker comments; Problem if they are not there once."""
    if text.count(BEGIN) != 1 or text.count(END) != 1:
        raise Problem(f"{DOC} needs exactly one {BEGIN} and one {END}")
    b, e = text.index(BEGIN), text.index(END)
    if e < b:
        raise Problem(f"{DOC}: the end marker comes before the begin marker")
    return text[:b + len(BEGIN)], text[b + len(BEGIN):e], text[e:]


def main(argv) -> int:
    root, check = ROOT, False
    args = list(argv)
    while args:
        a = args.pop(0)
        if a == "--check":
            check = True
        elif a == "--root" and args:
            root = Path(args.pop(0)).resolve()
        else:
            print("usage: tools_table.py [--check] [--root DIR]", file=sys.stderr)
            return 2
    try:
        table = render(read_env(root, ENV), read_requirements(root, REQ))
        try:
            text = (root / DOC).read_text(encoding="utf-8")
        except OSError as e:
            raise Problem(f"cannot read {DOC}: {e.strerror}")
        before, block, after = split(text)
    except Problem as e:
        print(f"tools-doc: {e}", file=sys.stderr)
        return 2
    new = f"{before}\n{table}\n{after}"
    if not check:
        (root / DOC).write_text(new, encoding="utf-8")
        print(f"tools-doc: wrote the table of {DOC}")
        return 0
    errors = []
    if block.strip() != table:
        errors.append(f"the table of {DOC} is out of date (./x tools-doc writes it)")
    rest = before + after
    for name in [t[0] for t in TOOLS] + [p for p, _ in read_requirements(root, REQ)]:
        if not re.search(rf"^\| {re.escape(name)} \|", rest, re.M):
            errors.append(f"{DOC} has no row for {name} outside the generated table")
    for e in errors:
        print(f"tools-doc: FAIL: {e}", file=sys.stderr)
    if errors:
        return 1
    print(f"tools-doc: ok: the table of {DOC} is current")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
