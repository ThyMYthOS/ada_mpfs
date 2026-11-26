# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# @verifies GEN-015, GEN-016, GEN-019
"""tools/pmp_check, the independent checker of the PMP, against the checks of the generator.

Every case derives a system with config/gen/mpfs_gen (without raising, so that a refused system is compared
too), writes the check input (system_json.py), runs the checker on it and asserts that both report the same
findings: the same multiset of (severity, code, path) over the codes the checker evaluates (COVERED), and so
the same verdict. The cases: the reference systems with their XMLs and with the XML of the PMP demo, as dev
and as prod, with 16 and 8 entries; one case per rule that makes it fire in both; 1000 configurations drawn
from a seeded generator of random PMP tables, contexts, profiles, monitors, MPU entries, owners of DMA
masters, way masks and cache partitionings; the reader of the check input refusing a malformed one; and the
command line `derive --check-json`.

The checker is the program the suite built (PMP_CHECK, else build/pmp_check/pmp_check). The random draw is
seeded (PMP_CHECK_SEED, default 1; PMP_CHECK_CASES, default 1000): a failure names its case number and seed
and is reproduced by running the suite with them.
"""
import collections
import dataclasses
import functools
import json
import os
import random
import re
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent.parent
sys.path[:0] = [str(HERE.parent / "gen_ada"), str(ROOT / "config" / "gen"), str(ROOT / "tools")]

from gen_ada import svdread
from harness import case, finish
from mpfs_gen import checks, derive, pmp, system_json, target, xml_reader, yaml_reader
from mpfs_gen.derive import contexts, plic, waymask

# The SVD is read for the PLIC sources by every derivation; read once here, so that 1000 derivations are quick.
plic.plic_sources = functools.cache(plic.plic_sources)
plic.local_interrupts = functools.cache(plic.local_interrupts)

SVD = svdread.ensure(ROOT)
BLOCKS = xml_reader.svd_blocks(SVD)
LAYOUT = xml_reader.svd_layout(SVD)
CHECKER = Path(os.environ.get("PMP_CHECK", ROOT / "build" / "pmp_check" / "pmp_check"))
SEED = int(os.environ.get("PMP_CHECK_SEED", "1"))
CASES = int(os.environ.get("PMP_CHECK_CASES", "1000"))
TMP = Path(tempfile.mkdtemp(prefix="pmp_check."))

BOARDS = ROOT / "config" / "boards"
XMLS = {p.parent.name: p for p in sorted(BOARDS.glob("*/*.xml"))}
CONFIGS = {board: xml_reader.read(path, SVD) for board, path in XMLS.items()}
SYSTEMS = {p.parent.name: (p, yaml_reader.read(p)) for p in sorted((ROOT / "systems").glob("*/system.yaml"))}
DEMO_PATH = ROOT / "tests" / "host" / "derive" / "fixtures" / "pmp_demo" / "system.yaml"
DEMO = yaml_reader.read(DEMO_PATH)
APB = "mss_memory_map/apb_split"
CACHE = "mss_memory_map/cache"
R, W, X, L = 0x01, 0x02, 0x04, 0x80
OFF, TOR, NA4, NAPOT = 0x00, 0x08, 0x10, 0x18
ALL_ONES = 0x003F_FFFF_FFFF_FFFF

# The rules of the AMP context registers (GEN-E130 to GEN-E134) are rules of the XML's own consistency, not of
# what the PMP lets through; the checker does not evaluate them, nor GEN-E074 (l2.cache_partitioning against
# the ways of the L2 of system.yaml).
CONTEXT_CODES = {f"GEN-E13{i}" for i in range(5)}
COVERED = {"GEN-E072", "GEN-E073", "GEN-E085"} | set(checks.PMP_CODES) | \
    (set(checks.PROTECTION_CODES) - CONTEXT_CODES) | set(checks.SEPARATION_CODES)
LINE = re.compile(r"^(error|warning|note): (GEN-E\d{3}) (\S+): ")
covered: set[str] = set()


def xml_of(system, path):
    return CONFIGS[derive.xml_of(system, path).parent.name]


def edited(config, changes):
    """<config> with the fields of {(section, register, field): value} changed and the values of their registers
    recomputed (the RW fields at their offsets), as the reader computes them."""
    registers = []
    for reg in config.registers:
        fields = tuple(dataclasses.replace(f, value=changes[(reg.section, reg.name, f.name)])
                       if (reg.section, reg.name, f.name) in changes else f for f in reg.fields)
        value = sum(f.value << f.bits.offset for f in fields if f.access == "RW" and f.value is not None)
        registers.append(dataclasses.replace(reg, fields=fields, value=value))
    keys = {(r.section, r.name, f.name) for r in registers for f in r.fields}
    assert set(changes) <= keys, set(changes) - keys
    return dataclasses.replace(config, registers=tuple(registers))


