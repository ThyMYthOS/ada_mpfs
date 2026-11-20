# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# @verifies GEN-010, GEN-011
"""config/gen/mpfs_gen/pmp.py: the PMP of the reference XMLs, the regions of the entries, the rules of their
layout, a negative case for every code of the PMP sections, the Ada table of examples/pmp_xml_test and the
command line; and that the emulator lists run the PMP test programs. Needs the merged SVD (tools/svd.py
ensure)."""
import dataclasses
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent.parent
sys.path[:0] = [str(HERE.parent / "gen_ada"), str(ROOT / "config" / "gen"), str(ROOT / "tools")]

from gen_ada import svdread
from harness import case, finish
from mpfs_gen import checks, pmp, xml_reader

SVD = svdread.ensure(ROOT)
BOARDS = ROOT / "config" / "boards"
XMLS = {p.parent.name: p for p in sorted(BOARDS.glob("*/*.xml"))}
CONFIGS = {board: xml_reader.read(path, SVD) for board, path in XMLS.items()}
ICICLE_XML = "config/boards/icicle/ICICLE_MSS_mss_cfg.xml"
TABLE = ROOT / "examples" / "pmp_xml_test" / "src" / "generated" / "pmp_xml.ads"
GEN = [sys.executable, "-I", str(ROOT / "config" / "gen" / "mpfs_gen")]
covered: set[str] = set()


def with_cfg(config, hart, entry, value):
    """<config> with the configuration byte of <entry> of <hart> set to <value> (the field PMP<n>CFG of
    CSR_PMPCFG0 or 2, the register value recomputed from its RW fields as the reader does)."""
    section, name = pmp.SECTION.format(hart), f"CSR_PMPCFG{0 if entry < 8 else 2}"
    registers = []
    for reg in config.registers:
        if (reg.section, reg.name) == (section, name):
            fields = tuple(dataclasses.replace(f, value=value) if f.name == f"PMP{entry}CFG" else f
                           for f in reg.fields)
            reg = dataclasses.replace(reg, fields=fields, value=sum(
                f.value << f.bits.offset for f in fields if f.access == "RW" and f.value is not None))
        registers.append(reg)
    return dataclasses.replace(config, registers=tuple(registers))


def run(*args):
    return subprocess.run([*GEN, *args], cwd=ROOT, capture_output=True, text=True, check=False)


@case("every reference XML: no entry on the E51, entry 0 of each U54 locked NAPOT over all addresses, RWX")
def _():
    for board, config in CONFIGS.items():
        harts, found = pmp.of(config)
        assert found == [], (board, found)
        assert [h.hart for h in harts] == [0, 1, 2, 3, 4]
        assert all(e.mode == "OFF" for e in harts[0].entries), board
        for h in harts[1:]:
            first = h.entry(0)
            assert (first.mode, first.rights, first.locked) == ("NAPOT", "rwx", True), (board, h.hart)
            assert pmp.region(first, 0) == (0, (1 << 56) - 1)
            assert all(e.mode == "OFF" for e in h.entries[1:]), (board, h.hart)


@case("the regions of NAPOT, TOR and NA4 entries; OFF and an empty TOR range match nothing")
def _():
    napot = pmp.Entry(1, 0x18 | pmp.R, (0x0800_0000 | 0x7FF) >> 2)
    assert pmp.region(napot, 0) == (0x0800_0000, 0x0800_0FFF)        # 4 KiB at 0x0800_0000
    assert pmp.region(pmp.Entry(0, 0x18, 0x0800_0000 >> 2), 0) == (0x0800_0000, 0x0800_0007)   # 8 bytes
    tor = pmp.Entry(2, 0x08 | pmp.R | pmp.W, 0x0800_2000 >> 2)
    assert pmp.region(tor, 0x0800_0000 >> 2) == (0x0800_0000, 0x0800_1FFF)
    assert pmp.region(tor, 0x0800_2000 >> 2) is None
    assert pmp.region(pmp.Entry(3, 0x10 | pmp.R, 0x0800_2004 >> 2), 0) == (0x0800_2004, 0x0800_2007)
    assert pmp.region(pmp.Entry(4, 0, 0x1234), 0) is None
    assert (tor.mode, tor.rights, tor.locked) == ("TOR", "rw-", False)


