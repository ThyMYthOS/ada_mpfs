# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# @req GEN-005
"""The differential test of the reader of the MSS Configurator XML against Microchip's configuration generator.

  python3 -I tools/mchp_diff/mchp_diff.py [--all] [--svd SVD] [--exceptions FILE] [--cache DIR]
                                          [--generator-output DIR] [XML...]

For each XML (default: every config/boards/*/*.xml) Microchip's generator (mpfs_configuration_generator.py of
polarfire-soc/platform at the commit of oracle.env) writes its C headers, and every `#define LIBERO_SETTING_*`
of them is compared with what config/gen/mpfs_gen/xml_reader.py reads from the same XML. The generator is a
test oracle only: it is fetched at run time into a cache outside the checkout (default build/mchp_diff), its
commit and the SHA-256 of the script are checked, and it runs as untrusted code: `python3 -I`, the XML alone
in a directory of its own (given a file, the generator takes the newest .xml of that file's directory), the
output in a temporary directory.

Each define falls into one class:

  compared      its header and name give a register (section, name) of the model, a memory element (its
                address, or its size for <NAME>_SIZE) or a field of the design information; the values must agree
  outside       the section is one that the reader only validates (DDR, the SGMII and DDR PLLs, hsio)
  own           a constant of the generator itself (its own version), no counterpart in the XML
  unmapped      none of the above: an unknown header, a name without the prefix of its header, a register
                that the section of the model does not have, a value that is not a C integer or string, a
                define given a second time (each is guarded by `#if !defined`, so C keeps the first)

and every register and memory element of the model that no define gives is `missing`. A difference (compared
and not equal), an unmapped define and a missing register fail, unless the exception list (exceptions.yaml)
admits it: an entry names the define, the XML, whose defect it is (ours or microchip) and the reason. An entry
without a reason, of another defect, with an unknown key, given twice, or that admits nothing of the XMLs
run is refused.

--generator-output DIR takes DIR (the fpga_design_config directory of a run) instead of running the generator;
with one XML only (the stand-in of the negative tests). --all prints every define, not only the differences.
Exit status: 0 everything agrees or is admitted, 1 a difference that is not admitted, 2 an input or the
generator failed (gen_ada.errors).
"""
import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

# Run as `python3 -I tools/mchp_diff/mchp_diff.py`: the generator package from config/gen and the library from
# tools/, never this directory (it would shadow nothing today, but the rule of config/gen/mpfs_gen holds here).
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path[:] = [p for p in sys.path if p not in (str(HERE), "")]
for _path in (str(ROOT / "tools"), str(ROOT / "config" / "gen")):
    if _path not in sys.path:
        sys.path.insert(0, _path)

from gen_ada import errors, svdread, yamlio
from mpfs_gen import target, xml_reader
from mpfs_gen.checks import DiagnosticError
from mpfs_gen.model import MssConfiguration

TOOL = "mchp_diff"
ORACLE = HERE / "oracle.env"
EXCEPTIONS = HERE / "exceptions.yaml"
CACHE = ROOT / "build" / "mchp_diff"
OUTPUT = "fpga_design_config"
PREFIX = "LIBERO_SETTING_"
TIMEOUT = 120

