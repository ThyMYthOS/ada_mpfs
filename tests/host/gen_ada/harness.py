# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""A small case harness for the tests of tools/gen_ada (the test files run under `python -I`).

  from harness import case, finish

  @case("what holds")
  def _():
      assert ...

  finish()      # exit status 1 if a case failed

A case that raises fails and prints its traceback to stderr; the others still run.
"""
import sys
import traceback

failed = 0


def case(description):
    def decorate(fn):
        global failed
        try:
            fn()
            print("ok:   " + description)
        except Exception:
            failed += 1
            print("FAIL: " + description, file=sys.stderr)
            traceback.print_exc()
        return fn
    return decorate


def raises(error, fn, pattern=""):
    """fn() must raise `error` with `pattern` in its message; returns the exception."""
    try:
        fn()
    except error as err:
        assert pattern in str(err), f"{err!s} does not contain {pattern!r}"
        return err
    raise AssertionError(f"no {error.__name__}")


def finish():
    sys.exit(1 if failed else 0)
