# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# @verifies GEN-017, GEN-018
"""config/gen/mpfs_gen/derive/mpu.py and derive/waymask.py: the MPU of each DMA master decoded from the XML and
checked against the partitions, and the way masks checked against l2.cache_partitioning; the reference XMLs, the
security profiles and a negative case for every code of them (GEN-E140 on). Needs the merged SVD (tools/svd.py
ensure).

A case changes the XML in the model (fields of registers, the value of the register recomputed as the reader
does) or the description. The XML of the Icicle Kit has every MPU open; most cases close them all first
(mpu_off) and open what they test. The PMP of that XML fails the checks of a prod system, so the cases of the
rules take a dev system and compare the notes of the MPU and the cache partitioning (checks.SEPARATION_CODES);
the prod cases take amp_c with its own XML, whose PMP passes."""
import dataclasses
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent.parent
sys.path[:0] = [str(HERE.parent / "gen_ada"), str(ROOT / "config" / "gen"), str(ROOT / "tools")]

from gen_ada import svdread
from harness import case, finish
from mpfs_gen import checks, derive, target, xml_reader, yaml_reader
from mpfs_gen.checks import DerivationError
from mpfs_gen.derive import mpu, waymask

SVD = svdread.ensure(ROOT)
LAYOUT = xml_reader.svd_layout(SVD)
BOARDS = ROOT / "config" / "boards"
XMLS = {p.parent.name: p for p in sorted(BOARDS.glob("*/*.xml"))}
CONFIGS = {board: xml_reader.read(path, SVD) for board, path in XMLS.items()}
ICICLE = CONFIGS["icicle"]
AMP_C_PATH = ROOT / "systems" / "amp_c" / "system.yaml"
AMP_C = yaml_reader.read(AMP_C_PATH)
AMP_C_XML = CONFIGS["icicle_amp_c"]
CACHE = "mss_memory_map/cache"
R, W, X, L = 0x01, 0x02, 0x04, 0x80
OFF, TOR, NA4, NAPOT = 0x00, 0x08, 0x10, 0x18
ALL = (1 << 36) - 1
covered: set[str] = set()

ONE = """schema: 1
board: icicle
partitions:
  - name: a
    harts: [1]
    profile: light
    memory:
      code: { region: lim, size: 64K }
      data: { region: lim, size: 64K }
    peripherals: [mmuart1, mac0]
  - name: b
    harts: [3]
    profile: light
    memory:
      code: { region: lim, size: 64K }
      data: { region: lim, size: 64K }
    peripherals: [mmuart3]
ipc:
  - { name: ab, between: [a, b], size: 16K }
"""


def text(description):
    return yaml_reader.read_text(description, "test.yaml")


def edited(config, changes):
    """<config> with the fields of {(section, register, field): value} changed and the values of their registers
    recomputed (the RW fields at their offsets)."""
    registers = []
    for reg in config.registers:
        fields = tuple(dataclasses.replace(f, value=changes[(reg.section, reg.name, f.name)])
                       if (reg.section, reg.name, f.name) in changes else f for f in reg.fields)
        value = sum(f.value << f.bits.offset for f in fields if f.access == "RW" and f.value is not None)
        registers.append(dataclasses.replace(reg, fields=fields, value=value))
    keys = {(r.section, r.name, f.name) for r in registers for f in r.fields}
    assert set(changes) <= keys, set(changes) - keys
    return dataclasses.replace(config, registers=tuple(registers))


def mpu_off(config=ICICLE, changes=None):
    """The changes that turn every MPU entry of <config> OFF (mode 0, the PMP field 0x1FF as the Configurator
    writes an unused entry), with <changes> on top."""
    out = {}
    for reg in config.registers:
        if reg.section.startswith("mss_memory_map/mpu_"):
            out[(reg.section, reg.name, "MODE")] = 0
            out[(reg.section, reg.name, "PMP")] = 0x1FF
    out.update(changes or {})
    return out


def entry(master, index, mode, pmp_field):
    section = f"mss_memory_map/mpu_{master}"
    return {(section, f"MPU_CFG_PMP{index}", "MODE"): mode, (section, f"MPU_CFG_PMP{index}", "PMP"): pmp_field}


def napot(first, size):
    return (first >> 2) | ((size >> 3) - 1)


def separation(sys_, config):
    """The findings of the MPU and the cache partitioning: (severity, code) in the order reported, and the text."""
    d = derive.derive(sys_, config, SVD, strict=False)
    found = [("error", f) for f in d.errors] + [("warning", f) for f in d.warnings] + [("note", f) for f in d.notes]
    mine = [(sev, f) for sev, f in found if f.code in checks.SEPARATION_CODES]
    return [(sev, f.code) for sev, f in mine], "\n".join(str(f) for _, f in mine), d


