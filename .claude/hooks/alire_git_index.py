#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Write an Alire index that fetches GitHub tag archives as git checkouts instead.

    alire_git_index.py OUT_DIR CRATE[=VERSION]...

The proxy of a cloud session refuses the archive downloads of github.com
(`/archive/refs/tags/<tag>.zip`, codeload.github.com and the API answer 403),
while `git clone` of a public repository works. Alire fetches most AdaCore
crates (xmlada, gnatcoll, libgpr, langkit, ...) from such archives.

For every CRATE[=VERSION] this asks `alr show --solve` for the solution, reads
the manifests of the solved releases from the community index, and writes a
copy of each manifest whose origin is a GitHub tag archive into OUT_DIR, with
the origin replaced by `git+https://github.com/<owner>/<repo>.git` and the
commit the tag points to (`git ls-remote`). The archive of a tag holds the same
tree as the commit, so the release is the same. Alire accepts a git origin
only for source releases; for a release marked `binary = true` (gprconfig_kb)
this clones the tag, packs it with `git archive` into OUT_DIR/archives and
names that file as the origin, with its own SHA-512.

Registered in front of the community index (`alr index --add file://OUT_DIR
--before community`), the copies shadow the releases of the community index;
every other release still comes from there. Run it again after a change of the
pins: it rewrites OUT_DIR from scratch.

Exit status: 0 done, 1 a step failed (no alr, no solution, a tag not found).
"""
from __future__ import annotations

import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ARCHIVE = re.compile(r'^\s*url\s*=\s*["\']https://github\.com/([^/]+)/([^/]+)/archive/refs/tags/(.+)\.(?:zip|tar\.gz)["\']\s*$')
KEY = re.compile(r"^\s*(url|hashes)\s*=")
BINARY = re.compile(r"^\s*binary\s*=\s*true\s*$")
SOLVED = re.compile(r"^\s+([a-z0-9_]+)=(\S+)")


def community_index() -> Path:
    out = subprocess.run(["alr", "index", "--list"], check=True, capture_output=True, text=True).stdout
    for line in out.splitlines():
        cols = line.split()
        if len(cols) >= 4 and cols[1] == "community":
            return Path(cols[3]) / "index"
    sys.exit("alire_git_index: no index named community in `alr index --list`")


def solution(spec: str) -> list[tuple[str, str]]:
    """The crate itself and the releases of its solution, as (name, version)."""
    out = subprocess.run(["alr", "-n", "show", "--solve", spec], check=False,
                         capture_output=True, text=True)
    text = out.stdout + out.stderr
    rels: list[tuple[str, str]] = []
    head = re.search(r"^([a-z0-9_]+)=(\S+):", text, re.MULTILINE)
    if head:
        rels.append((head.group(1), head.group(2)))
    in_solution = False
    for line in text.splitlines():
        if line.startswith("Dependencies (solution)"):
            in_solution = True
            continue
        if in_solution:
            m = SOLVED.match(line)
            if not m:
                break
            rels.append((m.group(1), m.group(2)))
    if not rels:
        sys.exit(f"alire_git_index: no solution for {spec}:\n{text}")
    return rels


def tag_commit(owner: str, repo: str, tag: str) -> str:
    url = f"https://github.com/{owner}/{repo}.git"
    out = subprocess.run(["git", "ls-remote", url, f"refs/tags/{tag}", f"refs/tags/{tag}^{{}}"],
                         check=True, capture_output=True, text=True).stdout
    refs: dict[str, str] = {}
    for line in out.splitlines():
        sha, _, ref = line.partition("\t")
        refs[ref] = sha
    commit = refs.get(f"refs/tags/{tag}^{{}}") or refs.get(f"refs/tags/{tag}")
    if not commit:
        sys.exit(f"alire_git_index: tag {tag} not found in {url}")
    return commit


def local_archive(out: Path, owner: str, repo: str, tag: str) -> tuple[Path, str]:
    """Pack the tree of the tag into OUT_DIR/archives; the file and its SHA-512."""
    archive = out / "archives" / f"{repo}-{tag}.tar.gz"
    archive.parent.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory() as work:
        subprocess.run(["git", "clone", "-q", "--depth", "1", "--branch", tag,
                        f"https://github.com/{owner}/{repo}.git", work], check=True)
        subprocess.run(["git", "-C", work, "archive", "--format=tar.gz", f"--prefix={repo}-{tag}/",
                        "-o", str(archive), "HEAD"], check=True)
    return archive, hashlib.sha512(archive.read_bytes()).hexdigest()


def rewrite(manifest: str, out: Path) -> str | None:
    """The manifest with a git origin, or None if its origin is no GitHub tag archive."""
    lines = manifest.splitlines()
    try:
        start = next(i for i, line in enumerate(lines) if line.strip() == "[origin]")
    except StopIteration:
        return None
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("[")), len(lines))
    url = next((ARCHIVE.match(line) for line in lines[start + 1:end] if ARCHIVE.match(line)), None)
    if url is None:
        return None
    owner, repo, tag = url.groups()
    # the other keys of the origin stay; `hashes` belong to the archive of GitHub
    kept = [line for line in lines[start + 1:end] if line.strip() and not KEY.match(line)]
    if any(BINARY.match(line) for line in kept):
        archive, sha512 = local_archive(out, owner, repo, tag)
        source = [f'url = "file://{archive}"', f'hashes = ["sha512:{sha512}"]']
    else:
        source = [f'url = "git+https://github.com/{owner}/{repo}.git"',
                  f'commit = "{tag_commit(owner, repo, tag)}"']
    origin = ["[origin]", *source, *kept, ""]
    return "\n".join(lines[:start] + origin + lines[end:]).rstrip("\n") + "\n"


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        sys.exit(__doc__.split("\n\n")[1])
    out = Path(argv[0])
    community = community_index()
    releases = sorted({rel for spec in argv[1:] for rel in solution(spec)})
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    (out / "index.toml").write_text((community / "index.toml").read_text())
    for name, version in releases:
        rel = Path(name[:2]) / name / f"{name}-{version}.toml"
        src = community / rel
        if not src.is_file():          # external or system release (make, gnat): nothing to fetch
            continue
        text = rewrite(src.read_text(), out.resolve())
        if text is None:
            continue
        (out / rel).parent.mkdir(parents=True, exist_ok=True)
        (out / rel).write_text(text)
        print(f"alire_git_index: {name}={version} from git", file=sys.stderr)
    return 0


if __name__ == "__main__":
    os.environ.setdefault("GIT_TERMINAL_PROMPT", "0")
    sys.exit(main(sys.argv[1:]))
