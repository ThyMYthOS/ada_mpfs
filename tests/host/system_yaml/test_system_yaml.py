# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# @verifies GEN-001, GEN-002
"""config/gen/mpfs_gen: the schema of system.yaml and its reader, on the reference systems in systems/ and
on the broken descriptions in fixtures/broken (each names the one code it must be rejected with in a line
`# expect: GEN-Exxx`); the table of the codes; the defaults; the standalone presets of the 30 runtime
variants against standalone.py. Needs PyYAML and jsonschema, no toolchain."""
import dataclasses
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent.parent
sys.path[:0] = [str(HERE.parent / "gen_ada"), str(ROOT / "config" / "gen"), str(ROOT / "tools")]

from harness import case, finish, raises

try:
    import jsonschema  # noqa: F401
    import yaml  # noqa: F401
except ImportError as err:
    print(f"skip: {err.name} is not installed (./x toolchain install)")
    sys.exit(0)

import standalone
from mpfs_gen import checks, model, presets, yaml_reader
from mpfs_gen.checks import SystemDescriptionError

BROKEN = HERE / "fixtures" / "broken"
SYSTEMS = ROOT / "systems"
REFERENCE = ("amp_a", "amp_b", "amp_c", "amp_d")
EXPECT = re.compile(r"^# expect: (GEN-E\d{3})$", re.MULTILINE)


def expected(path):
    found = EXPECT.findall(path.read_text())
    assert len(found) == 1, f"{path.name} must name exactly one expected code"
    return found[0]


def codes_of(fn):
    try:
        fn()
    except SystemDescriptionError as err:
        return err.codes
    return []


def cli(*args):
    return subprocess.run([sys.executable, "-I", str(ROOT / "config" / "gen" / "mpfs_gen"), *args],
                          capture_output=True, text=True, check=False)


@case("the four reference systems validate")
def _():
    assert sorted(p.name for p in SYSTEMS.iterdir() if p.is_dir()) == list(REFERENCE)
    for name in REFERENCE:
        system = yaml_reader.read(SYSTEMS / name / "system.yaml")
        assert system.schema == 1 and system.board == "icicle", name


@case("the reference systems are the ones described: harts, profiles and privilege modes")
def _():
    def shape(name):
        system = yaml_reader.read(SYSTEMS / name / "system.yaml")
        return [(p.harts, p.profile, p.priv) for p in system.partitions]
    assert shape("amp_a") == [((0,), "light", "u"), ((1,), "light-tasking", "m"), ((2, 3, 4), "embedded", "u")]
    assert shape("amp_b") == [((0,), "light-tasking", "u"), ((1,), "light", "u"), ((2, 3, 4), "light-tasking", "u")]
    assert shape("amp_c") == [((0,), "embedded", "u"), ((1,), "light", "u"), ((2,), "light-tasking", "u"),
                              ((3,), "embedded", "u"), ((4,), "embedded", "u")]
    assert shape("amp_d") == [((1, 2), "embedded", "u"), ((3, 4), "light", "m")]


@case("each broken description is rejected with exactly the code it names, and there are at least 20")
def _():
    files = sorted(BROKEN.glob("*.yaml"))
    assert len(files) >= 20, len(files)
    for path in files:
        got = codes_of(lambda path=path: yaml_reader.read(path))
        assert got == [expected(path)], (path.name, got)


@case("every code of system.yaml has a broken description that is rejected with it (tests/host/xml_reader has those of the XML)")
def _():
    covered = {expected(p) for p in BROKEN.glob("*.yaml")}
    assert covered == set(checks.CODES) - checks.XML_CODES, sorted((set(checks.CODES) - checks.XML_CODES) ^ covered)


@case("the messages name the file, the code and the path of the field")
def _():
    err = raises(SystemDescriptionError, lambda: yaml_reader.read(BROKEN / "e004_unknown_field.yaml", name="s.yaml"))
    assert str(err) == "s.yaml: GEN-E004 partitions[1].stack: unknown field 'stack'", str(err)
    err = raises(SystemDescriptionError, lambda: yaml_reader.read(BROKEN / "e001_duplicate_key.yaml", name="s.yaml"))
    assert "s.yaml: GEN-E001 (top level): not valid YAML: the key 'board' is given twice" in str(err)
    assert "line 8" in str(err), str(err)


@case("several mistakes are all reported, each once, in the order of their paths")
def _():
    text = ("schema: 1\nboard: icicle\npartitions:\n  - name: A\n    harts: [7]\n    profile: light\n"
            "    memory: { code: { region: lim, size: 1x }, data: { region: dtim } }\n    colour: red\n")
    err = raises(SystemDescriptionError, lambda: yaml_reader.read_text(text, "t"))
    assert [(d.code, d.path) for d in err.diagnostics] == [
        ("GEN-E004", "partitions[0].colour"), ("GEN-E008", "partitions[0].harts[0]"),
        ("GEN-E010", "partitions[0].memory.code.size"), ("GEN-E007", "partitions[0].memory.data.region"),
        ("GEN-E009", "partitions[0].name")], err.diagnostics


