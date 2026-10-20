#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Check the relative links and the #anchors of the Markdown files. Driven by `./x docs`.

usage: tools/check_docs.py [ROOT]

Every `[text](target)`, `![alt](target)`, `[text][ref]` with its `[ref]: target`
definition, and every `href=`/`src=` of an HTML tag in a Markdown file below ROOT
(default: the repository) is checked:

  - a relative target must exist (a file or a directory); a target that starts
    with `/` is relative to ROOT;
  - a `#anchor` on a Markdown file (or alone: the file itself) must be the slug
    of a heading of that file, written as GitHub does (`Foo, bar` is `foo-bar`, a
    second `Foo` is `foo-1`), or the `id` / `name` of an HTML tag;
  - a link with a scheme (`https:`, `mailto:`, ...) is not checked: no network.

Not looked at: fenced code blocks, inline code, HTML comments, and the directories
`svd/` and `LICENSES/` of ROOT, every `generated/` directory (the generated PAC),
`.git/` and build output (`build/`, `obj-*`, `bin-*`).

A broken link is printed as `file:line: link (reason)`. Fail-closed rules: a ROOT
that holds no Markdown file is an error (a typo in the path must not pass), and so
is a reference with no definition.

Exit status: 0 all links resolve; 1 a broken link; 2 usage or no Markdown file.
"""

import os
import re
import sys
import urllib.parse

SKIP_TOP = {"svd", "LICENSES"}
SKIP_ANY = {".git", "generated", "build", "node_modules", "__pycache__", ".venv", "alire"}
SKIP_PREFIX = ("obj-", "bin-")

SCHEME = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")
FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})")


def blank(text):
    """The text with everything but the newlines replaced by spaces."""
    return re.sub(r"[^\n]", " ", text)


def strip_code(text, inline=True):
    """Blank out fenced code blocks, HTML comments and (if `inline`) inline code, keeping the line numbers."""
    out = []
    fence = None
    for line in text.split("\n"):
        m = FENCE.match(line)
        if fence is None:
            if m:
                fence = m.group(1)
                out.append(blank(line))
            else:
                out.append(line)
        else:
            if m and m.group(1)[0] == fence[0] and len(m.group(1)) >= len(fence) \
                    and line.strip() == m.group(1):
                fence = None
            out.append(blank(line))
    text = "\n".join(out)
    text = re.sub(r"<!--.*?-->", lambda m: blank(m.group(0)), text, flags=re.DOTALL)
    if not inline:
        return text
    # An inline code span is closed by the same number of backticks, within a paragraph.
    span = re.compile(r"(?<!`)(`+)(?!`)((?:(?!\n[ \t]*\n).)+?)(?<!`)\1(?!`)", re.DOTALL)
    return span.sub(lambda m: blank(m.group(0)), text)


def slug_of(heading, seen):
    """The GitHub anchor of a heading text; `seen` counts the slugs of the file."""
    t = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", heading)       # links: their text
    t = re.sub(r"!?\[([^\]]*)\]\[[^\]]*\]", r"\1", t)
    t = re.sub(r"<[^>]*>", "", t)                                 # HTML tags
    t = t.replace("`", "").replace("*", "")
    t = re.sub(r"(?<!\w)_+|_+(?!\w)", "", t)                      # emphasis, not snake_case
    t = t.strip().lower()
    t = re.sub(r"[^\w\- ]", "", t)                                # punctuation
    t = t.replace(" ", "-")
    n = seen.get(t, 0)
    seen[t] = n + 1
    return t if n == 0 else "%s-%d" % (t, n)


def anchors_of(text):
    """The set of anchors a Markdown text offers."""
    code_free = strip_code(text, inline=False)   # a heading may hold code
    lines = code_free.split("\n")
    found = set()
    seen = {}
    for i, line in enumerate(lines):
        m = re.match(r"^ {0,3}#{1,6}[ \t]+(.*?)(?:[ \t]+#+)?[ \t]*$", line)
        if m:
            found.add(slug_of(m.group(1), seen))
        elif i + 1 < len(lines) and line.strip() and not line.startswith((" " * 4, "\t")) \
                and re.match(r"^ {0,3}(=+|-+)[ \t]*$", lines[i + 1]) \
                and not re.match(r"^\s*([-*+]|\d+[.)])\s", line):
            found.add(slug_of(line.strip(), seen))
    for m in re.finditer(r"""<[A-Za-z][^>]*\b(?:id|name)\s*=\s*["']([^"']+)["']""", code_free):
        found.add(m.group(1).lower())
    return found


def destination(text, pos):
    """Parse a link destination from text[pos:] (just after the `(`).

    Returns (target, end) or None if it does not end in `)`.
    """
    n = len(text)
    i = pos
    while i < n and text[i] in " \t\n":
        i += 1
    if i < n and text[i] == "<":
        j = text.find(">", i)
        if j < 0 or "\n" in text[i:j]:
            return None
        target = text[i + 1:j]
        i = j + 1
    else:
        depth = 0
        j = i
        while j < n:
            c = text[j]
            if c == "\\" and j + 1 < n:
                j += 2
                continue
            if c in " \t\n":
                break
            if c == "(":
                depth += 1
            elif c == ")":
                if depth == 0:
                    break
                depth -= 1
            j += 1
        target = text[i:j]
        i = j
    # an optional title, then the closing parenthesis
    m = re.compile(r"""[ \t\n]*(?:"[^"]*"|'[^']*'|\([^)]*\))?[ \t\n]*\)""").match(text, i)
    if not m:
        return None
    return target, m.end()