# The header of each section that Microchip's generator writes (its tables xml_tags and header_files, read, not
# copied) and the prefix it puts before the register name: LIBERO_SETTING_<prefix><register>. The prefix tells
# apart the registers of the same name in the three PLLs (MSS_, SGMII_, DDR_), the PMP CSRs of the harts and the
# entries of the MPUs; the alternative IO set has ALT_ in the register names of the XML already.
HEADERS: dict[str, tuple[str, str]] = {
    "memory_map/hw_memory.h": (xml_reader.MEM_ELEMENTS, ""),
    "memory_map/hw_apb_split.h": ("mss_memory_map/apb_split", ""),
    "memory_map/hw_cache.h": ("mss_memory_map/cache", ""),
    **{f"memory_map/hw_pmp_hart{hart}.h": (f"mss_memory_map/pmp_h{hart}", f"HART{hart}_")
       for hart in range(target.NUMBER_OF_HARTS)},
    **{f"memory_map/hw_mpu_{master}.h": (f"mss_memory_map/mpu_{master}", f"{master.upper()}_")
       for master in xml_reader.MPU_MASTERS},
    "memory_map/hw_nvm_map.h": ("mss_memory_map/nvm_map", ""),
    "io/hw_mssio_mux.h": ("mss_io/io_mux", ""),
    "io/hw_mssio_mux_alternate.h": ("mss_io/io_mux_alt", ""),
    "io/hw_hsio_mux.h": ("mss_io/hsio", ""),
    "sgmii/hw_sgmii_tip.h": ("mss_sgmii/tip", ""),
    **{f"ddr/hw_ddr_{leaf}.h": (f"mss_ddr/{leaf}", "") for leaf in ("options", "io_bank", "mode", "off_mode", "segs")},
    "ddr/hw_ddrc.h": ("mss_ddr/ddrc", ""),
    "clocks/hw_mss_clks.h": ("mss_clocks/clocks", ""),
    "clocks/hw_clk_sysreg.h": ("mss_clocks/mss_sys", "MSS_"),
    "clocks/hw_clk_mss_pll.h": ("mss_clocks/mss_pll", "MSS_"),
    "clocks/hw_clk_sgmii_pll.h": ("mss_clocks/sgmii_pll", "SGMII_"),
    "clocks/hw_clk_ddr_pll.h": ("mss_clocks/ddr_pll", "DDR_"),
    "clocks/hw_clk_mss_cfm.h": ("mss_clocks/mss_cfm", "MSS_"),
    "clocks/hw_clk_sgmii_cfm.h": ("mss_clocks/sgmii_cfm", "SGMII_"),
    "general/hw_gen_peripherals.h": ("mss_general/mss_peripherals", ""),
}
# fpga_design_config.h: the design information (a string each, the parts of the format version as numbers)
# and the generator's own version.
DESIGN_HEADER = "fpga_design_config.h"
DESIGN = {"DESIGN_NAME": "design_name", "MSS_CONFIGURATOR_VERSION": "libero_version", "MPFS_PART": "part_number",
          "GENERATION_DATE": "created", "XML_VERSION": "format_version"}
VERSION_PARTS = ("XML_VERSION_MAJOR", "XML_VERSION_MINOR", "XML_VERSION_PATCH")
OWN = ("HEADER_GENERATOR_VERSION", "HEADER_GENERATOR_VERSION_MAJOR", "HEADER_GENERATOR_VERSION_MINOR",
       "HEADER_GENERATOR_VERSION_PATCH")

DEFECTS = ("ours", "microchip")
FAILING = ("differs", "unmapped", "missing")

_COMMENT = re.compile(r"/\*.*?\*/|//[^\n]*", re.DOTALL)
_DEFINE = re.compile(r"^[ \t]*#[ \t]*define[ \t]+(\w+)(?:[ \t]+(.*?))?[ \t]*$", re.MULTILINE)
_INTEGER = re.compile(r"(0[xX][0-9a-fA-F]+|0[0-7]*|[1-9][0-9]*)(?:[uU](?:ll|LL|[lL])?|(?:ll|LL|[lL])[uU]?)?")
_STRING = re.compile(r'"([^"\\\n]*)"')
_PIN = re.compile(r"^([A-Z][A-Z0-9_]*)=(.*)$")


class Difference(errors.GenError):
    """A difference that the exception list does not admit."""

    status = errors.NOT_CURRENT


@dataclass(frozen=True, slots=True)
class Oracle:
    """oracle.env: the pinned source of Microchip's generator."""
    repo: str
    commit: str
    date: str
    script: str
    sha256: str


@dataclass(frozen=True, slots=True)
class Define:
    """A `#define NAME VALUE` of a generated header (<header> relative to fpga_design_config)."""
    header: str
    name: str
    text: str


