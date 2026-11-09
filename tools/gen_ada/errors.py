# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Errors of a generator and the exit status convention.

  0  ok (with --check: the output is current)
  1  not current (--check), or a rule of the tool is violated (svd.py, pac_gen.py: the check failed)
  2  an input is missing or wrong, or the tool is used wrongly

A generator raises a subclass of GenError wherever the message is for the user, and its entry point
is `sys.exit(errors.run(main, "tool", ...))`: run() prints `tool: message` on stderr and returns
the status of the error. Every other exception is a defect of the tool and keeps its traceback.
"""
import sys
from typing import Callable

OK = 0
NOT_CURRENT = 1
INPUT_ERROR = 2


class GenError(Exception):
    """A problem to report to the user; `status` is the exit status of the tool.

    The default is an input error. A tool whose violations of its own rules have always been reported
    with status 1 (svd.py, pac_gen.py) derives a class with `status = NOT_CURRENT`.
    """

    status = INPUT_ERROR


class NotCurrent(GenError):
    """The committed output is not the one the inputs give (--check)."""

    status = NOT_CURRENT


class InputError(GenError):
    """An input is missing or violates a rule."""

    status = INPUT_ERROR


def run(main: Callable[..., int | None], prog: str, *args) -> int:
    """Call main(*args) and return its status (None is 0); a GenError becomes `prog: message` on stderr
    and its status."""
    try:
        return main(*args) or OK
    except GenError as err:
        print(f"{prog}: {err}", file=sys.stderr)
        return err.status