def expect(expected, sys_, config, *words):
    """The MPU and the cache partitioning give exactly the codes <expected> (as notes for dev, errors for prod)."""
    got, message, d = separation(sys_, config)
    sev = "error" if sys_.security_profile == "prod" else "note"
    assert got == [(sev, code) for code in expected], (got, message)
    for word in words:
        assert word in message, (word, message)
    covered.update(expected)
    return d


# --- the decoding -------------------------------------------------------------------------------------------

@case("the entries per master are those of MSS TRM Table 3-40, the SVD has as many, and every reference XML has "
      "a register for each")
def _():
    assert target.MPU_ENTRIES == {"fic0": 16, "fic1": 16, "fic2": 8, "crypto": 4, "gem0": 8, "gem1": 8, "usb": 4,
                                  "mmc": 4, "scb": 8, "trace": 2}
    for master, count in target.MPU_ENTRIES.items():
        name = xml_reader.MPU_MASTERS[master]
        svd = [r for p, r in LAYOUT if p == "MPUCFG" and r.startswith(f"PMPCFG_{name}_")]
        assert len(svd) == count, (master, svd)
        for board, config in CONFIGS.items():
            m = derive.derive(text(ONE), config, SVD, strict=False).mpu.master(master) \
                if board in ("icicle", "icicle_es") else None
            assert len(config.section(f"mss_memory_map/mpu_{master}")) == count, (board, master)
            assert m is None or [e.index for e in m.table] == list(range(count))


@case("an entry decoded: bits 35:0 address bits 37:2 with bits 8:0 hardwired to 1, bits 63:56 the mode (L, the "
      "address mode, X, W, R); all ones is the whole 2^38 bytes")
def _():
    def e(mode, field):
        return mpu.MpuEntry(0, mode << 56 | field)
    whole = e(NAPOT | R | W | X, ALL)
    assert (whole.mode, whole.rights, whole.locked, whole.region) == ("NAPOT", "rwx", False, (0, (1 << 38) - 1))
    amp_c_gem0 = e(NAPOT, 0x0380001FF)
    assert amp_c_gem0.region == (0xE000_0000, 0xE000_0FFF) and amp_c_gem0.rights == "---"
    assert e(NAPOT | R, napot(0x0800_0000, 0x1_0000)).region == (0x0800_0000, 0x0800_FFFF)
    # bits 8:0 clear: the MPU sets them, the region is 4 KiB at least
    assert e(NAPOT | R, napot(0x0800_0000, 0x100)).region == (0x0800_0000, 0x0800_0FFF)
    assert e(L | NAPOT | W | R, 0x1FF).locked and e(L | NAPOT | W | R, 0x1FF).rights == "rw-"
    # TOR and NA4 are off for the MPU
    assert e(TOR | R, 0x1FF).region is None and e(NA4 | R, 0x1FF).region is None and e(OFF, 0x1FF).region is None
    assert mpu.outside(0, 99, [(10, 19), (20, 29), (50, 59)]) == [(0, 9), (30, 49), (60, 99)]
    assert mpu.outside(10, 19, [(0, 99)]) == [] and mpu.outside(10, 19, []) == [(10, 19)]


@case("the reference XMLs: the boards open every MPU (all masters reach the whole space, the SCB bypasses its "
      "MPU); amp_c's XML has three NAPOT entries without a right and passes, also in prod; "
      "MEM_CONFIGS_ENABLED.MPU is shown, not relied upon")
def _():
    for board in ("icicle", "icicle_es", "video_kit", "icicle_es_pmp_demo"):
        got, message, d = separation(text(ONE), CONFIGS[board])
        codes = [c for _, c in got]
        # fic0, fic1, fic2, crypto; gem0, owned by 'a' through mac0; gem1, usb, mmc, trace
        assert codes == ["GEN-E145", "GEN-E144"] * 4 + ["GEN-E145", "GEN-E143"] + ["GEN-E145", "GEN-E144"] * 4, \
            (board, codes)
        assert "GEN-E145 mss_memory_map/mpu_fic0: FIC0 reaches the whole address space through entries 0, 1, 2, 3, " \
               "4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15" in message
        assert "GEN-E143 mss_memory_map/mpu_gem0: GEM0, owned by 'a', reaches [0x0, " in message
        assert "mpu_scb" not in message and d.mpu.master("scb").bypass
        assert d.mpu.enabled == (board == "icicle_es_pmp_demo")
    got, message, d = separation(AMP_C, AMP_C_XML)
    assert got == [] and AMP_C.security_profile == "prod" and d.errors == ()
    assert d.mpu.enabled and [len(m.reach()) for m in d.mpu.masters] == [0, 0, 0, 0, 0, 0, 0, 0, 8, 0]
    used = {m.master: [(e.index, e.mode, e.region, e.rights) for e in m.table if e.mode != "OFF"]
            for m in d.mpu.masters if m.master in ("gem0", "usb", "mmc")}
    assert used == {"gem0": [(0, "NAPOT", (0xE000_0000, 0xE000_0FFF), "---")],
                    "usb": [(0, "NAPOT", (0xC000_0000, 0xC000_0FFF), "---")],
                    "mmc": [(0, "NAPOT", (0x14_0000_0000, 0x14_0000_0FFF), "---")]}, used


