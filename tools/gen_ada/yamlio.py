# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Reading YAML inputs with one readable message per failure.

  load(path)   the parsed file; PyYAML is imported here, when the first file is read

PyYAML is imported on the first call, not with the generator: a run that reads no YAML (`svd.py ensure`
of an SVD that has its hash) works without it. Every failure is an error of the class the caller names,
with the file in the message:

  PyYAML is not installed         `PyYAML is not installed (...)`
  the file cannot be read         `FILE: cannot read (...)`
  the file is not valid YAML      `FILE: not valid YAML: ...`
"""
from pathlib import Path

from .errors import GenError, InputError


def load(path: Path, *, error: type[GenError] = InputError, name: str | None = None):
    """The data of the YAML file <path> (`yaml.safe_load`); <name> stands for the path in the messages."""
    try:
        import yaml
    except ImportError as err:
        raise error(f"PyYAML is not installed ({err}); run ./x toolchain install") from err
    where = name or str(path)
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as err:
        raise error(f"{where}: cannot read ({err})") from err
    try:
        return yaml.safe_load(text)
    except yaml.YAMLError as err:
        raise error(f"{where}: not valid YAML: {err}") from err