def set_pmp(changes, hart, entries):
    """<changes> with the 16 entries of <hart> set to <entries> (cfg, pmpaddr) and the rest OFF and 0."""
    section = f"mss_memory_map/pmp_h{hart}"
    entries = list(entries) + [(OFF, 0)] * (16 - len(entries))
    assert len(entries) == 16, entries
    for i, (cfg, addr) in enumerate(entries):
        changes[(section, f"CSR_PMPCFG{0 if i < 8 else 2}", f"PMP{i}CFG")] = cfg
        changes[(section, f"CSR_PMPADDR{i}", f"CSR_PMPADDR{i}")] = addr
    return changes


def table(config, hart):
    """The 16 entries (cfg, pmpaddr) of <hart> in <config>."""
    harts, _ = pmp.of(config)
    return [(e.cfg, e.addr) for e in harts[hart].entries]


def set_mpu(changes, master, index, mode, field):
    """<changes> with entry <index> of the MPU of <master> set to the mode byte <mode> and the PMP field <field>."""
    reg = (f"mss_memory_map/mpu_{master}", f"MPU_CFG_PMP{index}")
    changes[(*reg, "MODE")] = mode
    changes[(*reg, "PMP")] = field
    return changes


def mpu_off(config, changes=None):
    """<changes> with every MPU entry of <config> OFF (as the Configurator writes an unused one), more on top."""
    out = {}
    for reg in config.registers:
        if reg.section.startswith("mss_memory_map/mpu_"):
            out[(reg.section, reg.name, "MODE")] = 0
            out[(reg.section, reg.name, "PMP")] = 0x1FF
    out.update(changes or {})
    return out


def with_register(config, section, name, value):
    """<config> with a register <name> more in <section> (a copy of its first register with <value>)."""
    first = config.section(section)[0]
    return dataclasses.replace(config, registers=config.registers + (dataclasses.replace(first, name=name, value=value),))


def owning(system, index, *peripherals):
    """<system> with <peripherals> added to partitions[<index>]."""
    parts = list(system.partitions)
    parts[index] = dataclasses.replace(parts[index], peripherals=tuple(sorted(parts[index].peripherals + peripherals)))
    return dataclasses.replace(system, partitions=tuple(parts))


def set_way_mask(changes, master, mask):
    reg = f"WAY_MASK_{master}"
    for i in range(16):
        changes[(CACHE, reg, f"WAY_MASK_{i}")] = mask >> i & 1
    return changes


def napot(first, size):
    return (first >> 2) | ((size >> 3) - 1)


def python_side(d):
    """The findings of the generator over COVERED, as (severity, code, path) -> count, and whether it refuses."""
    found = collections.Counter()
    for sev, items in (("error", d.errors), ("warning", d.warnings), ("note", d.notes)):
        for item in items:
            if item.code in COVERED:
                found[(sev, item.code, item.path)] += 1
    return found, any(sev == "error" for sev, _, _ in found)


def checker_side(data, name="input"):
    """The findings of the checker on the check input <data>, its verdict and its output."""
    path = TMP / f"{name}.json"
    path.write_text(system_json.text(data), encoding="utf-8")
    run = subprocess.run([str(CHECKER), str(path)], capture_output=True, text=True, check=False)
    assert run.returncode in (0, 1), (run.returncode, run.stdout, run.stderr)
    found = collections.Counter()
    for line in run.stdout.splitlines():
        m = LINE.match(line)
        if m:
            found[m.groups()] += 1
        else:
            assert line.startswith("verdict: "), line
    last = run.stdout.splitlines()[-1]
    assert (run.returncode == 1) == last.startswith("verdict: refused"), run.stdout
    return found, run.returncode == 1, run.stdout


def agree(system, config, entries=target.PMP_ENTRIES, name="input"):
    """Derive <system> with <config>, run the checker on its check input and assert the same findings; returns
    them and the verdict (True: refused)."""
    d = derive.derive(system, config, SVD, pmp_entries=entries, strict=False)
    data = system_json.check_input(d, config, BLOCKS)
    py, py_refused = python_side(d)
    ada, ada_refused, out = checker_side(data, name)
    if py != ada:
        only_py = py - ada
        only_ada = ada - py
        raise AssertionError(f"{name}: the generator only: {sorted(only_py.items())}; the checker only: "
                             f"{sorted(only_ada.items())}\n{out}")
    assert py_refused == ada_refused, name
    covered.update(code for _, code, _ in py)
    return py, py_refused


def as_profile(system, profile):
    return dataclasses.replace(system, security_profile=profile)


# --- the reference systems ---------------------------------------------------------------------------------

