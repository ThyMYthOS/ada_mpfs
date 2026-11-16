# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# @req GEN-001
"""The reader of system.yaml: YAML, the JSON schema, the defaults, the normalisation, the rules.

  read(path)              the System of the file, or SystemDescriptionError with every diagnostic
  read_text(text, where)  the same for a text (the presets)
  validate(data)          the diagnostics of the schema on parsed data (GEN-E002 to GEN-E013)

The order: the file is parsed (yaml.safe_load, a key given twice is an error: GEN-E001), the schema
version is checked first (a description of another version would only give a list of unknown fields),
then the schema (config/gen/schema/system.schema.json). Only a description that the schema accepts gets
its defaults and goes through the rules across fields (checks.semantic), so that each mistake is
reported once, with one code.

The defaults that depend on other fields (the console by hart, the stacks by profile) come from
target.py, the module that standalone.py takes them from as well.
"""
import json
import re
from pathlib import Path
from typing import Any

from gen_ada import errors, yamlio

from . import ROOT, checks, target
from .checks import Diagnostic, SystemDescriptionError, diagnostic
from .model import (
    L2,
    Boot,
    Fram,
    Ipc,
    L2Ways,
    Memory,
    Partition,
    Stacks,
    System,
    Watchdog,
    Window,
    Xml,
)

SCHEMA_PATH = ROOT / "config" / "gen" / "schema" / "system.schema.json"
BOARDS = ROOT / "config" / "boards"
SCHEMA_VERSION = 1

# The fields that a later version of the schema adds: an error of its own, so that the message says why.
LATER: dict[str, frozenset[str]] = {"": frozenset({"keys"}), "boot": frozenset({"slots"})}

# The validator keywords of the schema and their codes. A keyword that the schema uses and that is not
# here is a defect of the generator (a test walks the schema). A failure of the size definition is
# GEN-E010 whatever its keyword.
KEYWORD_CODES = {
    "required": "GEN-E003",
    "additionalProperties": "GEN-E004",
    "type": "GEN-E006",
    "enum": "GEN-E007",
    "const": "GEN-E007",
    "minimum": "GEN-E008",
    "maximum": "GEN-E008",
    "pattern": "GEN-E009",
    "minLength": "GEN-E009",
    "maxLength": "GEN-E009",
    "uniqueItems": "GEN-E011",
    "minItems": "GEN-E012",
    "maxItems": "GEN-E012",
    "dependentRequired": "GEN-E013",
}
SIZE_CODE = "GEN-E010"
SIZE_RE = re.compile(r"(?:(0|[1-9][0-9]*)([KM]?)|0x([0-9a-fA-F]+))")
UNITS = {"": 1, "K": 1024, "M": 1024 * 1024}

_schema: dict[str, Any] | None = None


def schema() -> dict[str, Any]:
    """The JSON schema of system.yaml (read once)."""
    global _schema
    if _schema is None:
        _schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    return _schema


def _validator() -> Any:
    try:
        import jsonschema  # type: ignore[import-untyped]
    except ImportError as err:
        raise errors.InputError(f"jsonschema is not installed ({err}); run ./x toolchain install") from err
    return jsonschema.Draft202012Validator(schema())


def path_text(parts: Any) -> str:
    """partitions[1].stacks.main for the path ('partitions', 1, 'stacks', 'main')."""
    out = ""
    for part in parts:
        out += f"[{part}]" if isinstance(part, int) else (f".{part}" if out else str(part))
    return out


def _schema_diagnostics(error: Any) -> list[Diagnostic]:
    """The diagnostics of one failure of the validator."""
    where = path_text(error.absolute_path)
    keyword = error.validator
    if keyword == "additionalProperties":
        known = set(error.schema.get("properties", {}))
        later = LATER.get(where, frozenset())
        out = []
        for name in sorted(set(error.instance) - known):
            at = f"{where}.{name}" if where else name
            if name in later:
                out.append(diagnostic("GEN-E005", at, f"{name} belongs to a later version of the schema"))
            else:
                out.append(diagnostic("GEN-E004", at, f"unknown field {name!r}"))
        return out
    if error.schema == schema()["$defs"]["size"] and keyword in ("type", "minimum", "pattern"):
        return [diagnostic(SIZE_CODE, where, f"{error.instance!r} is not a size (e.g. 4096, 0x1000, 64K, 1M)")]
    if keyword not in KEYWORD_CODES:
        raise KeyError(f"the schema keyword {keyword!r} has no error code")
    return [diagnostic(KEYWORD_CODES[keyword], where, error.message)]


