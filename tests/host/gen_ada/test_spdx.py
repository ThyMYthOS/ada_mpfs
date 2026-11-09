# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""tools/gen_ada/spdx.py: the header in every style, and that its source carries no literal tag."""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent.parent
sys.path[:0] = [str(HERE), str(ROOT / "tools")]

from gen_ada import spdx  # noqa: E402
from harness import case, finish, raises  # noqa: E402

# Assembled so that REUSE does not read these checks as tags of this file.
COPYRIGHT_TAG = "SPDX" + "-FileCopyrightText:"
LICENSE_TAG = "SPDX" + "-License-Identifier:"
OWNER = "2026 Manuel Stahl <thymythos@googlemail.com>"


@case("ada: two comment lines with two blanks after the dashes")
def _():
    assert spdx.header("ada", "CC-BY-4.0") == f"--  {COPYRIGHT_TAG} {OWNER}\n--  {LICENSE_TAG} CC-BY-4.0\n"


@case("ada: a licence expression with an exception is kept as written")
def _():
    text = spdx.header("ada", "GPL-3.0-or-later WITH GCC-exception-3.1")
    assert text.splitlines()[1] == f"--  {LICENSE_TAG} GPL-3.0-or-later WITH GCC-exception-3.1"


@case("shell, python and yaml: `# ` comment lines")
def _():
    want = f"# {COPYRIGHT_TAG} {OWNER}\n# {LICENSE_TAG} Apache-2.0\n"
    for style in ("shell", "python", "yaml"):
        assert spdx.header(style, "Apache-2.0") == want, style


@case("xml, markdown and html: one comment block")
def _():
    want = f"<!--\n{COPYRIGHT_TAG} {OWNER}\n{LICENSE_TAG} CC-BY-4.0\n-->\n"
    for style in ("xml", "markdown", "html"):
        assert spdx.header(style, "CC-BY-4.0") == want, style


@case("another copyright text")
def _():
    assert spdx.lines("MIT", "2030 Someone") == [f"{COPYRIGHT_TAG} 2030 Someone", f"{LICENSE_TAG} MIT"]
    assert spdx.header("shell", "MIT", "2030 Someone").startswith(f"# {COPYRIGHT_TAG} 2030 Someone\n")


@case("an unknown style is a mistake of the caller and names the styles")
def _():
    err = raises(ValueError, lambda: spdx.header("cobol", "MIT"), "cobol")
    assert "ada" in str(err) and "xml" in str(err)


@case("the source of the module has the two tags of its own header and no literal tag elsewhere")
def _():
    lines = (ROOT / "tools" / "gen_ada" / "spdx.py").read_text(encoding="utf-8").splitlines()
    tagged = [n for n, line in enumerate(lines, 1) if "SPDX" + "-" in line]
    assert tagged == [1, 2], tagged


finish()