@case("a missing file is GEN-E001")
def _():
    with tempfile.TemporaryDirectory() as tmp:
        assert codes_of(lambda: yaml_reader.read(Path(tmp) / "none.yaml")) == ["GEN-E001"]


@case("the table of the codes in config/README.md is CODES, in the same order")
def _():
    text = (ROOT / "config" / "README.md").read_text()
    rows = re.findall(r"^\| `(GEN-E\d{3})` \| (.*?) \|$", text, re.MULTILINE)
    assert rows == list(checks.CODES.items()), [r for r in rows if r not in checks.CODES.items()]


@case("the schema: every keyword that can fail has a code, every object refuses unknown fields")
def _():
    schema = yaml_reader.schema()
    annotations = {"$schema", "title", "description", "default", "properties", "items", "$defs", "$ref"}

    def walk(node, where):
        if isinstance(node, dict):
            if node.get("type") == "object" or "properties" in node:
                assert node.get("additionalProperties") is False, f"{where}: additionalProperties is not false"
            for key, value in node.items():
                if key in ("properties", "$defs"):
                    for name, sub in value.items():
                        walk(sub, f"{where}.{name}")
                elif key not in annotations:
                    assert key in yaml_reader.KEYWORD_CODES, f"{where}: {key} has no code"
                if key == "items":
                    walk(value, f"{where}[]")
    walk(schema, "")


@case("the defaults that the schema states are the ones the reader applies")
def _():
    schema = yaml_reader.schema()
    part = schema["$defs"]["partition"]["properties"]
    system = yaml_reader.read_text("schema: 1\nboard: icicle\nboot: { sources: [fram, ymodem] }\n"
                                   "fram: { transport: spi1, sck_hz: 1000000, cs: gpio0_12 }\n"
                                   "ipc: [{ name: x, between: [b, a], size: 4K }]\n"
                                   "partitions:\n"
                                   "  - { name: a, harts: [0], profile: light, memory: { code: { region: lim, size: 4K },"
                                   " data: { region: lim, size: 4K } } }\n"
                                   "  - { name: b, harts: [2, 1], profile: embedded, memory: { code: { region: lim, size: 4K },"
                                   " data: { region: lim, size: 4K } } }\n", "t")
    assert system.security_profile == schema["properties"]["security_profile"]["default"] == "dev"
    a, b = system.partitions
    assert a.priv == b.priv == part["priv"]["default"] == "u"
    assert a.stacks.main == yaml_reader.size(part["stacks"]["properties"]["main"]["default"]) == 16384
    assert (a.stacks.interrupt, a.stacks.secondary) == (8192, 16384)
    assert (b.stacks.interrupt, b.stacks.secondary) == (12912, 16384)
    assert (a.console, b.console) == ("mmuart0", "mmuart1")
    assert b.harts == (1, 2) and b.mask == 0b110
    assert a.peripherals == () and a.interrupts == () and a.watchdog is None and a.memory.fast_text is None
    assert system.ipc[0].doorbell is schema["properties"]["ipc"]["items"]["properties"]["doorbell"]["default"]
    assert system.ipc[0].between == ("a", "b")
    fram = schema["properties"]["fram"]["properties"]
    assert system.fram is not None
    assert (system.fram.part, system.fram.wp) == (fram["part"]["default"], fram["wp"]["default"]) == ("auto", "none")
    assert system.boot is not None and system.boot.sources == ("fram", "ymodem"), "the boot order is kept"
    assert system.xml is None and system.l2.ways is None and system.l2.cache_partitioning == ()


@case("normalisation: sizes in bytes (4096, 0x1000, 64K, 1M), sorted peripherals, interrupts and ways")
def _():
    assert [yaml_reader.size(v) for v in (4096, "4096", "0x1000", "64K", "1M", "0")] == \
        [4096, 4096, 4096, 65536, 1048576, 0]
    system = yaml_reader.read(SYSTEMS / "amp_a" / "system.yaml")
    monitor, rt, app = system.partitions
    assert monitor.memory.code == model.Window("lim", 65536)
    assert rt.memory.fast_text == model.Window("itim", 16384)
    assert (monitor.stacks.main, monitor.stacks.interrupt, monitor.stacks.secondary) == (8192, 4096, 16384)
    assert app.peripherals == ("mmuart2", "mmuart3", "wdog2")
    assert rt.interrupts == ("local:MMUART", "local:WDOG_TOUT")
    assert system.fram is not None and system.fram.sck_hz == 40_000_000
    d = yaml_reader.read(SYSTEMS / "amp_d" / "system.yaml")
    assert d.l2.ways == model.L2Ways(4, 12, 0)
    assert d.l2.cache_partitioning == (("u54_1", (0, 1)), ("u54_2", (0, 1)), ("u54_3", (2, 3)), ("u54_4", (2, 3)))


