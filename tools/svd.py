#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Merge, validate and check the PolarFire SoC SVD.

  svd.py merge   build build/svd/PolarfireSoC.svd and record its hash in svd/PolarfireSoC.sha256
  svd.py check   rebuild and fail on any violation or if the hash differs from the recorded one
  svd.py ensure  rebuild build/svd/PolarfireSoC.svd unless it exists and has the recorded hash

The SVD is generated, not committed. svdtools starts from the device head
svd/base/device.svd and applies the includes of svd/device.yaml in this fixed order:

  1. svd/base/*.yaml      one fragment per peripheral family, adding its peripherals
  2. svd/patches/*.yaml   corrections, one file per peripheral
  3. svd/additions/*.yaml blocks without register documentation (PLIC, CLINT, interrupts)

The result is validated against svd/schema/CMSIS-SVD.xsd. Every file in patches/
and additions/ starts with the mandatory header

  # source: <where the information comes from>   (one or more)
  # status: unverified | verified-<silicon>-<yyyy-mm-dd>
  # owner:  <name>

svd/additions/local_interrupts.yaml is not merged into the SVD (hart-local
interrupts do not fit the flat SVD model); it has its own schema, checked here.

Requires svdtools (version pinned in tools/toolchain.env), xmllint and PyYAML.
"""
import fnmatch
import hashlib
import os
import re
import subprocess
import sys
from pathlib import Path
from xml.etree import ElementTree as ET



class _LazyYaml:
    """PyYAML, imported when a fragment is first read: `ensure` of an SVD that has its hash needs no YAML."""

    def __getattr__(self, name):
        import yaml as module
        return getattr(module, name)


yaml = _LazyYaml()

ROOT = Path(__file__).resolve().parent.parent
SVD = ROOT / "svd"
HASH_FILE = SVD / "PolarfireSoC.sha256"
XSD = SVD / "schema" / "CMSIS-SVD.xsd"
DEVICE_YAML = SVD / "device.yaml"
LOCAL_INTERRUPTS = SVD / "additions" / "local_interrupts.yaml"
RESULT = ROOT / "build" / "svd" / "PolarfireSoC.svd"

STATUS = re.compile(r"unverified|verified-[A-Za-z0-9_.]+-\d{4}-\d{2}-\d{2}")
IDENTIFIER = re.compile(r"[A-Z][A-Z0-9_]*")


class SvdError(Exception):
    """A violation of the SVD rules; the message is shown to the user."""


def int_of(text: str) -> int:
    """Integer value of an SVD number such as "0x2000" or "16"."""
    return int(text, 0)


def load(path: Path):
    """Parsed YAML file."""
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def base_peripherals() -> dict[str, dict]:
    """All peripherals added by the base fragments: name -> description (a dict).

    Every peripheral needs a baseAddress; an instance derived from another
    peripheral must be in the same fragment, names must be unique.
    """
    found: dict[str, dict] = {}
    for path in sorted((SVD / "base").glob("*.yaml")):
        added = (load(path) or {}).get("_add", {})
        for name, p in added.items():
            rel = path.relative_to(ROOT)
            if name in found:
                raise SvdError(f"{rel}: duplicate peripheral {name}")
            if "baseAddress" not in p:
                raise SvdError(f"{rel}: peripheral {name} has no baseAddress")
            if p.get("derivedFrom", name) not in added:
                raise SvdError(f"{rel}: {name} is derived from {p['derivedFrom']}, which is not in the same file")
            found[name] = p
    return found


def header_of(path: Path) -> dict[str, list[str]]:
    """Mandatory header of a patch or addition: key -> values, in file order."""
    found: dict[str, list[str]] = {"source": [], "status": [], "owner": []}
    for line in path.read_text(encoding="utf-8").splitlines():
        m = re.fullmatch(r"#\s*(source|status|owner):\s*(.*?)\s*", line)
        if m:
            found[m[1]].append(m[2])
    return found


def check_header(path: Path) -> list[str]:
    """Violations of the mandatory header rules in <path>."""
    rel, h, errors = path.relative_to(ROOT), header_of(path), []
    if not h["source"] or not all(h["source"]):
        errors.append(f"{rel}: missing '# source:'")
    if len(h["status"]) != 1 or not STATUS.fullmatch(h["status"][0]):
        errors.append(f"{rel}: need exactly one '# status:' (unverified or verified-<silicon>-<date>)")
    if len(h["owner"]) != 1 or not h["owner"][0]:
        errors.append(f"{rel}: need exactly one '# owner:'")
    return errors


def annotated_files() -> list[Path]:
    """Patches and additions that are merged (they carry the mandatory header), in order."""
    return sorted((SVD / "patches").glob("*.yaml")) + [
        p for p in sorted((SVD / "additions").glob("*.yaml")) if p != LOCAL_INTERRUPTS]


def merged_files() -> list[Path]:
    """Fragments, patches and additions that are merged, in application order."""
    return sorted((SVD / "base").glob("*.yaml")) + annotated_files()


def check_device_yaml() -> list[str]:
    """Check that device.yaml includes exactly the files of base/, patches/ and additions/.

    The stages must be in order: base, patches, additions. The order of the files
    within a stage is that of device.yaml, since later ones may refer to
    peripherals added by earlier ones.
    """
    includes = [(DEVICE_YAML.parent / i).resolve() for i in
                yaml.safe_load(DEVICE_YAML.read_text(encoding="utf-8")).get("_include", [])]
    present = {p.resolve() for p in merged_files()}
    errors = [f"svd/device.yaml: {p.relative_to(ROOT)} is not on disk" for p in includes if p not in present]
    errors += [f"svd/device.yaml: does not include {p.relative_to(ROOT)}" for p in sorted(present - set(includes))]
    stages = {(SVD / d).resolve(): n for n, d in enumerate(("base", "patches", "additions"))}
    kinds = [stages.get(p.parent, -1) for p in includes]
    if kinds != sorted(kinds):
        errors.append("svd/device.yaml: includes must be ordered base, patches, additions")
    return errors


def check_patch_targets(names: list[str]) -> list[str]:
    """Check that no patch targets a peripheral that does not exist.

    Top-level keys of a patch file are peripheral names or glob lists; keys
    starting with '_' are directives. Keys marked optional ('?~') may match nothing.
    """
    errors = []
    for path in sorted((SVD / "patches").glob("*.yaml")):
        for key in yaml.safe_load(path.read_text(encoding="utf-8")) or {}:
            if key.startswith("_") or key.startswith("?~"):
                continue
            if not any(fnmatch.fnmatchcase(n, g.strip()) for g in key.split(",") for n in names):
                errors.append(f"{path.relative_to(ROOT)}: no peripheral matches '{key}'")
    return errors


def check_local_interrupts(plic_names: set[str]) -> list[str]:
    """Validate svd/additions/local_interrupts.yaml against its schema.

    Local numbers must be unique per hart and in 0..47 (the mcause is 16 more),
    names must be unique per hart, and a 'plic' reference must name an interrupt
    of interrupts.yaml.
    """
    rel = LOCAL_INTERRUPTS.relative_to(ROOT)
    data = yaml.safe_load(LOCAL_INTERRUPTS.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or set(data) != {"schema", "harts", "interrupts"}:
        return [f"{rel}: expected exactly the keys schema, harts, interrupts"]
    errors = []
    if data["schema"] != 1:
        errors.append(f"{rel}: unsupported schema {data['schema']}")
    harts = data["harts"]
    if sorted(harts.values()) != [0, 1, 2, 3, 4]:
        errors.append(f"{rel}: harts must map names to the ids 0..4, each once")
    used: dict[str, tuple[set[int], set[str]]] = {h: (set(), set()) for h in harts}
    for i, e in enumerate(data["interrupts"]):
        where = f"{rel}: interrupt #{i}"
        if not isinstance(e, dict) or not {"local", "name", "description", "harts"} <= set(e) \
                or set(e) - {"local", "name", "description", "harts", "plic"}:
            errors.append(f"{where}: needs local, name, description, harts and optionally plic")
            continue
        if not (isinstance(e["local"], int) and 0 <= e["local"] <= 47):
            errors.append(f"{where}: local must be 0..47")
        if not IDENTIFIER.fullmatch(str(e["name"])):
            errors.append(f"{where}: bad name {e['name']!r}")
        if "plic" in e and e["plic"] not in plic_names:
            errors.append(f"{where}: unknown PLIC interrupt {e['plic']!r}")
        for h in e["harts"]:
            if h not in harts:
                errors.append(f"{where}: unknown hart {h!r}")
                continue
            nums, names = used[h]
            if e["local"] in nums or e["name"] in names:
                errors.append(f"{where}: {e['name']} / local {e['local']} used twice on {h}")
            nums.add(e["local"])
            names.add(e["name"])
    return errors


def run(cmd: list[str]) -> None:
    """Run <cmd>; raise SvdError with its output if it fails."""
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise SvdError(f"{cmd[0]} failed:\n{r.stdout}{r.stderr}".rstrip())


def check_svdtools() -> None:
    """Fail unless the installed svdtools is the version pinned in tools/toolchain.env."""
    want = os.environ.get("SVDTOOLS_VERSION")
    try:
        r = subprocess.run(["svdtools", "--version"], capture_output=True, text=True)
    except FileNotFoundError:
        raise SvdError("svdtools not found; run ./x toolchain install") from None
    found = r.stdout.split()[-1] if r.returncode == 0 and r.stdout.split() else None
    if found is None:
        raise SvdError("svdtools not found; run ./x toolchain install")
    if want and found != want:
        raise SvdError(f"svdtools {found} found, {want} wanted; run ./x toolchain install")


def validate_xsd(svd: Path) -> None:
    """Validate <svd> against the CMSIS-SVD schema."""
    run(["xmllint", "--noout", "--schema", str(XSD), str(svd)])


def build() -> Path:
    """Run all stages and return the merged, validated SVD (build/svd/PolarfireSoC.svd)."""
    check_svdtools()
    errors = check_device_yaml()
    for p in annotated_files():
        errors += check_header(p)
    errors += check_header(LOCAL_INTERRUPTS)
    if errors:
        raise SvdError("\n".join(errors))
    names = list(base_peripherals())
    errors = check_patch_targets(names)
    interrupts = load(SVD / "additions" / "interrupts.yaml")
    errors += check_local_interrupts(set(interrupts["PLIC"]["_add"]["_interrupts"]))
    if errors:
        raise SvdError("\n".join(errors))
    RESULT.parent.mkdir(parents=True, exist_ok=True)
    run(["svdtools", "patch", "--post-validate", str(DEVICE_YAML), str(RESULT)])
    validate_xsd(RESULT)
    return RESULT


def digest(path: Path) -> str:
    """SHA-256 of <path> as a hex string."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def cmd_merge() -> int:
    """Build the SVD and record its hash in svd/PolarfireSoC.sha256."""
    out = build()
    HASH_FILE.write_text(f"{digest(out)}  {out.name}\n", encoding="utf-8")
    print(f"svd: wrote {out.relative_to(ROOT)} and {HASH_FILE.relative_to(ROOT)}")
    return 0


def cmd_check() -> int:
    """Build the SVD and fail if its hash differs from the one in svd/PolarfireSoC.sha256."""
    out = build()
    recorded = HASH_FILE.read_text(encoding="utf-8").split()[0] if HASH_FILE.is_file() else None
    if recorded != digest(out):
        raise SvdError(f"{HASH_FILE.relative_to(ROOT)} does not match the merged SVD; run ./x svd merge")
    print("svd: ok")
    return 0


def cmd_ensure() -> int:
    """Rebuild the SVD unless build/svd/PolarfireSoC.svd has the recorded hash; warn if the rebuilt one differs."""
    recorded = HASH_FILE.read_text(encoding="utf-8").split()[0] if HASH_FILE.is_file() else None
    if RESULT.is_file() and recorded == digest(RESULT):
        return 0
    print(f"svd: {RESULT.relative_to(ROOT)} is missing or does not have the recorded hash; regenerating")
    out = build()
    if recorded != digest(out):
        print(f"svd: warning: the sources do not match {HASH_FILE.relative_to(ROOT)}; run ./x svd merge", file=sys.stderr)
    return 0


def main(argv: list[str]) -> int:
    """Command line entry point; returns the exit code."""
    if len(argv) != 2 or argv[1] not in ("merge", "check", "ensure"):
        print(__doc__, file=sys.stderr)
        return 2
    try:
        return {"merge": cmd_merge, "check": cmd_check, "ensure": cmd_ensure}[argv[1]]()
    except SvdError as e:
        print(f"svd: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
