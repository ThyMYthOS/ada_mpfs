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