@case("the reference systems with their XMLs, as dev and as prod, 16 and 8 entries: the same findings")
def _():
    verdicts = {}
    for name, (path, system) in SYSTEMS.items():
        for profile in ("dev", "prod"):
            for entries in (16, 8):
                _, refused = agree(as_profile(system, profile), xml_of(system, path), entries,
                                   f"{name}-{profile}-{entries}")
                verdicts[(name, profile, entries)] = refused
    # dev never refuses for the PMP; the XMLs of the Icicle Kit refuse every prod system (the open locked entry 0)
    assert not any(v for (_, profile, _), v in verdicts.items() if profile == "dev"), verdicts
    assert all(verdicts[(n, "prod", e)] for n in ("amp_a", "amp_b", "amp_d") for e in (16, 8)), verdicts
    # amp_c passes with its 16 entries per hart, not with the 8 of QEMU
    assert not verdicts[("amp_c", "prod", 16)] and verdicts[("amp_c", "prod", 8)], verdicts


@case("amp_c (prod): both accept, with the same accepted warnings (GEN-E127, GEN-E128, GEN-E136)")
def _():
    path, system = SYSTEMS["amp_c"]
    found, refused = agree(system, xml_of(system, path), name="amp_c")
    assert not refused
    assert {code for sev, code, _ in found} == {"GEN-E127", "GEN-E128", "GEN-E136"}, found
    assert all(sev == "warning" for sev, _, _ in found), found


@case("the reference systems with the XML of Microchip's PMP demo, and the demo's own system (prod): the same "
      "findings")
def _():
    demo = CONFIGS["icicle_es_pmp_demo"]
    for name, (_, system) in SYSTEMS.items():
        if name == "amp_c":
            continue    # its L2 and windows need its own XML
        for profile in ("dev", "prod"):
            agree(as_profile(system, profile), demo, name=f"{name}-demo-{profile}")
    _, refused = agree(DEMO, demo, name="pmp_demo")
    assert refused, "the demo's deny-all hides the allow list of U mode"


# --- one case per rule -------------------------------------------------------------------------------------

AMP_C_PATH, AMP_C = SYSTEMS["amp_c"]
AMP_C_XML = xml_of(AMP_C, AMP_C_PATH)
AMP_C_DERIVED = derive.derive(AMP_C, AMP_C_XML, SVD)


def with_allow_list(hart, extra=(), drop=0, first=()):
    """The XML of amp_c with the generated allow list of <hart> written into it as unlocked entries (so that
    the generator keeps them and adds none), the last <drop> of them left out, <extra> entries after them,
    <first> entries before the locked ones."""
    locked = list(first) + [e for e in table(AMP_C_XML, hart) if e[0] & L]
    generated = [(e.cfg, e.addr) for e in AMP_C_DERIVED.protection.hart(hart).generated]
    entries = locked + generated[:len(generated) - drop] + list(extra)
    return edited(AMP_C_XML, set_pmp({}, hart, entries))


def expect(code, system, config, entries=16, name=None):
    """Both report <code> (and agree on everything)."""
    found, refused = agree(system, config, entries, name or code)
    assert code in {c for _, c, _ in found}, (code, found)
    return found, refused


@case("the allow list of amp_c written into its XML as unlocked entries: the same findings as when generated")
def _():
    found, refused = agree(AMP_C, with_allow_list(1), name="allow-list-in-xml")
    assert not refused, found


@case("GEN-E100, GEN-E101: W without R, the reserved bits 5 and 6")
def _():
    t = table(AMP_C_XML, 0)
    t[15] = (NA4 | W, 0x10)
    expect("GEN-E100", AMP_C, edited(AMP_C_XML, set_pmp({}, 0, t)))
    t[15] = (0x60, 0)
    expect("GEN-E101", AMP_C, edited(AMP_C_XML, set_pmp({}, 0, t)))


@case("GEN-E102: a locked entry after an unlocked one")
def _():
    t = [(NAPOT | R | W, napot(0x0800_0000, 0x1000))] + table(AMP_C_XML, 1)[:15]
    expect("GEN-E102", AMP_C, edited(AMP_C_XML, set_pmp({}, 1, t)))


@case("GEN-E103, GEN-E129: amp_c with the 8 entries of QEMU")
def _():
    expect("GEN-E103", AMP_C, AMP_C_XML, entries=8)
    expect("GEN-E129", AMP_C, AMP_C_XML, entries=8)


@case("GEN-E104: PMP entries with MEM_CONFIGS_ENABLED.PMP 0 (a warning)")
def _():
    found, _ = expect("GEN-E104", AMP_C, edited(AMP_C_XML, {(APB, "MEM_CONFIGS_ENABLED", "PMP"): 0}))
    assert ("warning", "GEN-E104", "mss_memory_map/apb_split/MEM_CONFIGS_ENABLED.PMP") in found