@case("the profiles: the MPU is in the derived system and the check input in both; its findings are notes in dev "
      "and errors in prod (amp_c with FIC0 opened)")
def _():
    opened = edited(AMP_C_XML, entry("fic0", 3, NAPOT | R | W, ALL))
    d = expect(["GEN-E145", "GEN-E144"], AMP_C, opened, "through entry 3", "FIC0, which no partition owns, reaches "
               "[0x0, 0x3fffffffff] (entry 3)")
    assert d.mpu.master("fic0").table[3].value == (NAPOT | R | W) << 56 | ALL
    try:
        derive.derive(AMP_C, opened, SVD)
        raise AssertionError("amp_c with an open FIC0 is not refused")
    except DerivationError as err:
        assert [c for c in err.codes if c in checks.SEPARATION_CODES] == ["GEN-E145", "GEN-E144"], err.codes
    dev = dataclasses.replace(AMP_C, security_profile="dev")
    d = expect(["GEN-E145", "GEN-E144"], dev, opened)
    assert d.errors == () and d.mpu.master("fic0").table[3].rights == "rw-"


# --- one case per rule ------------------------------------------------------------------------------------------

@case("GEN-E140: TOR and NA4 entries, which the MPU takes as off (and which grant nothing)")
def _():
    config = edited(ICICLE, mpu_off(changes={**entry("usb", 1, TOR | R, 0x4_0000), **entry("mmc", 0, NA4 | R | W, 0)}))
    expect(["GEN-E140", "GEN-E140"], text(ONE), config, "mss_memory_map/mpu_usb/MPU_CFG_PMP1: entry 1 of USB is TOR",
           "mpu_mmc/MPU_CFG_PMP0")


@case("GEN-E141: a NAPOT entry with a clear bit among address bits 8:0 (a region of 256 bytes in the XML)")
def _():
    d = derive.derive(dataclasses.replace(text(ONE), security_profile="dev"), ICICLE, SVD)
    data = next(w for w in d.windows if w.owners == ("a",) and w.kind == "code+data")
    small = napot(data.origin, 0x100)
    config = edited(ICICLE, mpu_off(changes=entry("gem0", 2, NAPOT | R | W, small)))
    expect(["GEN-E141"], text(ONE), config, f"has the PMP field {small:#011x}",
           f"matches [{data.origin:#x}, {data.origin + 0xFFF:#x}]")


@case("GEN-E142: an entry in use beyond the entries of its master (a register the XML adds to FIC2, which has 8)")
def _():
    base = edited(ICICLE, mpu_off())
    seven = base.register("mss_memory_map/mpu_fic2", "MPU_CFG_PMP7")
    extra = dataclasses.replace(seven, name="MPU_CFG_PMP8", value=(NAPOT | R) << 56 | ALL)
    config = dataclasses.replace(base, registers=base.registers + (extra,))
    expect(["GEN-E142"], text(ONE), config, "entry 8 of FIC2 is in use (0x19); FIC2 has 8 entries (0 to 7)")
    unused = dataclasses.replace(extra, value=0x1FF)
    expect([], text(ONE), dataclasses.replace(base, registers=base.registers + (unused,)))


@case("GEN-E143: a master owned by a partition (GEM0 by its peripheral mac0) reaches only the windows of its "
      "owner: its code+data window and its channel pass, the other partition's window and more do not")
def _():
    d = derive.derive(dataclasses.replace(text(ONE), security_profile="dev"), ICICLE, SVD)
    mine = next(w for w in d.windows if w.owners == ("a",))
    channel = next(w for w in d.windows if w.channel == "ab")
    theirs = next(w for w in d.windows if w.owners == ("b",))
    assert mine.length == 0x2_0000 and channel.length == 0x4000
    ok = {**entry("gem0", 0, NAPOT | R | W, napot(mine.origin, mine.length)),
          **entry("gem0", 1, L | NAPOT | R | W, napot(channel.origin, channel.length)),
          **entry("gem0", 2, NAPOT, napot(theirs.origin, theirs.length))}       # no right: reaches nothing
    expect([], text(ONE), edited(ICICLE, mpu_off(changes=ok)))
    bad = {**ok, **entry("gem0", 5, NAPOT | R, napot(theirs.origin, 0x1000))}
    expect(["GEN-E143"], text(ONE), edited(ICICLE, mpu_off(changes=bad)),
           f"GEM0, owned by 'a', reaches [{theirs.origin:#x}, {theirs.origin + 0xFFF:#x}] outside the windows of 'a' "
           "(entries 0, 1, 5)")
    # the crypto processor is owned through athena; a partition without it leaves CRYPTO without an owner
    crypto = entry("crypto", 0, NAPOT | R | W, napot(mine.origin, mine.length))
    owned = text(ONE.replace("[mmuart1, mac0]", "[mmuart1, mac0, athena]"))
    expect([], owned, edited(ICICLE, mpu_off(changes=crypto)))
    expect(["GEN-E144"], text(ONE), edited(ICICLE, mpu_off(changes=crypto)), "CRYPTO, which no partition owns")