@case("GEN-E100: an entry with W and without R is refused")
def _():
    _, found = pmp.of(with_cfg(CONFIGS["icicle"], 2, 3, 0x18 | pmp.W))
    assert [f.code for f in found] == ["GEN-E100"], found
    assert "pmp_h2/CSR_PMPCFG0.PMP3CFG" in found[0].path
    covered.add("GEN-E100")


@case("GEN-E101: a configuration byte with the reserved bits 5 and 6 is refused")
def _():
    _, found = pmp.of(with_cfg(CONFIGS["icicle"], 0, 9, 0x20 | 0x18 | pmp.R))
    assert [f.code for f in found] == ["GEN-E101"], found
    assert "pmp_h0/CSR_PMPCFG2.PMP9CFG" in found[0].path
    covered.add("GEN-E101")


def enabled(config):
    """<config> with MEM_CONFIGS_ENABLED.PMP 1."""
    registers = []
    for reg in config.registers:
        if (reg.section, reg.name) == (pmp.APB_SPLIT, "MEM_CONFIGS_ENABLED"):
            fields = tuple(dataclasses.replace(f, value=1) if f.name == "PMP" else f for f in reg.fields)
            reg = dataclasses.replace(reg, fields=fields, value=sum(f.value << f.bits.offset for f in fields))
        registers.append(reg)
    return dataclasses.replace(config, registers=tuple(registers))


def harts_with(hart, entries):
    """The PMP of the five harts, all OFF but <hart> with <entries> (cfg, pmpaddr) from entry 0."""
    entries = list(entries) + [(0, 0)] * (16 - len(entries))
    cfg0 = sum(c << (8 * i) for i, (c, _) in enumerate(entries[:8]))
    cfg2 = sum(c << (8 * i) for i, (c, _) in enumerate(entries[8:]))
    return tuple(pmp.HartPmp(h, cfg0, cfg2, tuple(a for _, a in entries)) if h == hart
                 else pmp.HartPmp(h, 0, 0, (0,) * 16) for h in range(5))


def rule_codes(harts, entries=16, config=None):
    found = pmp.rules(config or enabled(CONFIGS["icicle"]), harts, entries)
    return [f.code for f in found], " ".join(map(str, found))


@case("the rules of the layout hold for a layering of locked entries before unlocked ones within 8 entries")
def _():
    deny, allow = 0x98, 0x18 | pmp.R | pmp.W
    harts = harts_with(1, [(deny, 0x0800_7FFF >> 2), (0x00, 0x0802_0000 >> 2), (0x08 | 0x80, 0x0803_0000 >> 2),
                           (allow, 0x2010_07FF >> 2)])
    assert rule_codes(harts, 8) == ([], "")
    # the base of the locked TOR entry is in the locked part
    assert [e.index for e in pmp.locked_part(harts[1])] == [0, 1, 2]
    assert [e.index for e in pmp.unlocked_part(harts[1])] == [3]


@case("GEN-E102: a locked entry after an unlocked entry in use")
def _():
    codes, message = rule_codes(harts_with(3, [(0x18 | pmp.R, 0x2010_07FF >> 2), (0x98, 0x0800_7FFF >> 2)]))
    assert codes == ["GEN-E102"] and "entry 1 of hart 3 is locked, after the unlocked entry 0" in message, message
    covered.add("GEN-E102")


@case("GEN-E103: an entry beyond the 8 entries of QEMU; the 16 of the silicon hold it")
def _():
    harts = harts_with(2, [(0, 0)] * 9 + [(0x18 | pmp.R, 0x2010_07FF >> 2)])
    assert rule_codes(harts, 16) == ([], "")
    codes, message = rule_codes(harts, 8)
    assert codes == ["GEN-E103"] and "hart 2 uses entry 9; the target has 8 (0 to 7)" in message, message
    covered.add("GEN-E103")


@case("GEN-E104 and GEN-E105: the reference XMLs, MEM_CONFIGS_ENABLED.PMP 0 with the open, locked entry 0 of the "
      "U54 harts")
def _():
    for board, config in CONFIGS.items():
        harts, _ = pmp.of(config)
        found = pmp.rules(config, harts)
        assert [f.code for f in found] == ["GEN-E105"] * 4 + ["GEN-E104"], (board, found)
        assert found[0].path == "mss_memory_map/pmp_h1/PMP0CFG" and "over the whole address space" in found[0].message
        assert found[-1].warning and "pmp_h1, pmp_h2, pmp_h3, pmp_h4" in found[-1].message
    covered.update({"GEN-E104", "GEN-E105"})


