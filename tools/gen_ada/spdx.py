# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""The licence header of a generated file.

  header(style, licence)   the two tag lines in the comment syntax of `style`

A generator that writes a header must not spell the tags as a string literal: `reuse` reads a
literal tag as a tag of the generator itself (a second licence, or an invalid expression), and
`tools/headers.py check` fails on it. The tags are assembled here, in one place, and nowhere else.

The styles are the comment syntaxes of the generated files:

  ada     `--  tag`, one per line (Ada, GPR)
  shell   `# tag`, one per line (shell, Python, YAML, TOML)
  xml     `<!--`, the tags, `-->` (XML, SVD, Markdown, HTML)
"""

COPYRIGHT = "2026 Manuel Stahl <thymythos@googlemail.com>"

# Assembled so that the tools do not read the tags below as the tags of this file.
_PREFIX = "SPDX"
_COPYRIGHT_TAG = _PREFIX + "-FileCopyrightText:"
_LICENSE_TAG = _PREFIX + "-License-Identifier:"

_LINE_PREFIX = {"ada": "--  ", "shell": "# ", "python": "# ", "yaml": "# "}
_BLOCK = {"xml": ("<!--", "-->"), "markdown": ("<!--", "-->"), "html": ("<!--", "-->")}


def lines(licence: str, copyright_text: str = COPYRIGHT) -> list[str]:
    """The two tags without a comment marker: copyright text first, then the licence."""
    return [f"{_COPYRIGHT_TAG} {copyright_text}", f"{_LICENSE_TAG} {licence}"]


def header(style: str, licence: str, copyright_text: str = COPYRIGHT) -> str:
    """The tag lines, each ended by a newline, as comments of `style`.

    `licence` is an SPDX expression, e.g. `CC-BY-4.0` or
    `GPL-3.0-or-later WITH GCC-exception-3.1`. An unknown style is a mistake of the caller
    (ValueError), not of an input.
    """
    tags = lines(licence, copyright_text)
    if style in _LINE_PREFIX:
        return "".join(_LINE_PREFIX[style] + line + "\n" for line in tags)
    if style in _BLOCK:
        opening, closing = _BLOCK[style]
        return "".join(f"{part}\n" for part in (opening, *tags, closing))
    raise ValueError(f"unknown comment style {style!r} (one of {', '.join(sorted({*_LINE_PREFIX, *_BLOCK}))})")
