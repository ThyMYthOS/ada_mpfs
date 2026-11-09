# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""tools/gen_ada/cli.py: the common arguments, the comparison with the committed file, the diff and the
atomic write."""
import argparse
import contextlib
import io
import os
import stat
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent.parent
sys.path[:0] = [str(HERE), str(ROOT / "tools")]

from gen_ada import cli  # noqa: E402
from harness import case, finish  # noqa: E402


def check(text, path):
    err = io.StringIO()
    with contextlib.redirect_stderr(err):
        status = cli.check_output(text, path, tool="gen_x", command="tools/gen_x.py")
    return status, err.getvalue()


@case("add_check and add_output: --check is a flag, --output a path with the given default")
def _():
    parser = argparse.ArgumentParser()
    cli.add_check(parser)
    cli.add_output(parser, Path("default.ads"))
    args = parser.parse_args([])
    assert args.check is False and args.output == Path("default.ads")
    args = parser.parse_args(["--check", "--output", "x/y.ads"])
    assert args.check is True and args.output == Path("x/y.ads")
    helptext = parser.format_help()
    assert "compare with --output instead of writing it" in helptext


@case("state: current, stale and missing (also a directory)")
def _():
    with tempfile.TemporaryDirectory() as t:
        f = Path(t) / "f.txt"
        assert cli.state("a\n", f) == cli.MISSING
        f.write_text("a\n")
        assert cli.state("a\n", f) == cli.CURRENT
        assert cli.state("b\n", f) == cli.STALE
        assert cli.state("a", f) == cli.STALE
        assert cli.state("a\n", Path(t)) == cli.MISSING


@case("check_output: a current file is 0 and silent")
def _():
    with tempfile.TemporaryDirectory() as t:
        f = Path(t) / "f.txt"
        f.write_text("one\ntwo\n")
        assert check("one\ntwo\n", f) == (0, "")


@case("check_output: a missing file is 1 and says what to run")
def _():
    with tempfile.TemporaryDirectory() as t:
        f = Path(t) / "f.txt"
        assert check("x\n", f) == (1, f"gen_x: {f} is missing; run tools/gen_x.py\n")


@case("check_output: another content is 1, with the diff of the file against the generated text")
def _():
    with tempfile.TemporaryDirectory() as t:
        f = Path(t) / "f.txt"
        f.write_text("one\ntwo\nthree\n")
        status, err = check("one\n2\nthree\n", f)
        assert status == 1
        lines = err.splitlines()
        assert lines[0] == f"--- {f}" and lines[1] == "+++ generated", lines[:2]
        assert "-two" in lines and "+2" in lines
        assert lines[-1] == f"gen_x: {f} is not current; run tools/gen_x.py"
        assert f.read_text() == "one\ntwo\nthree\n", "--check wrote the file"


@case("check_output: the diff is cut after 40 lines")
def _():
    with tempfile.TemporaryDirectory() as t:
        f = Path(t) / "f.txt"
        f.write_text("".join(f"old {n}\n" for n in range(100)))
        status, err = check("".join(f"new {n}\n" for n in range(100)), f)
        assert status == 1
        assert len(err.splitlines()) == 40 + 1, len(err.splitlines())


@case("write_atomic: writes the text, leaves no temporary file and replaces an existing file")
def _():
    with tempfile.TemporaryDirectory() as t:
        f = Path(t) / "f.txt"
        cli.write_atomic(f, "first\n")
        cli.write_atomic(f, "second\näö\n")
        assert f.read_text(encoding="utf-8") == "second\näö\n"
        assert sorted(p.name for p in Path(t).iterdir()) == ["f.txt"]


@case("write_atomic: an existing file keeps its permissions, a new one has the permissions of a written file")
def _():
    with tempfile.TemporaryDirectory() as t:
        f = Path(t) / "run.sh"
        f.write_text("#!/bin/sh\n")
        f.chmod(0o755)
        cli.write_atomic(f, "#!/bin/sh\necho\n")
        assert stat.S_IMODE(f.stat().st_mode) == 0o755
        plain = Path(t) / "plain.txt"
        cli.write_atomic(plain, "x")
        umask = os.umask(0)
        os.umask(umask)
        assert stat.S_IMODE(plain.stat().st_mode) == 0o666 & ~umask


@case("write_atomic: a failed write leaves the old file and no temporary file")
def _():
    with tempfile.TemporaryDirectory() as t:
        f = Path(t) / "f.txt"
        f.write_text("old\n")
        try:
            cli.write_atomic(f, "new\udc80")       # a lone surrogate cannot be encoded as UTF-8
        except UnicodeEncodeError:
            pass
        else:
            raise AssertionError("no error")
        assert f.read_text() == "old\n"
        assert sorted(p.name for p in Path(t).iterdir()) == ["f.txt"]


@case("write_output: makes the directory")
def _():
    with tempfile.TemporaryDirectory() as t:
        f = Path(t) / "a" / "b" / "f.txt"
        cli.write_output("x\n", f)
        assert f.read_text() == "x\n"


finish()
