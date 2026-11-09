# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""tools/headers.py: a literal SPDX tag outside the header of a file under tools/, crates/ or tests/ is
reported, a real header and other directories are not."""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent.parent
sys.path[:0] = [str(HERE), str(ROOT / "tools")]

import headers  # noqa: E402
from gen_ada import spdx  # noqa: E402
from harness import case, finish  # noqa: E402

C, L = spdx.COPYRIGHT_TAG, spdx.LICENSE_TAG
HEADER = f"# {C} 2026 Someone\n# {L} Apache-2.0\n"


def stray(name, text):
    return [n for n, _ in headers.stray_tags(name, text)]


@case("a header at the top of a script is fine, in any comment syntax")
def _():
    assert stray("tools/x.py", HEADER + "print(1)\n") == []
    assert stray("tools/x.sh", "#!/bin/sh\n" + HEADER) == []
    assert stray("crates/a/b.ads", f"--  {C} x\n--  {L} y\n") == []
    assert stray("tests/t.c", f"/*\n * {C} x\n * {L} y\n */\n") == []
    assert stray("tools/x.md", f"<!--\n{C} x\n{L} y\n-->\n") == []


@case("a tag in a string of a generator is reported with its line number")
def _():
    text = HEADER + f'X = """\n{C} 2026 Someone\n{L} CC-BY-4.0\n"""\n'
    assert stray("tools/gen.py", text) == [4, 5]
    assert stray("tools/gen.py", HEADER + f'H = "# {L} MIT"\n') == [3]
    assert stray("crates/mpfs_rts/g.py", HEADER + f"print(f'{C} x')\n") == [3]


@case("a tag in a comment below the header is reported, and a header that starts after line 30 is not a header")
def _():
    assert stray("tools/x.sh", HEADER + "echo\n" + f"# {L} MIT\n") == [4]
    assert stray("tests/x.sh", "\n" * 30 + HEADER) == [31, 32]


@case("a tag after a quote is no header even on the first lines")
def _():
    assert stray("tools/x.py", f'"{C} x"\n') == [1]


@case("other directories and the upstream fork are not checked")
def _():
    text = HEADER + f'X = "{L} MIT"\n'
    assert stray("examples/x.py", text) == []
    assert stray("crates/bb-runtimes/x.py", text) == []
    assert stray("docs/x.md", text) == []


@case("the files of the repository under tools/, crates/ and tests/ have no stray tag")
def _():
    bad = []
    for name in headers.files():
        if name.startswith(headers.LINT_PREFIX) and not name.startswith(headers.LINT_SKIP_PREFIX):
            text = (ROOT / name).read_text(errors="replace")
            bad += [f"{name}:{n}" for n, _ in headers.stray_tags(name, text)]
    assert not bad, bad


@case("the default header of headers.py fix is the one of gen_ada.spdx")
def _():
    assert headers.header_for("x.py") == HEADER.replace("2026 Someone", headers.COPYRIGHT) \
        + "#\n# TODO: purpose\n"
    assert headers.header_for("x.md") == spdx.header("markdown", "CC-BY-4.0", headers.COPYRIGHT)


finish()