@case("GEN-E105: a locked entry that grants rights over the range of a later entry hides it")
def _():
    codes, message = rule_codes(harts_with(4, [(0x98 | pmp.R, 0x0800_7FFF >> 2), (0x18 | pmp.R | pmp.W,
                                                                                    0x0800_03FF >> 2)]))
    assert codes == ["GEN-E105"] and "over [0x8000000, 0x800ffff], hiding entry 1" in message, message
    # without rights it is a deny entry, which may cover later entries
    assert rule_codes(harts_with(4, [(0x98, 0x0800_7FFF >> 2), (0x18 | pmp.R, 0x0800_03FF >> 2)]))[0] == []


@case("every code of the PMP sections has a negative case, and the codes are in the table of config/README.md")
def _():
    assert covered == set(checks.PMP_CODES), sorted(covered ^ set(checks.PMP_CODES))
    readme = (ROOT / "config" / "README.md").read_text()
    for code in checks.PMP_CODES:
        assert f"| `{code}` | {checks.CODES[code]} |" in readme, code


@case("the Ada table has every CSR of every hart, is the same twice, and the committed one is current")
def _():
    config = xml_reader.read(ROOT / ICICLE_XML, SVD, name=ICICLE_XML)
    text = pmp.ada_table(config, ICICLE_XML)
    assert text == pmp.ada_table(config, ICICLE_XML)
    assert "package Pmp_Xml with Pure is" in text and config.sha256 in text
    assert text.count("Cfg0 => ") == 5 and text.count("16#ffff_ffff_ffff_ffff#") == 4
    assert text.count("16#0000_0000_0000_009f#") == 4
    assert TABLE.read_text() == text, "run python3 config/gen/mpfs_gen pmp --ada " + str(TABLE.relative_to(ROOT))
    assert all(len(line) <= 79 for line in text.splitlines())


@case("pmp --check: 0 for the committed table, 1 and a diff for a stale one, 2 without --ada")
def _():
    rel = str(TABLE.relative_to(ROOT))
    ok = run("pmp", "--svd", str(SVD), "--check", "--ada", rel, ICICLE_XML)
    assert ok.returncode == 0, ok.stderr
    with tempfile.TemporaryDirectory() as tmp:
        stale = Path(tmp) / "pmp_xml.ads"
        stale.write_text(TABLE.read_text().replace("16#0000_0000_0000_009f#", "16#0000_0000_0000_0098#", 1))
        bad = run("pmp", "--svd", str(SVD), "--check", "--ada", str(stale), ICICLE_XML)
        assert bad.returncode == 1 and "is not current" in bad.stderr, bad.stderr
        written = Path(tmp) / "new" / "pmp_xml.ads"
        made = run("pmp", "--svd", str(SVD), "--ada", str(written), ICICLE_XML)
        assert made.returncode == 0 and written.read_text() == TABLE.read_text(), made.stderr
    usage = run("pmp", "--svd", str(SVD), "--check", ICICLE_XML)
    assert usage.returncode == 2 and "--ada" in usage.stderr


@case("pmp prints the entries of each hart")
def _():
    out = run("pmp", "--svd", str(SVD), ICICLE_XML)
    assert out.returncode == 0, out.stderr
    assert "hart 0: pmpcfg0 0x0000000000000000, pmpcfg2 0x0000000000000000, 0 of 16 entries not OFF" in out.stdout
    assert out.stdout.count("  entry 0: NAPOT [0x0, 0xffffffffffffff] rwx locked") == 4


@case("tests.list and the Renode expectations run the PMP tests and the APB window test on the E51 and a U54")
def _():
    rows = (ROOT / "tests" / "qemu" / "tests.list").read_text().splitlines()
    renode = (ROOT / "tests" / "renode" / "smoke.expected").read_text().splitlines()
    for test in ("pmp_xml_test", "pmp_access_test", "pmp_isolation_test", "apb_window_test"):
        for hart in ("e51", "u54"):
            assert f"{test}_{hart}\texamples/{test}\t0\tpass\t-\t-" in rows, (test, hart)
            assert f"examples/{test}/bin-{hart}/{test}.elf\tTEST {test}_{hart}: PASS" in renode, (test, hart)


finish()
