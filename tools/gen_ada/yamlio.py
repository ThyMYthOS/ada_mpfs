# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Reading YAML inputs with one readable message per failure.

  load(path)          the parsed file; PyYAML is imported here, when the first file is read
  parse(text, where)  the same for a text that is not in a file (<where> names it in the messages)

PyYAML is imported on the first call, not with the generator: a run that reads no YAML (`svd.py ensure`
of an SVD that has its hash) works without it. Every failure is an error of the class the caller names,
with the file in the message:

  PyYAML is not installed         `PyYAML is not installed (...)`
  the file cannot be read         `FILE: cannot read (...)`
  the file is not valid YAML      `FILE: not valid YAML: ...`

With unique_keys=True a key that a mapping has twice is not valid YAML either (the YAML specification
requires unique keys; `yaml.safe_load` keeps the last value without a word). The message names the
key and its line.
"""
from pathlib import Path
from typing import Any

from .errors import GenError, InputError

_unique_loader: Any = None


def _yaml(error: type[GenError]) -> Any:
    try:
        import yaml  # type: ignore[import-untyped]
    except ImportError as err:
        raise error(f"PyYAML is not installed ({err}); run ./x toolchain install") from err
    return yaml


def _unique_key_loader(yaml: Any) -> Any:
    """yaml.SafeLoader that refuses a key given twice in one mapping (made once, on first use)."""
    global _unique_loader
    if _unique_loader is None:
        class UniqueKeyLoader(yaml.SafeLoader):  # type: ignore[misc]
            def construct_mapping(self, node: Any, deep: bool = False) -> Any:
                seen = set()
                for key_node, _ in node.value:
                    if key_node.tag == "tag:yaml.org,2002:merge":
                        continue
                    key = self.construct_object(key_node, deep=deep)
                    try:
                        twice = key in seen
                        seen.add(key)
                    except TypeError:       # an unhashable key: the base class reports it
                        continue
                    if twice:
                        raise yaml.constructor.ConstructorError(
                            None, None, f"the key {key!r} is given twice in this mapping", key_node.start_mark)
                return super().construct_mapping(node, deep)
        _unique_loader = UniqueKeyLoader
    return _unique_loader


def parse(text: str, where: str, *, error: type[GenError] = InputError, unique_keys: bool = False) -> Any:
    """The data of the YAML text <text> (`yaml.safe_load`); <where> names it in the messages."""
    yaml = _yaml(error)
    loader = _unique_key_loader(yaml) if unique_keys else yaml.SafeLoader
    try:
        return yaml.load(text, Loader=loader)
    except yaml.YAMLError as err:
        raise error(f"{where}: not valid YAML: {err}") from err


def load(path: Path, *, error: type[GenError] = InputError, name: str | None = None,
         unique_keys: bool = False) -> Any:
    """The data of the YAML file <path> (`yaml.safe_load`); <name> stands for the path in the messages."""
    _yaml(error)
    where = name or str(path)
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as err:
        raise error(f"{where}: cannot read ({err})") from err
    return parse(text, where, error=error, unique_keys=unique_keys)
