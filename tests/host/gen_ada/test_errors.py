# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""tools/gen_ada/errors.py: the exit status convention and the run() wrapper."""
import contextlib
import io
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent.parent
sys.path[:0] = [str(HERE), str(ROOT / "tools")]

from gen_ada import errors  # noqa: E402
from harness import case, finish  # noqa: E402


class Violation(errors.GenError):
    status = errors.NOT_CURRENT


def call(main, *args):
    """run(main, "tool", *args): the status and what went to stderr."""
    err = io.StringIO()
    with contextlib.redirect_stderr(err):
        status = errors.run(main, "tool", *args)
    return status, err.getvalue()


@case("the statuses are 0 ok, 1 not current, 2 input error")
def _():
    assert (errors.OK, errors.NOT_CURRENT, errors.INPUT_ERROR) == (0, 1, 2)


@case("a main that returns nothing or 0 is ok, and its other statuses pass through")
def _():
    assert call(lambda: None) == (0, "")
    assert call(lambda: 0) == (0, "")
    assert call(lambda: 1) == (1, "")
    assert call(lambda: 2) == (2, "")


@case("the arguments reach main")
def _():
    assert call(lambda a, b: a + b, 0, 1) == (1, "")


@case("a GenError is `tool: message` on stderr with the status of its class")
def _():
    def fail(error):
        def main():
            raise error("the input is wrong")
        return main
    assert call(fail(errors.GenError)) == (2, "tool: the input is wrong\n")
    assert call(fail(errors.InputError)) == (2, "tool: the input is wrong\n")
    assert call(fail(errors.NotCurrent)) == (1, "tool: the input is wrong\n")
    assert call(fail(Violation)) == (1, "tool: the input is wrong\n")


@case("another exception is a defect: it is not caught")
def _():
    def main():
        raise KeyError("x")
    try:
        call(main)
    except KeyError:
        return
    raise AssertionError("a KeyError was swallowed")


@case("the subclasses are GenErrors")
def _():
    assert issubclass(errors.NotCurrent, errors.GenError) and issubclass(errors.InputError, errors.GenError)


finish()
