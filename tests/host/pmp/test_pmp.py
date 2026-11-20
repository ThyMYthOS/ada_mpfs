# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# @verifies GEN-010
"""config/gen/mpfs_gen/pmp.py: the PMP of the reference XMLs, the regions of the entries, a negative case for
every code of the PMP sections, the Ada table of examples/pmp_xml_test and the command line; and that the
emulator lists run the PMP test programs. Needs the merged SVD (tools/svd.py ensure)."""
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