@case("the model is immutable")
def _():
    system = yaml_reader.read(SYSTEMS / "amp_b" / "system.yaml")
    raises(dataclasses.FrozenInstanceError, lambda: setattr(system, "board", "x"))
    raises(dataclasses.FrozenInstanceError, lambda: setattr(system.partitions[0], "harts", (1,)))
    assert isinstance(system.partitions, tuple) and isinstance(system.partitions[0].peripherals, tuple)


@case("presets: 30 runtime variants, 6 of the E51 and 24 of the U54, each a valid description")
def _():
    assert len(presets.VARIANTS) == 30 and len(set(presets.VARIANTS)) == 30
    assert sum(1 for v in presets.VARIANTS if v[0] == "e51") == 6
    for variant in presets.VARIANTS:
        system = presets.preset(*variant)
        part, = system.partitions
        assert part.harts == ((0,) if variant[0] == "e51" else tuple(range(1, variant[1] + 1))), variant
        assert (part.profile, part.priv) == (variant[2], variant[3])


def render(args):
    """The two outputs of standalone.py for <args>, in the process (what main() writes)."""
    part = standalone.Partition(standalone.parser().parse_args([*args, "--output", "unused.ads"]))
    return standalone.render_package(part), standalone.render_defsyms(part)


@case("presets: standalone.py with the parameters of each preset writes the bytes of ./x build without options")
def _():
    for hart, cpus, profile, priv in presets.VARIANTS:
        build = ["--hart", hart, "--profile", profile, "--memory", "lim"]
        if cpus > 1:
            build += ["--harts", f"1-{cpus}"]
        args = presets.standalone_args(presets.preset(hart, cpus, profile, priv))
        assert render(args) == render(build), (hart, cpus, profile, priv, args)


@case("presets: the rendered text starts with the licence header and names its variant")
def _():
    from gen_ada import spdx
    text = presets.preset_text("u54", 3, "light-tasking", "m")
    assert text.startswith(spdx.header("yaml", "Apache-2.0"))
    assert "light-tasking-u54-cpus3-m" in text
    raises(presets.PresetError, lambda: presets.preset_text("e51", 2, "light", "u"), "no runtime variant")
    raises(presets.PresetError, lambda: presets.preset_text("u54", 1, "full", "u"), "no runtime variant")


@case("standalone_args: a description of several partitions or sized windows has no standalone form")
def _():
    raises(presets.PresetError, lambda: presets.standalone_args(yaml_reader.read(SYSTEMS / "amp_a" / "system.yaml")),
           "one partition")
    sized = presets.preset_text("e51", 1, "light", "u").replace("code: { region: lim }", "code: { region: lim, size: 64K }")
    raises(presets.PresetError, lambda: presets.standalone_args(yaml_reader.read_text(sized, "t")), "whole regions")
    scratch = presets.preset_text("u54", 1, "embedded", "u").replace("region: lim", "region: scratchpad")
    args = presets.standalone_args(yaml_reader.read_text(scratch, "t"))
    assert args[args.index("--memory") + 1] == "scratchpad"


@case("the command line: check prints ok or the diagnostics (status 2); preset prints a valid description")
def _():
    done = cli("check", *(str(SYSTEMS / n / "system.yaml") for n in REFERENCE))
    assert done.returncode == 0 and done.stdout.count(": ok\n") == 4, (done.stdout, done.stderr)
    done = cli("check", str(BROKEN / "e021_hart_in_two_partitions.yaml"))
    assert done.returncode == 2 and "GEN-E021 partitions[2].harts: hart 1 is also in partition 'app'" in done.stderr
    done = cli("preset", "u54", "2", "embedded", "u")
    assert done.returncode == 0 and "harts: [1, 2]" in done.stdout
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "p.yaml"
        path.write_text(done.stdout)
        done = cli("standalone-args", str(path))
        assert done.returncode == 0 and done.stdout.startswith("--hart u54 --harts 1,2 --profile embedded"), done
    assert cli("preset", "u54", "5", "light", "u").returncode == 2


@case("the schema is valid JSON Schema (draft 2020-12)")
def _():
    from jsonschema import Draft202012Validator
    Draft202012Validator.check_schema(json.loads(yaml_reader.SCHEMA_PATH.read_text()))


finish()