@case("GEN-E105: a locked entry over the whole space; one that hides a later entry")
def _():
    t = [(NAPOT | R | W | X | L, ALL_ONES)] + table(AMP_C_XML, 1)[:15]
    expect("GEN-E105", AMP_C, edited(AMP_C_XML, set_pmp({}, 1, t)), name="E105-whole")
    t = [(NAPOT | R | L, napot(0x0800_0000, 0x10_0000)), (NAPOT | L, napot(0x0800_0000, 0x1000))] \
        + table(AMP_C_XML, 1)[:14]
    expect("GEN-E105", AMP_C, edited(AMP_C_XML, set_pmp({}, 1, t)), name="E105-hidden")


@case("GEN-E120, GEN-E121, GEN-E122: an allow list without the last entries (the page of mtime, a peripheral, "
      "a window)")
def _():
    for drop in range(1, 5):
        agree(AMP_C, with_allow_list(1, drop=drop), name=f"drop-{drop}")
    for code in ("GEN-E120", "GEN-E121", "GEN-E122"):
        assert code in covered, code


@case("GEN-E123 to GEN-E126, GEN-E135: an unlocked entry for what is not its own, another partition's window, "
      "a critical block, SYSREG, the other context's bus window")
def _():
    control = next(w for w in AMP_C_DERIVED.windows if w.owners == ("control",) and w.kind == "code+data")
    cases = {"GEN-E123": (NAPOT | R, napot(0x0800_0000 + 0x1D_0000, 0x1000)),
             "GEN-E124": (NAPOT | R, napot(control.origin, 0x1000)),
             "GEN-E125": (NAPOT | R, napot(0x0300_0000, 0x1000)),
             "GEN-E126": (NAPOT | R | W, napot(0x2000_2000, 0x1000))}
    for code, entry in cases.items():
        # hart 1 has the locked barrier of context A, which denies SYSREG to all modes; hart 0 has none
        expect(code, AMP_C, with_allow_list(0 if code == "GEN-E126" else 1, extra=[entry]))
    # the barrier of context A denies the HI window to all modes: only a locked entry before it opens a page
    found, _ = expect("GEN-E135", AMP_C, with_allow_list(1, first=[(NAPOT | R | W | L, napot(0x2810_0000, 0x1000))]))
    assert {(sev, path) for sev, code, path in found if code == "GEN-E135"} == {("warning", "partitions[1]")}


@case("GEN-E124 in M mode: a hart with locked entries that does not lock out another context's window; "
      "GEN-E127, GEN-E128, GEN-E136 with amp_c")
def _():
    t = [e for e in table(AMP_C_XML, 3) if e[0] & L][:2]
    found, _ = expect("GEN-E124", AMP_C, edited(AMP_C_XML, set_pmp({}, 3, t)), name="E124-m")
    assert any(code == "GEN-E124" and path == "partitions[3]" for _, code, path in found)
    for code in ("GEN-E127", "GEN-E128", "GEN-E136"):
        expect(code, AMP_C, AMP_C_XML, name=f"amp_c-{code}")


@case("GEN-E072, GEN-E073: no cache way; a way mask with a scratchpad way (errors in dev too)")
def _():
    path, amp_a = SYSTEMS["amp_a"]
    icicle = xml_of(amp_a, path)
    found, refused = expect("GEN-E073", amp_a, edited(icicle, set_way_mask({}, "DMA", 0xFFFF)))
    assert refused and ("error", "GEN-E073", "mss_memory_map/cache/WAY_MASK_DMA") in found
    found, refused = expect("GEN-E072", amp_a, edited(icicle, {(CACHE, "NUM_SCRATCH_PAD_WAYS", "NUM_OF_WAYS"): 12}))
    assert refused


@case("GEN-E085: a way mask without a cache way: none at all, a LIM way only (errors in dev too)")
def _():
    path, amp_a = SYSTEMS["amp_a"]
    icicle = xml_of(amp_a, path)
    found, refused = expect("GEN-E085", amp_a, edited(icicle, set_way_mask({}, "U54_3_ICACHE", 0)))
    assert refused and ("error", "GEN-E085", "mss_memory_map/cache/WAY_MASK_U54_3_ICACHE") in found
    expect("GEN-E085", amp_a, edited(icicle, set_way_mask({}, "DMA", 1 << 13)), name="E085-lim")


@case("GEN-E146, GEN-E147: amp_d's cache partitioning against the masks of the Icicle Kit (notes in dev, errors in "
      "prod); masks that implement it pass")
def _():
    path, amp_d = SYSTEMS["amp_d"]
    icicle = xml_of(amp_d, path)
    found, _ = expect("GEN-E146", amp_d, icicle, name="amp_d-E146")
    assert {code for _, code, _ in found} >= {"GEN-E146", "GEN-E147"}
    found, _ = expect("GEN-E147", as_profile(amp_d, "prod"), icicle, name="amp_d-E147")
    assert ("error", "GEN-E147", "l2.cache_partitioning") in found
    changes = {}
    for hart, mask in ((1, 0x3), (2, 0x3), (3, 0xC), (4, 0xC)):
        for master in waymask.masters_of(hart):
            set_way_mask(changes, master, mask)
    found, _ = agree(amp_d, edited(icicle, changes), name="amp_d-partitioned")
    assert not {code for _, code, _ in found} & {"GEN-E146", "GEN-E147"}, found


