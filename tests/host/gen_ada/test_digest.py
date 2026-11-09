# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""tools/gen_ada/digest.py: the hash of a file and of a tree."""
import hashlib
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent.parent
sys.path[:0] = [str(HERE), str(ROOT / "tools")]

from gen_ada import digest, errors  # noqa: E402
from harness import case, finish, raises  # noqa: E402


class Mine(errors.GenError):
    pass


@case("file_digest is the SHA-256 of the bytes")
def _():
    with tempfile.TemporaryDirectory() as t:
        f = Path(t) / "f"
        f.write_bytes(b"abc\n\x00\xff")
        assert digest.file_digest(f) == hashlib.sha256(b"abc\n\x00\xff").hexdigest()
        f.write_bytes(b"")
        assert digest.file_digest(f) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"


@case("tree_digest: name, NUL, content, NUL per file in name order (the format of MPFS_Registers.sha256)")
def _():
    with tempfile.TemporaryDirectory() as t:
        d = Path(t)
        (d / "b.ads").write_bytes(b"two")
        (d / "a.ads").write_bytes(b"one")
        (d / "ignored.txt").write_bytes(b"x")
        want = hashlib.sha256(b"a.ads\0one\0b.ads\0two\0").hexdigest()
        assert digest.tree_digest(d) == want


@case("tree_digest: names and contents count, the order of creation does not")
def _():
    with tempfile.TemporaryDirectory() as t1, tempfile.TemporaryDirectory() as t2:
        a, b = Path(t1), Path(t2)
        (a / "x.ads").write_text("1")
        (a / "y.ads").write_text("2")
        (b / "y.ads").write_text("2")
        (b / "x.ads").write_text("1")
        assert digest.tree_digest(a) == digest.tree_digest(b)
        (b / "x.ads").write_text("3")
        assert digest.tree_digest(a) != digest.tree_digest(b)
        (b / "x.ads").write_text("1")
        (b / "x.ads").rename(b / "z.ads")
        assert digest.tree_digest(a) != digest.tree_digest(b)


@case("tree_digest: another pattern")
def _():
    with tempfile.TemporaryDirectory() as t:
        d = Path(t)
        (d / "a.txt").write_bytes(b"1")
        assert digest.tree_digest(d, "*.txt") == hashlib.sha256(b"a.txt\x001\x00").hexdigest()


@case("tree_digest: no matching file raises the error class of the caller, by default a GenError")
def _():
    with tempfile.TemporaryDirectory() as t:
        d = Path(t)
        (d / "a.txt").write_text("1")
        raises(errors.GenError, lambda: digest.tree_digest(d), f"no *.ads file in {d}")
        raises(Mine, lambda: digest.tree_digest(d, error=Mine), "no *.ads file")


finish()