@case("GEN-E144: a master that no partition owns reaches something (the trace; the SCB bypasses its MPU and is "
      "not checked)")
def _():
    trace = entry("trace", 1, NAPOT | R, napot(0x0800_0000, 0x1000))
    expect(["GEN-E144"], text(ONE), edited(ICICLE, mpu_off(changes=trace)),
           "TRACE, which no partition owns, reaches [0x8000000, 0x8000fff] (entry 1)")
    scb = entry("scb", 0, NAPOT | R | W | X, ALL)
    expect([], text(ONE), edited(ICICLE, mpu_off(changes=scb)))


@case("GEN-E145: an entry over the whole address space, of an owned master too")
def _():
    expect(["GEN-E145", "GEN-E143"], text(ONE), edited(ICICLE, mpu_off(changes=entry("gem0", 7, L | NAPOT | R, ALL))),
           "GEM0 reaches the whole address space through entry 7")


@case("GEN-E146, GEN-E147: l2.cache_partitioning against the way masks of the XML; amp_d with the XML of the "
      "Icicle Kit, whose masks give every master the cache ways 0 to 7")
def _():
    amp_d = yaml_reader.read(ROOT / "systems" / "amp_d" / "system.yaml")
    got, message, _ = separation(amp_d, ICICLE)
    codes = [c for sev, c in got if sev == "note"]
    assert codes.count("GEN-E146") == 8 and codes.count("GEN-E147") == 4, got
    assert "GEN-E146 mss_memory_map/cache/WAY_MASK_U54_1_DCACHE: cache ways [0, 1, 2, 3, 4, 5, 6, 7]; " \
           "l2.cache_partitioning.u54_1 gives [0, 1]" in message
    assert "GEN-E147 l2.cache_partitioning: hart 1 ('app') and hart 3 ('rt') share the cache ways " \
           "[0, 1, 2, 3, 4, 5, 6, 7] in the way masks of the XML" in message
    covered.update(("GEN-E146", "GEN-E147"))
    # the masks as amp_d partitions the cache: nothing; with the ways of a hart of each partition shared: GEN-E147
    masks = {}
    for hart, mask in ((1, 0x3), (2, 0x3), (3, 0xC), (4, 0xC)):
        for master in waymask.masters_of(hart):
            masks.update({(CACHE, f"WAY_MASK_{master}", f"WAY_MASK_{i}"): mask >> i & 1 for i in range(16)})
    config = edited(ICICLE, mpu_off(changes=masks))
    expect([], amp_d, config)
    one = dataclasses.replace(amp_d.l2, cache_partitioning=(("u54_1", (0, 1)),))
    expect(["GEN-E147", "GEN-E147"], dataclasses.replace(amp_d, l2=one),
           edited(config, {(CACHE, "WAY_MASK_U54_3_ICACHE", "WAY_MASK_1"): 1}), "hart 1 ('app') and hart 3 ('rt') "
           "share the cache ways [1]", "hart 2 ('app') and hart 3 ('rt')")
    # without l2.cache_partitioning the masks are not compared
    expect([], dataclasses.replace(amp_d, l2=dataclasses.replace(amp_d.l2, cache_partitioning=())), edited(ICICLE, mpu_off()))
    # in prod they are errors
    prod = dataclasses.replace(amp_d, security_profile="prod")
    got, _, _ = separation(prod, edited(config, {(CACHE, "WAY_MASK_U54_2_DCACHE", "WAY_MASK_2"): 1}))
    assert ("error", "GEN-E146") in got and ("error", "GEN-E147") in got, got


@case("every code of the MPU and the cache partitioning has a negative case, and the codes are in the table of "
      "config/README.md")
def _():
    assert covered == set(checks.SEPARATION_CODES), sorted(covered ^ set(checks.SEPARATION_CODES))
    readme = (ROOT / "config" / "README.md").read_text()
    for code in sorted(checks.SEPARATION_CODES):
        assert f"| `{code}` | {checks.CODES[code]} |" in readme, code


finish()