@case("GEN-E140 to GEN-E142: TOR and NA4 entries, a NAPOT entry with a clear bit among bits 8:0, an entry beyond "
      "the hardware (amp_c, prod)")
def _():
    expect("GEN-E140", AMP_C, edited(AMP_C_XML, set_mpu(set_mpu({}, "usb", 1, TOR | R, 0x4_0000), "scb", 7, NA4, 0)))
    expect("GEN-E141", AMP_C, edited(AMP_C_XML, set_mpu({}, "gem1", 2, NAPOT, napot(0x0800_0000, 0x100))))
    found, refused = expect("GEN-E142", AMP_C, with_register(AMP_C_XML, "mss_memory_map/mpu_trace", "MPU_CFG_PMP2",
                                                            (NAPOT | R) << 56 | 0x1FF))
    assert refused and ("error", "GEN-E142", "mss_memory_map/mpu_trace/MPU_CFG_PMP2") in found
    found, refused = agree(AMP_C, with_register(AMP_C_XML, "mss_memory_map/mpu_trace", "MPU_CFG_PMP2", 0x1FF),
                           name="E142-unused")
    assert not refused, found


@case("GEN-E143 to GEN-E145: an owned master beyond its owner's windows, a master without an owner, an entry over "
      "the whole space (amp_c, prod; the SCB not checked)")
def _():
    owned = owning(AMP_C, 3, "mac0")                     # app_a owns GEM0
    data = next(w for w in AMP_C_DERIVED.windows if w.owners == ("app_a",))
    mine = set_mpu({}, "gem0", 0, NAPOT | R | W, napot(data.origin, data.length))
    found, _ = agree(owned, edited(AMP_C_XML, mine), name="E143-own")
    assert not {code for _, code, _ in found} & set(checks.SEPARATION_CODES), found
    other = next(w for w in AMP_C_DERIVED.windows if w.owners == ("app_b",))
    found, refused = expect("GEN-E143", owned, edited(AMP_C_XML, set_mpu(mine, "gem0", 5, L | NAPOT | R,
                                                                         napot(other.origin, 0x1000))))
    assert refused and ("error", "GEN-E143", "mss_memory_map/mpu_gem0") in found
    expect("GEN-E144", AMP_C, edited(AMP_C_XML, set_mpu({}, "fic2", 0, NAPOT | W, napot(0x0800_0000, 0x1000))))
    found, _ = expect("GEN-E145", owned, edited(AMP_C_XML, set_mpu({}, "gem0", 7, NAPOT | R | W | X, (1 << 36) - 1)))
    assert {code for _, code, _ in found} >= {"GEN-E143", "GEN-E145"}, found
    found, refused = agree(AMP_C, edited(AMP_C_XML, set_mpu({}, "scb", 0, NAPOT | R | W | X, (1 << 36) - 1)),
                           name="scb-open")
    assert not refused, found


@case("the open MPUs of the XML of the Icicle Kit in dev and prod, with USB and the crypto processor owned: the same "
      "notes and errors")
def _():
    path, amp_a = SYSTEMS["amp_a"]
    for profile in ("dev", "prod"):
        found, _ = agree(as_profile(owning(amp_a, 2, "usb", "athena"), profile), xml_of(amp_a, path),
                         name=f"open-mpu-{profile}")
        codes = collections.Counter(code for _, code, _ in found)
        assert codes["GEN-E145"] == 9 and codes["GEN-E144"] == 7 and codes["GEN-E143"] == 2, codes


@case("every code the checker evaluates is reported by both somewhere")
def _():
    assert covered >= COVERED, sorted(COVERED - covered)


# --- random configurations ---------------------------------------------------------------------------------

def pool_of(d):
    """The addresses a random entry draws from: the bounds of what the derived system <d> has, and a few more."""
    out = {0, 0x1000, 0x0200_0000, 0x2000_0000, 0x2800_0000, 0x3000_0000, 0x4000_0000}
    for w in d.windows:
        out |= {w.origin, w.end}
    for p in d.partitions:
        out |= {b.base for b in p.blocks} | {b.base + b.length for b in p.blocks}
    out |= {b.base for b in d.protection.critical} | {d.protection.mtime.base}
    out |= {m.origin for m in d.memories} | {m.end for m in d.memories}
    out |= {b.base for b in contexts.bus_blocks(BLOCKS, "HI")}
    return sorted(out)


BASES = [("amp_c", AMP_C, AMP_C_XML), ("amp_a", SYSTEMS["amp_a"][1], xml_of(SYSTEMS["amp_a"][1], SYSTEMS["amp_a"][0])),
         ("pmp_demo", DEMO, CONFIGS["icicle_es_pmp_demo"])]