@dataclass(frozen=True, slots=True)
class Row:
    """The verdict on one define (or on a register of the model that no define gives, kind `missing`).

    <kind> is agrees, differs, outside, own, unmapped or missing; <target> is what the define stands for
    (SECTION/NAME, design/FIELD) or why it maps to nothing; <ours> and <theirs> are the values as shown."""
    define: str
    kind: str
    target: str
    ours: str = ""
    theirs: str = ""


@dataclass(frozen=True, slots=True)
class Exception_:
    """An entry of the exception list."""
    define: str
    xml: str
    defect: str
    reason: str


def load_oracle(path: Path = ORACLE) -> Oracle:
    """The pin of oracle.env (plain NAME=VALUE lines and comments)."""
    values: dict[str, str] = {}
    try:
        text = path.read_text()
    except OSError as err:
        raise errors.InputError(f"{path}: cannot read ({err.strerror or err})") from err
    for number, line in enumerate(text.splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        match = _PIN.match(line)
        if not match:
            raise errors.InputError(f"{path}:{number}: not a NAME=VALUE line")
        values[match.group(1)] = match.group(2)
    keys = {"MCHP_PLATFORM_REPO": "repo", "MCHP_PLATFORM_COMMIT": "commit", "MCHP_PLATFORM_DATE": "date",
            "MCHP_GENERATOR": "script", "MCHP_GENERATOR_SHA256": "sha256"}
    missing = [key for key in keys if not values.get(key)]
    if missing:
        raise errors.InputError(f"{path}: no {', '.join(missing)}")
    oracle = Oracle(**{field: values[key] for key, field in keys.items()})
    if not re.fullmatch(r"[0-9a-f]{40}", oracle.commit) or not re.fullmatch(r"[0-9a-f]{64}", oracle.sha256):
        raise errors.InputError(f"{path}: the commit must be a full hash, the SHA-256 64 hex digits")
    return oracle


def _git(*args: str, cwd: Path | None = None) -> str:
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0")
    result = subprocess.run(["git", *args], cwd=cwd, env=env, capture_output=True, text=True, check=False,
                            timeout=TIMEOUT)
    if result.returncode != 0:
        raise errors.InputError(f"git {' '.join(args)} failed:\n{(result.stdout + result.stderr).rstrip()}")
    return result.stdout.strip()


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def ensure_generator(oracle: Oracle, cache: Path = CACHE) -> Path:
    """The script of Microchip's generator at the pinned commit: fetched once (that commit only, the directory
    of the script only) into <cache>/platform-<commit>; the commit and the SHA-256 of the script are checked
    on every call."""
    clone = cache / f"platform-{oracle.commit}"
    script = clone / oracle.script
    if not script.is_file():
        partial = cache / f"platform-{oracle.commit}.partial"
        shutil.rmtree(partial, ignore_errors=True)
        partial.mkdir(parents=True)
        _git("init", "-q", str(partial))
        _git("fetch", "-q", "--depth", "1", "--filter=blob:none", oracle.repo, oracle.commit, cwd=partial)
        _git("sparse-checkout", "set", "--no-cone", "/" + str(Path(oracle.script).parent) + "/", cwd=partial)
        _git("-c", "advice.detachedHead=false", "checkout", "-q", "FETCH_HEAD", cwd=partial)
        shutil.rmtree(clone, ignore_errors=True)
        partial.rename(clone)
    head = _git("rev-parse", "HEAD", cwd=clone)
    if head != oracle.commit:
        raise errors.InputError(f"{clone} is at {head}, not at the pinned {oracle.commit}; remove it")
    if not script.is_file() or _sha256(script) != oracle.sha256:
        raise errors.InputError(f"{script}: missing or not the SHA-256 of {ORACLE.name}; remove {clone}")
    return script


def run_generator(script: Path, xml: Path, work: Path) -> Path:
    """Run Microchip's generator on <xml> inside <work>; returns its fpga_design_config directory."""
    source = work / "xml"
    out = work / "out"
    source.mkdir(parents=True)
    out.mkdir()
    shutil.copyfile(xml, source / xml.name)
    result = subprocess.run([sys.executable, "-I", str(script), str(source / xml.name), str(out)], cwd=out,
                            capture_output=True, text=True, check=False, timeout=TIMEOUT)
    # The generator ends with status 0 also where it gives up (sys.exit() without a status): only the
    # header that it writes last says that it got through.
    if result.returncode != 0 or not (out / OUTPUT / DESIGN_HEADER).is_file():
        raise errors.InputError(f"{xml}: Microchip's generator failed (status {result.returncode}):\n"
                                f"{(result.stdout + result.stderr).rstrip()}")
    return out / OUTPUT


def parse_defines(directory: Path) -> list[Define]:
    """Every `#define LIBERO_SETTING_*` of the headers below <directory>, in the order of the files, comments
    removed first (the generator puts the fields of a register into comments)."""
    if not directory.is_dir():
        raise errors.InputError(f"{directory}: no such directory")
    found: list[Define] = []
    for path in sorted(directory.rglob("*.h")):
        header = path.relative_to(directory).as_posix()
        text = _COMMENT.sub(" ", path.read_text(errors="replace"))
        for match in _DEFINE.finditer(text):
            if match.group(1).startswith(PREFIX):
                found.append(Define(header, match.group(1), (match.group(2) or "").strip()))
    return found


def c_integer(text: str) -> int | None:
    """The value of a C integer literal (hex, octal, decimal, with a suffix U, L, UL, ULL ...); None otherwise."""
    match = _INTEGER.fullmatch(text)
    if not match:
        return None
    digits = match.group(1)
    if digits.lower().startswith("0x"):
        return int(digits, 16)
    return int(digits, 8) if digits.startswith("0") else int(digits)


def c_string(text: str) -> str | None:
    match = _STRING.fullmatch(text)
    return match.group(1) if match else None


def _shown(value: int, bits: int, decimal: bool) -> str:
    return str(value) if decimal else f"{value:#0{bits // 4 + 2}x}"


def compare(config: MssConfiguration, defines: list[Define]) -> list[Row]:
    """The verdict on every define and on every register and memory element of <config> that no define gives."""
    rows: list[Row] = []
    seen: set[tuple[str, str]] = set()
    sections = set(config.sections)
    validated = set(config.validated)
    mems = {mem.name: mem for mem in config.mem_elements}

    def integer(define: Define, target_: str, ours: int, bits: int = 32, decimal: bool = False) -> Row:
        theirs = c_integer(define.text)
        if theirs is None:
            return Row(define.name, "unmapped", f"{target_}: {define.text!r} is not a C integer")
        kind = "agrees" if theirs == ours else "differs"
        return Row(define.name, kind, target_, _shown(ours, bits, decimal), _shown(theirs, bits, decimal))

    first: dict[str, str] = {}
    for define in defines:
        name = define.name.removeprefix(PREFIX)
        if define.name in first:
            # every define is guarded by `#if !defined`: C keeps the first, this one is dead
            rows.append(Row(define.name, "unmapped", f"{define.header}: defined before in {first[define.name]}"))
            continue
        first[define.name] = define.header
        if define.header == DESIGN_HEADER:
            design = config.design
            if name in DESIGN:
                theirs_text = c_string(define.text)
                ours_text = str(getattr(design, DESIGN[name]))
                if theirs_text is None:
                    rows.append(Row(define.name, "unmapped", f"design/{DESIGN[name]}: {define.text!r} is not a C string"))
                else:
                    rows.append(Row(define.name, "agrees" if theirs_text == ours_text else "differs",
                                    f"design/{DESIGN[name]}", repr(ours_text), repr(theirs_text)))
            elif name in VERSION_PARTS:
                parts = design.format_version.split(".")
                index = VERSION_PARTS.index(name)
                part = int(parts[index]) if index < len(parts) and parts[index].isdigit() else -1
                rows.append(integer(define, f"design/format_version[{index}]", part, decimal=True))
            elif name in OWN:
                rows.append(Row(define.name, "own", "the generator's own version"))
            else:
                rows.append(Row(define.name, "unmapped", f"{DESIGN_HEADER} has no such define"))
            continue
        if define.header not in HEADERS:
            rows.append(Row(define.name, "unmapped", f"{define.header} is not a header of a known section"))
            continue
        section, prefix = HEADERS[define.header]
        if not name.startswith(prefix):
            rows.append(Row(define.name, "unmapped", f"{define.header}: the name lacks the prefix {PREFIX}{prefix}"))
            continue
        register = name.removeprefix(prefix)
        if section == xml_reader.MEM_ELEMENTS:
            if register in mems:
                seen.add((section, register))
                rows.append(integer(define, f"{section}/{register}", mems[register].address))
            elif register.endswith("_SIZE") and register.removesuffix("_SIZE") in mems:
                base = register.removesuffix("_SIZE")
                seen.add((section, register))
                rows.append(integer(define, f"{section}/{base}.size", mems[base].size))
            else:
                rows.append(Row(define.name, "unmapped", f"{section} has no element {register}"))
        elif section in validated:
            rows.append(Row(define.name, "outside", f"{section}/{register}"))
        elif section in sections:
            try:
                reg = config.register(section, register)
            except KeyError:
                rows.append(Row(define.name, "unmapped", f"{section} has no register {register}"))
                continue
            seen.add((section, register))
            rows.append(integer(define, f"{section}/{register}", reg.value, reg.size,
                                section in xml_reader.DECIMAL_SECTIONS))
        else:
            rows.append(Row(define.name, "unmapped", f"the XML has no section {section}"))

    by_section = {section: (header, prefix) for header, (section, prefix) in HEADERS.items()}
    expected = [(reg.section, reg.name) for reg in config.registers]
    expected += [(xml_reader.MEM_ELEMENTS, mem.name) for mem in config.mem_elements]
    expected += [(xml_reader.MEM_ELEMENTS, mem.name + "_SIZE") for mem in config.mem_elements]
    for section, register in expected:
        if (section, register) not in seen:
            header, prefix = by_section.get(section, ("no header", ""))
            rows.append(Row(f"{PREFIX}{prefix}{register}", "missing", f"{section}/{register} ({header})"))
    return rows


def load_exceptions(path: Path = EXCEPTIONS) -> list[Exception_]:
    """The exception list: a mapping with the one key `exceptions`, a list of entries with exactly the keys
    define, xml, defect (ours or microchip) and reason (not empty); no entry twice."""
    data = yamlio.load(path, unique_keys=True)
    where = str(path)
    if not isinstance(data, dict) or set(data) != {"exceptions"} or not isinstance(data["exceptions"], list | None):
        raise errors.InputError(f"{where}: must be a mapping with the one key `exceptions`, a list")
    entries: list[Exception_] = []
    keys = {"define", "xml", "defect", "reason"}
    for index, item in enumerate(data["exceptions"] or [], 1):
        at = f"{where}: entry {index}"
        if not isinstance(item, dict) or set(item) != keys:
            got = sorted(item) if isinstance(item, dict) else type(item).__name__
            raise errors.InputError(f"{at}: needs exactly the keys {', '.join(sorted(keys))} (has {got})")
        if not all(isinstance(item[key], str) and item[key].strip() for key in keys):
            empty = [key for key in sorted(keys) if not (isinstance(item[key], str) and item[key].strip())]
            raise errors.InputError(f"{at}: {', '.join(empty)} must be a text that is not empty (a deviation is "
                                    "admitted only with a reason)")
        if item["defect"] not in DEFECTS:
            raise errors.InputError(f"{at}: defect {item['defect']!r} is not one of {', '.join(DEFECTS)}")
        if not item["define"].startswith(PREFIX):
            raise errors.InputError(f"{at}: {item['define']!r} is not a {PREFIX}* define")
        entry = Exception_(item["define"], item["xml"], item["defect"], item["reason"].strip())
        if any((e.define, e.xml) == (entry.define, entry.xml) for e in entries):
            raise errors.InputError(f"{at}: {entry.define} of {entry.xml} is listed twice")
        entries.append(entry)
    return entries


def xml_name(path: Path) -> str:
    """The name of an XML in the report and in the exception list: relative to the repository if it is in it."""
    resolved = path.resolve()
    return resolved.relative_to(ROOT).as_posix() if resolved.is_relative_to(ROOT) else str(path)


def report(name: str, rows: list[Row], admitted: dict[tuple[str, str], Exception_], show_all: bool) -> list[str]:
    """The lines printed for one XML: the differences (or every define), then a summary."""
    lines = [f"# {name}"]
    for row in rows:
        failing = row.kind in FAILING
        if not (failing or show_all):
            continue
        entry = admitted.get((name, row.define)) if failing else None
        values = f"  ours {row.ours}  microchip {row.theirs}" if row.ours or row.theirs else ""
        mark = f"  [admitted, defect of {entry.defect}: {entry.reason}]" if entry else ""
        lines.append(f"{row.kind:9} {row.define}  {row.target}{values}{mark}")
    count = {kind: sum(1 for row in rows if row.kind == kind)
             for kind in ("agrees", "differs", "outside", "own", "unmapped", "missing")}
    lines.append(f"{name}: {len(rows) - count['missing']} defines: compared {count['agrees'] + count['differs']} "
                 f"(agree {count['agrees']}, differ {count['differs']}), outside the model {count['outside']}, "
                 f"the generator's own {count['own']}, unmapped {count['unmapped']}; missing {count['missing']}")
    return lines


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog=TOOL, description="Compare the reader of the MSS Configurator XML with "
                                "Microchip's configuration generator.")
    p.add_argument("--all", action="store_true", help="print every define, not only the differences")
    p.add_argument("--svd", type=Path, help="the merged SVD (default: build/svd, made current)")
    p.add_argument("--exceptions", type=Path, default=EXCEPTIONS, help="the exception list")
    p.add_argument("--cache", type=Path, default=CACHE, help="where the generator is fetched to")
    p.add_argument("--generator-output", type=Path,
                   help="a fpga_design_config directory to take instead of running the generator (one XML)")
    p.add_argument("xmls", nargs="*", type=Path, help="the XMLs (default: config/boards/*/*.xml)")
    return p


