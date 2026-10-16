#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Requirement trace matrix.

  trace.py            write docs/assurance/trace-matrix.md
  trace.py --check    check the catalogue and the references, and that the committed
                      matrix is the one the sources produce; write nothing
  trace.py --root DIR work on another tree (the tests do)

The requirements are catalogued in docs/requirements/<area>.yaml:

  requirements:
    - id: BLD-001
      text: What shall hold.
      tsf: false          # true: part of the security-critical set (needs a test)
      source: plan section or document

and are referenced from the sources by marker comments, in any comment style (`--`, `#`,
`//`, `/*`, `;`):

  -- @req BLD-001           where the requirement is specified or implemented
  -- @verifies BLD-001      in a test that checks it (several IDs: comma separated)

`--check` fails on: a malformed or duplicate ID, an ID in a file of another area, a missing
field, a reference to an ID that is not in the catalogue, a TSF requirement without a
`@verifies`, and a committed matrix that differs from the generated one. A requirement
that is not TSF and has no `@verifies` is listed in the matrix and reported as a warning.
Exit status: 0 ok, 1 a check failed, 2 usage or an unreadable catalogue.
"""
import re
import subprocess
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
CATALOGUE = Path("docs/requirements")
MATRIX = Path("docs/assurance/trace-matrix.md")

ID = r"[A-Z][A-Z0-9]*(?:-[A-Z][A-Z0-9]*)*-[0-9]{3}"
ID_RE = re.compile(rf"^{ID}$")
# a comment leader, then @req or @verifies, then one or more IDs
REF_RE = re.compile(rf"(?:--|#|//|/\*|;)\s*@(req|verifies)\s+({ID}(?:\s*,\s*{ID})*)")
FIELDS = ("id", "text", "tsf", "source")
SKIP_DIRS = ("docs/requirements/", "docs/assurance/", "svd/", "LICENSES/",
             "libs/mpfs_pac/src/generated/", "tools/analyzer-baselines/")
# This tool and its test write the markers as examples and fixtures. Markdown documents
# the convention and verifies nothing.
SKIP_FILES = ("tools/trace.py", "tests/host/trace/run.sh")


class Problem(Exception):
    pass


def load_catalogue(root: Path):
    """Return (requirements by id, problems). Requirements keep the file order."""
    reqs, problems = {}, []
    files = sorted((root / CATALOGUE).glob("*.yaml"))
    for f in files:
        rel = f.relative_to(root)
        try:
            data = yaml.safe_load(f.read_text(encoding="utf-8"))
        except yaml.YAMLError as e:
            raise Problem(f"{rel}: not valid YAML: {e}")
        items = (data or {}).get("requirements") if isinstance(data, dict) else None
        if not isinstance(items, list):
            raise Problem(f"{rel}: the top level must be a mapping with a list `requirements`")
        area = f.stem.upper()
        for n, item in enumerate(items, 1):
            where = f"{rel}: entry {n}"
            if not isinstance(item, dict):
                problems.append(f"{where}: not a mapping")
                continue
            missing = [k for k in FIELDS if k not in item]
            extra = [k for k in item if k not in FIELDS]
            if missing:
                problems.append(f"{where} ({item.get('id', '?')}): missing field(s) {', '.join(missing)}")
            if extra:
                problems.append(f"{where} ({item.get('id', '?')}): unknown field(s) {', '.join(extra)}")
            rid = item.get("id")
            if not isinstance(rid, str) or not ID_RE.match(rid):
                problems.append(f"{where}: the id {rid!r} is not <AREA>-<NNN> (capital letters, digits, three-digit number)")
                continue
            if rid.split("-")[0] != area:
                problems.append(f"{where}: {rid} belongs in {rid.split('-')[0].lower()}.yaml, not in {f.name}")
            if rid in reqs:
                problems.append(f"{where}: {rid} is defined twice ({reqs[rid]['file']} and {rel})")
                continue
            if not isinstance(item.get("tsf"), bool):
                problems.append(f"{where} ({rid}): tsf must be true or false")
            for k in ("text", "source"):
                if k in item and not (isinstance(item[k], str) and item[k].strip()):
                    problems.append(f"{where} ({rid}): {k} is empty")
            reqs[rid] = {"id": rid, "text": str(item.get("text", "")).strip(), "tsf": item.get("tsf") is True,
                         "source": str(item.get("source", "")).strip(), "file": str(rel), "req": [], "verifies": []}
    return reqs, problems


def source_files(root: Path):
    try:
        out = subprocess.run(["git", "-C", str(root), "ls-files", "-z", "--cached", "--others", "--exclude-standard"], capture_output=True, check=True).stdout
        names = [n for n in out.decode("utf-8", "replace").split("\0") if n]
    except (OSError, subprocess.CalledProcessError):
        names = [str(p.relative_to(root)) for p in root.rglob("*") if p.is_file() and ".git" not in p.parts]
    return sorted(n for n in set(names) if not n.startswith(SKIP_DIRS) and n not in SKIP_FILES
                  and not n.endswith(".md") and (root / n).is_file())


def collect(root: Path, reqs):
    """Fill req/verifies of the requirements; return the references to unknown IDs."""
    unknown = []
    for name in source_files(root):
        try:
            text = (root / name).read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue  # binary
        for lineno, line in enumerate(text.splitlines(), 1):
            for m in REF_RE.finditer(line):
                for rid in re.split(r"\s*,\s*", m.group(2)):
                    where = f"{name}:{lineno}"
                    if rid not in reqs:
                        unknown.append(f"{where}: @{m.group(1)} {rid} is not in the catalogue")
                    elif where not in reqs[rid][m.group(1)]:
                        reqs[rid][m.group(1)].append(where)
    return unknown


def render(reqs) -> str:
    def cell(refs):
        return "<br>".join(f"`{r}`" for r in refs) if refs else "-"

    lines = [
        "<!--",
        "SPDX" "-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>",  # split: not a header of this file
        "SPDX" "-License-Identifier: CC-BY-4.0",
        "-->",
        "# Requirement trace matrix",
        "",
        "Generated by `./x trace` from `docs/requirements/*.yaml` and the `@req` and `@verifies` markers in the",
        "sources. Do not edit; `./x trace --check` fails when this file is out of date.",
        "",
    ]
    if not reqs:
        lines += ["No requirements are catalogued.", ""]
        return "\n".join(lines)
    n_tsf = sum(1 for r in reqs.values() if r["tsf"])
    n_ver = sum(1 for r in reqs.values() if r["verifies"])
    lines += [f"{len(reqs)} requirement(s), {n_tsf} in the TSF; {n_ver} with a test, "
              f"{len(reqs) - n_ver} without.", "",
              "| ID | TSF | Requirement | Source | Specified or implemented in | Verified by |",
              "|---|---|---|---|---|---|"]
    for r in sorted(reqs.values(), key=lambda r: r["id"]):
        text = r["text"].replace("|", "\\|").replace("\n", " ")
        src = r["source"].replace("|", "\\|")
        lines.append(f"| {r['id']} | {'yes' if r['tsf'] else 'no'} | {text} | {src} | "
                     f"{cell(r['req'])} | {cell(r['verifies'])} |")
    lines.append("")
    return "\n".join(lines)


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
            print("usage: trace.py [--check] [--root DIR]", file=sys.stderr)
            return 2
    try:
        reqs, problems = load_catalogue(root)
    except Problem as e:
        print(f"trace: {e}", file=sys.stderr)
        return 2
    unknown = collect(root, reqs)
    matrix = render(reqs)
    if not check:
        if problems or unknown:
            for p in problems + unknown:
                print(f"trace: {p}", file=sys.stderr)
            return 1
        out = root / MATRIX
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(matrix, encoding="utf-8")
        print(f"trace: wrote {MATRIX} ({len(reqs)} requirement(s))")
        return 0
    errors = list(problems) + unknown
    for r in reqs.values():
        if r["tsf"] and not r["verifies"]:
            errors.append(f"{r['file']}: {r['id']} is in the TSF and has no @verifies")
    for r in reqs.values():
        if not r["tsf"] and not r["verifies"]:
            print(f"trace: warning: {r['id']} has no @verifies", file=sys.stderr)
    committed = root / MATRIX
    if not committed.is_file():
        errors.append(f"{MATRIX} is missing (./x trace writes it)")
    elif committed.read_text(encoding="utf-8") != matrix:
        errors.append(f"{MATRIX} is out of date (./x trace writes it)")
    for e in errors:
        print(f"trace: FAIL: {e}", file=sys.stderr)
    if errors:
        return 1
    print(f"trace: ok: {len(reqs)} requirement(s), every reference resolves, every TSF requirement has a test")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
