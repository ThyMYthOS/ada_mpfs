# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""tools/gen_ada/yamlio.py: the data of a YAML file and one readable message for every failure."""
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent.parent
sys.path[:0] = [str(HERE), str(ROOT / "tools")]

from gen_ada import errors, yamlio  # noqa: E402
from harness import case, finish, raises  # noqa: E402

try:
    import yaml  # noqa: F401
except ImportError:
    print("skip: PyYAML is not installed (./x toolchain install)")
    sys.exit(0)


class Mine(errors.GenError):
    pass


def write(tmp, text, name="f.yaml"):
    path = Path(tmp) / name
    path.write_text(text, encoding="utf-8")
    return path


@case("load: a mapping, a list, an empty file and non-ASCII text")
def _():
    with tempfile.TemporaryDirectory() as t:
        assert yamlio.load(write(t, "a: 1\nb: [x, y]\n")) == {"a": 1, "b": ["x", "y"]}
        assert yamlio.load(write(t, "- 1\n- two\n")) == [1, "two"]
        assert yamlio.load(write(t, "")) is None
        assert yamlio.load(write(t, "name: Größe\n")) == {"name": "Größe"}


@case("load: a missing file is `FILE: cannot read (...)`")
def _():
    with tempfile.TemporaryDirectory() as t:
        missing = Path(t) / "missing.yaml"
        raises(errors.InputError, lambda: yamlio.load(missing), f"{missing}: cannot read (")


@case("load: a file that is not valid YAML is `FILE: not valid YAML: ...`")
def _():
    with tempfile.TemporaryDirectory() as t:
        bad = write(t, "requirements: [\n")
        raises(errors.InputError, lambda: yamlio.load(bad), f"{bad}: not valid YAML: ")


@case("load: the name replaces the path in the messages, and the error class is the caller's")
def _():
    with tempfile.TemporaryDirectory() as t:
        bad = write(t, "a: [\n")
        err = raises(Mine, lambda: yamlio.load(bad, error=Mine, name="docs/x.yaml"), "docs/x.yaml: not valid YAML: ")
        assert str(bad) not in str(err)
        raises(Mine, lambda: yamlio.load(Path(t) / "none.yaml", error=Mine, name="n.yaml"), "n.yaml: cannot read (")


@case("parse: a text gives the data of load; its name is in the messages")
def _():
    assert yamlio.parse("a: 1\nb: [x]\n", "inline") == {"a": 1, "b": ["x"]}
    assert yamlio.parse("", "inline") is None
    raises(Mine, lambda: yamlio.parse("a: [\n", "preset u54", error=Mine), "preset u54: not valid YAML: ")


@case("unique_keys: a key given twice in one mapping is not valid YAML, with the key and its line; "
      "without it the last value wins as in yaml.safe_load")
def _():
    text = "a: 1\nb:\n  c: 2\n  c: 3\n"
    assert yamlio.parse(text, "t") == {"a": 1, "b": {"c": 3}}
    err = raises(Mine, lambda: yamlio.parse(text, "t", error=Mine, unique_keys=True), "t: not valid YAML: ")
    assert "the key 'c' is given twice" in str(err) and "line 4" in str(err), str(err)
    with tempfile.TemporaryDirectory() as t:
        raises(errors.InputError, lambda: yamlio.load(write(t, "a: 1\na: 1\n"), unique_keys=True), "given twice")
        assert yamlio.load(write(t, "a: 1\nb: {a: 2}\nc: [{a: 1}, {a: 2}]\n"), unique_keys=True) == \
            {"a": 1, "b": {"a": 2}, "c": [{"a": 1}, {"a": 2}]}
        merged = "base: &b {x: 1, y: 2}\nuse:\n  <<: *b\n  y: 3\n"
        assert yamlio.load(write(t, merged), unique_keys=True)["use"] == {"x": 1, "y": 3}


@case("load: without PyYAML the message says so, and the file is not read")
def _():
    saved = sys.modules.get("yaml")
    sys.modules["yaml"] = None          # `import yaml` raises ImportError
    try:
        with tempfile.TemporaryDirectory() as t:
            raises(errors.InputError, lambda: yamlio.load(write(t, "a: 1\n")), "PyYAML is not installed")
            raises(Mine, lambda: yamlio.load(Path(t) / "none.yaml", error=Mine), "PyYAML is not installed")
    finally:
        sys.modules["yaml"] = saved


finish()