def main(argv: list[str]) -> int:
    args = parser().parse_args(argv)
    xmls: list[Path] = args.xmls or sorted((ROOT / "config" / "boards").glob("*/*.xml"))
    if not xmls:
        raise errors.InputError("no XML to compare")
    if args.generator_output and len(xmls) != 1:
        raise errors.InputError("--generator-output takes one XML")
    exceptions = load_exceptions(args.exceptions)
    svd = args.svd or svdread.ensure(ROOT)
    script = None if args.generator_output else ensure_generator(load_oracle(), args.cache)
    names = [xml_name(xml) for xml in xmls]
    admitted = {(e.xml, e.define): e for e in exceptions}
    used: set[tuple[str, str]] = set()
    failures = 0
    for xml, name in zip(xmls, names, strict=True):
        try:
            config = xml_reader.read(xml, svd, name=name)
        except DiagnosticError as err:
            raise errors.InputError(str(err)) from err
        if script is None:
            defines = parse_defines(args.generator_output)
        else:
            with tempfile.TemporaryDirectory(prefix="mchp_diff-") as work:
                defines = parse_defines(run_generator(script, xml, Path(work)))
        rows = compare(config, defines)
        print("\n".join(report(name, rows, admitted, args.all)))
        for row in rows:
            if row.kind in FAILING:
                if (name, row.define) in admitted:
                    used.add((name, row.define))
                else:
                    failures += 1
    stale = [e for e in exceptions if e.xml in names and (e.xml, e.define) not in used]
    if stale:
        raise errors.InputError("the exception list admits what does not differ (remove the entries): "
                                + ", ".join(f"{e.define} of {e.xml}" for e in stale))
    if failures:
        raise Difference(f"{failures} difference(s) with Microchip's generator that the exception list does not admit")
    print(f"{TOOL}: ok, {len(xmls)} XML(s) agree with Microchip's generator")
    return errors.OK


if __name__ == "__main__":
    sys.exit(errors.run(main, TOOL, sys.argv[1:]))