POOLS = {name: pool_of(derive.derive(as_profile(s, "dev"), c, SVD)) for name, s, c in BASES}
DEMO_CONTEXTS = {"A": ((1, 2), ("MMUART1", "MMUART2")), "B": ((3, 4), ("MMUART3", "MMUART4"))}


def random_entry(rnd, pool):
    mode = rnd.choices((OFF, TOR, NA4, NAPOT), (1, 3, 1, 5))[0]
    rights = rnd.randrange(8)
    if rights & W and not rights & R and rnd.random() < 0.95:
        rights |= R
    cfg = mode | rights | (L if rnd.random() < 0.5 else 0) | (0x20 if rnd.random() < 0.01 else 0)
    at = rnd.choice(pool)
    if mode == NAPOT:
        if rnd.random() < 0.03:
            return cfg, ALL_ONES
        size = 1 << rnd.randint(3, 28)
        return cfg, napot(at & ~(size - 1), size)
    return cfg, (at >> 2) + rnd.choice((0, 0, 0, 1, -1 if at else 0))


def small_change(rnd):
    """amp_c (which passes) with one small change: none, the pmpaddr of an entry that is OFF, the pmpaddr or the
    rights of one locked entry, or the 8 entries of QEMU; so that the draw has systems on both sides of the
    verdict."""
    hart = rnd.randrange(5)
    t = table(AMP_C_XML, hart)
    what = rnd.randrange(5)
    if what == 1:
        off = [i for i, (cfg, _) in enumerate(t) if cfg >> 3 & 3 == 0 and not cfg & L]
        i = rnd.choice(off)
        t[i] = (t[i][0], rnd.choice(POOLS["amp_c"]) >> 2)
    elif what in (2, 3):
        locked = [i for i, (cfg, _) in enumerate(t) if cfg & L]
        if locked:
            i = rnd.choice(locked)
            t[i] = (t[i][0], t[i][1] + rnd.choice((-1, 1, 0x400))) if what == 2 else \
                (t[i][0] & ~7 | rnd.randrange(8) & ~W | R, t[i][1])
    config = edited(AMP_C_XML, set_pmp({}, hart, t))
    profile = rnd.choice(("prod", "prod", "dev"))
    return as_profile(AMP_C, profile), config, 8 if what == 4 else 16


def random_case(rnd):
    """A random system and XML: a small change to amp_c, or a base with its profile, monitor and privileges
    changed, the PMP of each hart kept, mutated or drawn anew, the contexts and the way masks sometimes changed."""
    if rnd.random() < 0.25:
        return small_change(rnd)
    name, system, config = rnd.choice(BASES)
    pool = POOLS[name]
    parts = []
    monitor = rnd.randrange(len(system.partitions) + 2)
    for i, p in enumerate(system.partitions):
        priv = p.priv if rnd.random() < 0.85 else ("m" if p.priv == "u" else "u")
        parts.append(dataclasses.replace(p, monitor=i == monitor, priv=priv))
    system = dataclasses.replace(system, partitions=tuple(parts),
                                 security_profile=rnd.choice(("prod", "prod", "dev")))
    changes = {}
    for hart in range(5):
        t = table(config, hart)
        how = rnd.random()
        if how < 0.3:
            continue
        if how < 0.7:
            for _ in range(rnd.randint(1, 3)):
                t[rnd.randrange(16)] = random_entry(rnd, pool)
        else:
            t = [random_entry(rnd, pool) for _ in range(rnd.randint(0, 12))]
            if rnd.random() < 0.5:
                t.sort(key=lambda e: not e[0] & L)       # locked first, as a user would
        set_pmp(changes, hart, t)
    if rnd.random() < 0.3:
        changes[(APB, "MEM_CONFIGS_ENABLED", "PMP")] = rnd.randrange(2)
    if rnd.random() < 0.15 and name != "amp_c":
        a, b = rnd.sample(((1, 2), (3, 4), (2, 3), ()), 2)
        for reg, on in (("CONTEXT_A_HART_EN", a), ("CONTEXT_B_HART_EN", b)):
            changes.update({(APB, reg, f"HART{h}"): int(h in on) for h in range(5)})
    if rnd.random() < 0.05:
        set_way_mask(changes, rnd.choice(waymask.MASTERS), rnd.randrange(1 << 16))
    system, config = random_separation(rnd, name, system, config, changes, pool)
    entries = 8 if rnd.random() < 0.2 else 16
    return system, config, entries


MASTERS = tuple(target.MPU_ENTRIES)
OWNABLE = ("fic0", "fic1", "fic2", "athena", "mac0", "mac1", "usb", "mmc")