def validate(data: Any) -> list[Diagnostic]:
    """The schema diagnostics of the parsed description <data>, in the order of their paths."""
    if not isinstance(data, dict):
        return [diagnostic("GEN-E006", "", "the top level must be a mapping")]
    if "schema" not in data:
        return [diagnostic("GEN-E002", "schema", "the schema version is missing (schema: 1)")]
    if data["schema"] != SCHEMA_VERSION or isinstance(data["schema"], bool):
        return [diagnostic("GEN-E002", "schema", f"schema version {data['schema']!r} is not supported (1 is)")]
    found: list[Diagnostic] = []
    for error in _validator().iter_errors(data):
        found += _schema_diagnostics(error)
    return sorted(found, key=lambda d: (d.path, d.code, d.message))


def size(value: int | str) -> int:
    """Bytes of a size that the schema accepted: 4096, 0x1000, 64K, 1M."""
    if isinstance(value, int):
        return value
    found = SIZE_RE.fullmatch(value)
    if not found:
        raise ValueError(f"{value!r} is not a size")
    if found.group(3) is not None:
        return int(found.group(3), 16)
    return int(found.group(1)) * UNITS[found.group(2)]


def _window(data: dict[str, Any] | None) -> Window | None:
    if data is None:
        return None
    return Window(data["region"], size(data["size"]) if "size" in data else None)


def _partition(data: dict[str, Any]) -> Partition:
    harts = tuple(sorted(data["harts"]))
    profile = data["profile"]
    stacks = data.get("stacks", {})
    memory = data["memory"]
    code, data_window = _window(memory["code"]), _window(memory["data"])
    assert code is not None and data_window is not None
    watchdog = data.get("watchdog")
    return Partition(
        name=data["name"],
        harts=harts,
        profile=profile,
        priv=data.get("priv", "u"),
        memory=Memory(code, data_window, _window(memory.get("fast_text"))),
        stacks=Stacks(
            main=size(stacks.get("main", target.DEFAULT_STACK_SIZE)),
            interrupt=size(stacks.get("interrupt", target.INTERRUPT_STACK[profile])),
            secondary=size(stacks.get("secondary", target.SECONDARY_STACK[profile]))),
        console=data.get("console", target.default_console(harts[0])),
        peripherals=tuple(sorted(data.get("peripherals", ()))),
        interrupts=tuple(sorted(data.get("interrupts", ()))),
        watchdog=Watchdog(watchdog["instance"], watchdog["timeout_ms"]) if watchdog else None)


def build(data: dict[str, Any]) -> System:
    """The System of a description that the schema accepts, with the defaults applied."""
    l2 = data.get("l2", {})
    ways = l2.get("ways")
    xml = data.get("xml")
    boot = data.get("boot")
    fram = data.get("fram")
    return System(
        schema=data["schema"],
        board=data["board"],
        xml=Xml(xml["file"], xml["sha256"]) if xml else None,
        security_profile=data.get("security_profile", "dev"),
        l2=L2(ways=L2Ways(ways["cache"], ways["lim"], ways["scratchpad"]) if ways else None,
              reason=l2.get("reason"),
              cache_partitioning=tuple((hart, tuple(sorted(w))) for hart, w in
                                       sorted(l2.get("cache_partitioning", {}).items()))),
        partitions=tuple(_partition(p) for p in data["partitions"]),
        ipc=tuple(Ipc(c["name"], (min(c["between"]), max(c["between"])), size(c["size"]),
                      c.get("doorbell", False)) for c in data.get("ipc", ())),
        boot=Boot(tuple(boot["sources"])) if boot else None,
        fram=Fram(fram["transport"], fram.get("part", "auto"), fram["sck_hz"], fram["cs"],
                  fram.get("wp", "none")) if fram else None)


class _Unreadable(errors.InputError):
    pass


def read_text(text: str, where: str, *, boards: Path = BOARDS) -> System:
    """The System of the description <text>; <where> names it in the messages."""
    try:
        data = yamlio.parse(text, where, error=_Unreadable, unique_keys=True)
    except _Unreadable as err:
        raise SystemDescriptionError(where, [diagnostic("GEN-E001", "", str(err).removeprefix(f"{where}: "))]) from err
    return _checked(data, where, boards)


def read(path: Path, *, boards: Path = BOARDS, name: str | None = None) -> System:
    """The System of the file <path>; <name> stands for the path in the messages."""
    where = name or str(path)
    try:
        data = yamlio.load(path, error=_Unreadable, name=where, unique_keys=True)
    except _Unreadable as err:
        raise SystemDescriptionError(where, [diagnostic("GEN-E001", "", str(err).removeprefix(f"{where}: "))]) from err
    return _checked(data, where, boards)


def _checked(data: Any, where: str, boards: Path) -> System:
    found = validate(data)
    if found:
        raise SystemDescriptionError(where, found)
    system = build(data)
    found = checks.semantic(system, boards)
    if found:
        raise SystemDescriptionError(where, found)
    return system
