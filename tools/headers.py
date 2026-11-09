#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Check or fix SPDX headers and provenance notes.

  headers.py check   fail on missing SPDX header, missing PROVENANCE.md entry, or an SPDX tag that is
                     not in the header of a file of tools/, crates/ or tests/ (for example a tag inside
                     a string of a generator: reuse reads it as a tag of the generator; write the header
                     of a generated file with tools/gen_ada/spdx.py)
  headers.py fix     add the default header where missing (Apache-2.0 for code,
                     CC-BY-4.0 for Markdown/SVD/XML)
"""
import fnmatch
import re
import subprocess
import sys
import tomllib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gen_ada import spdx  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
COPYRIGHT = "2026 Manuel Stahl <thymythos@googlemail.com>"
LICENSE_ID = "Apache-2.0"
DOC_LICENSE_ID = "CC-BY-4.0"  # documentation and data files
SKIP = {"LICENSE"}
SKIP_PREFIX = ("LICENSES/",)
BINARY = {".png", ".jpg", ".pdf", ".bin", ".elf", ".o", ".a", ".gz", ".zip"}

# (line prefix, block open, block close) per extension
LINE = {".ads": "--  ", ".adb": "--  ", ".ada": "--  ", ".gpr": "--  ",
        ".py": "# ", ".sh": "# ", ".yml": "# ", ".yaml": "# ", ".toml": "# ",
        ".env": "# ", ".cfg": "# ", ".repl": "# ", ".resc": "# ", ".robot": "# "}
BLOCK = {".md": ("<!--", "-->"), ".svd": ("<!--", "-->"), ".xml": ("<!--", "-->"),
         ".S": ("/*", " */"), ".c": ("/*", " */"), ".h": ("/*", " */"), ".ld": ("/*", " */")}
# Files of these directories (not the upstream fork) may carry the tags only in their header: the first
# HEADER_LINES lines, at the start of a comment line.
LINT_PREFIX = ("tools/", "crates/", "tests/")
LINT_SKIP_PREFIX = ("crates/bb-runtimes/",)
HEADER_LINES = 30
TAG_RE = re.compile(re.escape(spdx.COPYRIGHT_TAG) + "|" + re.escape(spdx.LICENSE_TAG))
HEADER_TAG_RE = re.compile(r"^\s*(?:#|--|//|/\*|\*|;|<!--)?\s*(?:" + TAG_RE.pattern + ")")
NAMES = {".gitignore": "# ", ".editorconfig": "# ", "CODEOWNERS": "# ",
         "x": "# ", "export.sh": "# "}


def files():
    out = subprocess.run(["git", "ls-files", "-co", "--exclude-standard"], cwd=ROOT,
                         capture_output=True, text=True, check=True).stdout.split("\n")
    return [f for f in out if f and (ROOT / f).is_file()]


def glob_re(pat):
    rx, i = "", 0
    while i < len(pat):
        if pat.startswith("**/", i):
            rx += "(?:.*/)?"; i += 3
        elif pat.startswith("**", i):
            rx += ".*"; i += 2
        elif pat[i] == "*":
            rx += "[^/]*"; i += 1
        else:
            rx += re.escape(pat[i]); i += 1
    return re.compile(rx + r"\Z")


def reuse_covered():
    path = ROOT / "REUSE.toml"
    pats = []
    if path.exists():
        for a in tomllib.loads(path.read_text()).get("annotations", []):
            p = a["path"]
            pats += [glob_re(x) for x in ([p] if isinstance(p, str) else p)]
    return pats


def has_header(text):
    head = "\n".join(text.split("\n")[:30])
    return spdx.COPYRIGHT_TAG in head and spdx.LICENSE_TAG in head


def stray_tags(name, text):
    """The lines of <text> that have a tag outside the header: (line number, line) for a file of the
    directories in LINT_PREFIX. The header is the first run of consecutive tag lines, within the first
    HEADER_LINES lines, each at the start of a comment line. A tag anywhere else (in a string, in a
    comment below the header, in a second run) is read by reuse as a tag of the file itself."""
    if not name.startswith(LINT_PREFIX) or name.startswith(LINT_SKIP_PREFIX):
        return []
    found, started, ended = [], False, False
    for n, line in enumerate(text.split("\n"), 1):
        if not TAG_RE.search(line):
            ended = ended or started
            continue
        if n > HEADER_LINES or ended or not HEADER_TAG_RE.match(line):
            found.append((n, line))
        else:
            started = True
    return found


def header_for(name, purpose="TODO: purpose"):
    p = Path(name)
    lic = DOC_LICENSE_ID if p.suffix in (".md", ".svd", ".xml") else LICENSE_ID
    lines = spdx.lines(lic, COPYRIGHT)
    if p.name in NAMES:
        return "".join(NAMES[p.name] + l + "\n" for l in lines)
    if p.suffix in LINE:
        pre = LINE[p.suffix]
        return "".join(pre + l + "\n" for l in lines) + pre.rstrip() + "\n" + pre + purpose + "\n"
    if p.suffix in BLOCK:
        o, c = BLOCK[p.suffix]
        return o + "\n" + "\n".join(lines) + "\n" + c + "\n"
    return None


def main(mode):
    covered = reuse_covered()
    prov = (ROOT / "PROVENANCE.md").read_text() if (ROOT / "PROVENANCE.md").exists() else ""
    bad = 0
    for f in files():
        p = ROOT / f
        if f in SKIP or f.startswith(SKIP_PREFIX) or p.suffix in BINARY:
            continue
        if any(r.match(f) for r in covered):
            continue
        text = p.read_text(errors="replace")
        for n, line in stray_tags(f, text):
            print(f"SPDX tag outside the header: {f}:{n}: {line.strip()[:80]}")
            bad += 1
        if not has_header(text):
            hdr = header_for(f)
            if mode == "fix" and hdr:
                if text.startswith("#!"):
                    first, _, rest = text.partition("\n")
                    text = first + "\n" + hdr + rest
                else:
                    text = hdr + text
                p.write_text(text)
                print(f"fixed:   {f}")
            else:
                print(f"missing SPDX header: {f}")
                bad += 1
            continue
        head = "\n".join(text.split("\n")[:30])
        if re.search(r"^\W*Derived from \S+/\S+ ", head, re.M) and f not in prov and str(Path(f).parent) + "/" not in prov:
            print(f"no PROVENANCE.md entry: {f}")
            bad += 1
    return 1 if bad else 0


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in ("check", "fix"):
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1]))