def random_mpu_entry(rnd, pool):
    """A random entry of an MPU: its mode byte and PMP field (NAPOT mostly; a region at a bound of the system, a
    small one whose bits 8:0 the MPU sets, or all ones)."""
    mode = rnd.choices((OFF, TOR, NA4, NAPOT), (2, 1, 1, 6))[0]
    cfg = mode | rnd.randrange(8) | (L if rnd.random() < 0.2 else 0)
    how = rnd.random()
    if how < 0.1:
        return cfg, (1 << 36) - 1
    at = rnd.choice(pool)
    size = 1 << rnd.randint(8 if how < 0.2 else 12, 24)
    return cfg, napot(at & ~(size - 1), size) & ((1 << 36) - 1)


def random_separation(rnd, name, system, config, changes, pool):
    """<system> and <config> with <changes> and, at random: the MPUs closed, entries of a few masters drawn, an
    entry beyond the hardware, DMA masters given to a partition, the cache partitioning of system.yaml and way
    masks that follow it or not."""
    if rnd.random() < 0.4:
        changes = mpu_off(config, changes)
    for _ in range(rnd.choice((0, 0, 1, 2, 3))):
        master = rnd.choice(MASTERS)
        for _ in range(rnd.randint(1, 3)):
            set_mpu(changes, master, rnd.randrange(target.MPU_ENTRIES[master]), *random_mpu_entry(rnd, pool))
    if rnd.random() < 0.3:
        owner = rnd.randrange(len(system.partitions))
        taken = {p for part in system.partitions for p in part.peripherals}
        free = [p for p in OWNABLE if p not in taken]
        system = owning(system, owner, *rnd.sample(free, rnd.randint(1, 2)))
    if rnd.random() < 0.25:
        harts = sorted({h for p in system.partitions for h in p.harts})
        chosen = rnd.sample(harts, rnd.randint(1, len(harts)))
        cache = CACHE_WAYS[name]
        plan = tuple((waymask.HART_KEYS[h], tuple(sorted(rnd.sample(range(cache), rnd.randint(1, cache)))))
                     for h in sorted(chosen))
        system = dataclasses.replace(system, l2=dataclasses.replace(system.l2, cache_partitioning=plan))
        if rnd.random() < 0.6:
            for key, ways in plan:
                for master in waymask.masters_of(waymask.HART_KEYS.index(key)):
                    set_way_mask(changes, master, sum(1 << w for w in ways))
    config = edited(config, changes)
    if rnd.random() < 0.03:
        master = rnd.choice(MASTERS)
        mode, field = random_mpu_entry(rnd, pool)
        config = with_register(config, f"mss_memory_map/mpu_{master}",
                               f"MPU_CFG_PMP{target.MPU_ENTRIES[master] + rnd.randrange(3)}", mode << 56 | field)
    return system, config


# The cache ways of the split of the XML of each base (the ways a mask is checked against).
CACHE_WAYS = {name: derive.derive(as_profile(s, "dev"), c, SVD, strict=False).l2.xml_ways.cache for name, s, c in BASES}


# The rules of the MPU and the way masks that the random draw must make fire (and so compare) somewhere.
DRAWN = {"GEN-E073", "GEN-E085"} | set(checks.SEPARATION_CODES)


@case(f"{CASES} random configurations (seed {SEED}): the same findings and verdict in every one")
def _():
    rnd = random.Random(SEED)
    tally = collections.Counter()
    fired = collections.Counter()
    for n in range(CASES):
        system, config, entries = random_case(rnd)
        try:
            found, refused = agree(system, config, entries, name=f"random-{n}")
        except AssertionError as err:
            raise AssertionError(f"case {n} of seed {SEED}: {err}") from None
        tally[(system.security_profile, "refused" if refused else "accepted")] += 1
        fired.update({code for _, code, _ in found})
    print(f"      verdicts: {dict(sorted(tally.items()))}")
    print(f"      draws in which a rule of the MPU or the way masks fired: "
          f"{dict(sorted((c, k) for c, k in fired.items() if c in DRAWN))}")
    assert sum(tally.values()) == CASES
    if CASES >= 1000:
        assert tally[("prod", "refused")] > 100 and tally[("dev", "accepted")] > 100, tally
        assert tally[("prod", "accepted")] > 0, "no random prod system passes: the draw tests refusals only"
        assert all(fired[code] for code in DRAWN), sorted(code for code in DRAWN if not fired[code])



# --- the reader of the check input --------------------------------------------------------------------------

def run_text(text, name):
    path = TMP / name
    path.write_text(text, encoding="utf-8")
    return subprocess.run([str(CHECKER), str(path)], capture_output=True, text=True, check=False)