def links_of(text):
    """Yield (offset, target) for every link of a code-free text; reference uses as ('ref', id)."""
    for m in re.finditer(r"\]\(", text):
        # a link text opens in the same paragraph
        start = text.rfind("\n\n", 0, m.start())
        if "[" not in text[start + 1:m.start()]:
            continue
        d = destination(text, m.end())
        if d is None:
            continue
        yield m.start(), d[0]
    for m in re.finditer(r"""<[A-Za-z][^>]*?\b(?:href|src)\s*=\s*(?:"([^"]*)"|'([^']*)')""", text):
        yield m.start(), m.group(1) if m.group(1) is not None else m.group(2)
    defs = {}
    for m in re.finditer(r"^ {0,3}\[([^\]\n]+)\]:[ \t]*(<[^>\n]*>|\S+)", text, re.MULTILINE):
        defs[m.group(1).strip().lower()] = m.group(2).strip("<>")
        yield m.start(), m.group(2).strip("<>")
    for m in re.finditer(r"\]\[([^\]\n]*)\]", text):
        ref = m.group(1).strip().lower()
        if ref == "":
            before = text[:m.start()]
            k = before.rfind("[")
            ref = before[k + 1:].strip().lower() if k >= 0 else ""
        if ref not in defs:
            yield m.start(), ("ref", ref)


def markdown_files(root):
    found = []
    for dirpath, dirnames, filenames in os.walk(root):
        rel = os.path.relpath(dirpath, root)
        keep = []
        for d in sorted(dirnames):
            if d in SKIP_ANY or d.startswith(SKIP_PREFIX):
                continue
            if rel == "." and d in SKIP_TOP:
                continue
            keep.append(d)
        dirnames[:] = keep
        for f in sorted(filenames):
            if f.lower().endswith(".md"):
                found.append(os.path.join(dirpath, f))
    return found


def check(root):
    """Check the tree; return (files, links, problems), problems as (file, line, link, reason)."""
    files = markdown_files(root)
    cache = {}
    problems = []
    nlinks = 0

    def anchors(path):
        if path not in cache:
            with open(path, encoding="utf-8", errors="replace") as fh:
                cache[path] = anchors_of(fh.read())
        return cache[path]

    for path in files:
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = strip_code(fh.read())
        rel = os.path.relpath(path, root)
        for off, target in links_of(text):
            line = text.count("\n", 0, off) + 1
            nlinks += 1
            if isinstance(target, tuple):
                problems.append((rel, line, "[%s]" % target[1], "reference without a definition"))
                continue
            if not target or SCHEME.match(target) or target.startswith("//"):
                continue
            base, _, frag = target.partition("#")
            base = urllib.parse.unquote(base.partition("?")[0])
            frag = urllib.parse.unquote(frag)
            if base == "":
                dest = path
            elif base.startswith("/"):
                dest = os.path.join(root, base.lstrip("/"))
            else:
                dest = os.path.join(os.path.dirname(path), base)
            dest = os.path.normpath(dest)
            if not os.path.exists(dest):
                problems.append((rel, line, target, "no such file"))
                continue
            if frag and os.path.isfile(dest) and dest.lower().endswith(".md") \
                    and frag.lower() not in anchors(dest):
                problems.append((rel, line, target, "no such anchor"))
    return files, nlinks, problems


def main(argv):
    if len(argv) > 2 or (len(argv) == 2 and argv[1] in ("-h", "--help")):
        print(__doc__.split("\n\n")[0], file=sys.stderr)
        return 2
    root = os.path.abspath(argv[1] if len(argv) == 2 else
                           os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    if not os.path.isdir(root):
        print("check_docs: %s is not a directory" % root, file=sys.stderr)
        return 2
    files, nlinks, problems = check(root)
    if not files:
        print("check_docs: no Markdown file below %s" % root, file=sys.stderr)
        return 2
    for rel, line, link, reason in problems:
        print("%s:%d: %s (%s)" % (rel, line, link, reason), file=sys.stderr)
    if problems:
        print("check_docs: %d broken link(s) in %d file(s)" % (len(problems), len(files)),
              file=sys.stderr)
        return 1
    print("check_docs: %d link(s) in %d file(s) resolve" % (nlinks, len(files)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