@case("a malformed check input is refused with status 2 and a message, not checked")
def _():
    good = json.loads(system_json.text(system_json.check_input(AMP_C_DERIVED, AMP_C_XML, BLOCKS)))

    def changed(fn):
        data = json.loads(json.dumps(good))
        fn(data)
        return json.dumps(data)

    bad = {
        "not JSON": "{",
        "trailing text": json.dumps(good) + " x",
        "a version 2": changed(lambda d: d.update(version=2)),
        "no pmp": changed(lambda d: d.pop("pmp")),
        "a hart missing": changed(lambda d: d["pmp"]["harts"].pop()),
        "15 configuration bytes": changed(lambda d: d["pmp"]["harts"][1]["cfg"].pop()),
        "a configuration byte of 256": changed(lambda d: d["pmp"]["harts"][1]["cfg"].__setitem__(0, 256)),
        "a range beyond 2 ** 56": changed(lambda d: d["mtime"].update(base=1 << 56)),
        "a range of no byte": changed(lambda d: d["mtime"].update(length=0)),
        "an unknown owner": changed(lambda d: d["windows"][0].__setitem__("owners", ["nobody"])),
        "a profile test": changed(lambda d: d.update(security_profile="test")),
        "a negative number": changed(lambda d: d.update(version=-1)),
        "a number above 2 ** 64": json.dumps(good).replace('"version": 1', '"version": 18446744073709551616'),
        "an escape in a string": json.dumps(good).replace('"io"', '"i\\u006f"'),
        "nested too deep": "[" * 40 + "]" * 40,
        "no mpu": changed(lambda d: d.pop("mpu")),
        "an unknown master": changed(lambda d: d["mpu"]["masters"][0].update(master="pdma")),
        "a master missing": changed(lambda d: d["mpu"]["masters"].pop()),
        "a master twice": changed(lambda d: d["mpu"]["masters"].append(d["mpu"]["masters"][0])),
        "an owner that is no partition": changed(lambda d: d["mpu"]["masters"][4].update(owner="nobody")),
        "MPU entries out of order": changed(lambda d: d["mpu"]["masters"][0]["entries"].reverse()),
        "no cache_partitioning": changed(lambda d: d["l2"].pop("cache_partitioning")),
        "a way 16": changed(lambda d: d["l2"].update(cache_partitioning=[{"hart": 1, "ways": [16]}])),
    }
    for what, text in bad.items():
        run = run_text(text, "bad.json")
        assert run.returncode == 2 and run.stderr.startswith("pmp_check: "), (what, run.returncode, run.stderr)
    assert run_text(json.dumps(good), "good.json").returncode == 0
    assert subprocess.run([str(CHECKER)], capture_output=True, check=False).returncode == 2
    assert subprocess.run([str(CHECKER), str(TMP / "missing.json")], capture_output=True, check=False).returncode == 2


# --- the command line ---------------------------------------------------------------------------------------

def gen(*args):
    return subprocess.run([sys.executable, str(ROOT / "config" / "gen" / "mpfs_gen"), *map(str, args)],
                          capture_output=True, text=True, check=False, cwd=ROOT)


@case("derive --check-json: writes the check input, byte for byte the same each time; for a refused system too "
      "(status 2); one description only")
def _():
    out = TMP / "amp_c.json"
    first = gen("derive", "--check-json", out, "--svd", SVD, AMP_C_PATH)
    assert first.returncode == 0 and first.stdout.startswith(f"{AMP_C_PATH}: ok"), first
    text = out.read_text(encoding="utf-8")
    assert gen("derive", "--check-json", out, "--svd", SVD, AMP_C_PATH).returncode == 0
    assert out.read_text(encoding="utf-8") == text
    assert text == system_json.text(json.loads(text)), "canonical: sorted keys, indent 1, a newline at the end"
    data = json.loads(text)
    assert data["version"] == 1 and data["security_profile"] == "prod" and data["pmp"]["entries"] == 16
    assert [h["hart"] for h in data["pmp"]["harts"]] == [0, 1, 2, 3, 4]
    assert [len(h["generated"]) for h in data["pmp"]["harts"]] == [5, 4, 6, 5, 4]
    assert [m["master"] for m in data["mpu"]["masters"]] == list(target.MPU_ENTRIES)
    assert [len(m["entries"]) for m in data["mpu"]["masters"]] == list(target.MPU_ENTRIES.values())
    assert data["l2"]["cache_partitioning"] == [] and data["mpu"]["enabled"] is True
    assert subprocess.run([str(CHECKER), str(out)], capture_output=True, check=False).returncode == 0

    prod = TMP / "amp_a_prod.yaml"
    prod.write_text(SYSTEMS["amp_a"][0].read_text(encoding="utf-8").replace("security_profile: dev",
                                                                            "security_profile: prod"))
    refused = TMP / "amp_a_prod.json"
    run = gen("derive", "--check-json", refused, "--svd", SVD, prod)
    assert run.returncode == 2 and "GEN-E105" in run.stderr and refused.is_file(), run
    assert subprocess.run([str(CHECKER), str(refused)], capture_output=True, check=False).returncode == 1
    two = gen("derive", "--check-json", out, "--svd", SVD, AMP_C_PATH, AMP_C_PATH)
    assert two.returncode == 2 and "one FILE" in two.stderr, two


finish()
