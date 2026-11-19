# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# @verifies GEN-003, GEN-004
"""config/gen/mpfs_gen/xml_reader.py: the reference XMLs of config/boards, the broken XMLs of fixtures/broken
(each names the one code it must be rejected with), the known defect of PLL_PHADJ, the layout from the SVD,
the values against the literals of hw/mss_init.py, the command line. Needs the merged SVD (tools/svd.py
ensure)."""
import dataclasses
import hashlib
import re
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent.parent
sys.path[:0] = [str(HERE.parent / "gen_ada"), str(ROOT / "config" / "gen"), str(ROOT / "tools"), str(ROOT / "hw")]

import mss_init
from gen_ada import svdread
from harness import case, finish, raises
from mpfs_gen import checks, xml_reader
from mpfs_gen.checks import ConfiguratorXmlError

SVD = svdread.ensure(ROOT)
BOARDS = ROOT / "config" / "boards"
BROKEN = HERE / "fixtures" / "broken"
BASE = BOARDS / "icicle" / "ICICLE_MSS_mss_cfg.xml"
REFERENCE = {"icicle": "0.6.8", "icicle_es": "0.6.5", "video_kit": "0.6.8"}
EXPECT = re.compile(r"^#? ?expect: (GEN-E\d{3})$", re.MULTILINE)
PLL = "mss_clocks/mss_pll"


def reference_xmls():
    return sorted(BOARDS.glob("*/*.xml"))


def read(path, name=None):
    return xml_reader.read(path, SVD, name=name)


def expected(path):
    found = EXPECT.findall(path.read_text())
    assert len(found) == 1, f"{path.name} must name exactly one expected code"
    return found[0]


def edited(edit):
    """The text of BASE with the edits of an .edit fixture: each `after:`, `old:`, `new:` replaces the first
    `old` after the first `after`."""
    text = BASE.read_text()
    steps = [line.split(": ", 1) for line in edit.read_text().splitlines() if not line.startswith("#")]
    for (k1, after), (k2, old), (k3, new) in zip(steps[0::3], steps[1::3], steps[2::3]):
        assert (k1, k2, k3) == ("after", "old", "new"), edit.name
        start = text.index(after)
        at = text.index(old, start)
        text = text[:at] + new + text[at + len(old):]
    return text


def codes_of(path):
    try:
        read(path)
    except ConfiguratorXmlError as err:
        return err.codes
    return []


def broken_cases():
    """(fixture, the XML to read) for every fixture: an .xml as it is, an .edit applied to BASE."""
    tmp = Path(tempfile.mkdtemp())
    for fixture in sorted(BROKEN.iterdir()):
        if fixture.suffix == ".edit":
            path = tmp / (fixture.stem + ".xml")
            path.write_text(edited(fixture))
            yield fixture, path
        else:
            yield fixture, fixture


def cli(*args):
    return subprocess.run([sys.executable, "-I", str(ROOT / "config" / "gen" / "mpfs_gen"), *args],
                          capture_output=True, text=True, check=False)


@case("the reference XMLs of config/boards are the ones described and read, each with its format version")
def _():
    found = {p.parent.name: read(p) for p in reference_xmls()}
    assert {board: c.design.format_version for board, c in found.items()} == REFERENCE, found.keys()
    assert set(REFERENCE.values()) == set(xml_reader.FORMAT_VERSIONS), "each known version has a reference XML"
    for board, config in found.items():
        assert sorted(config.sections) == sorted(xml_reader.NEEDED), (board, config.sections)
        assert len(config.registers) == 314 and len(config.mem_elements) == 13, board
        assert config.validated == ("mss_io/hsio", "mss_ddr/options", "mss_ddr/io_bank", "mss_ddr/segs",
                                    "mss_ddr/ddrc", "mss_clocks/sgmii_pll", "mss_clocks/ddr_pll"), board


@case("the design information and the SHA-256 of the bytes")
def _():
    config = read(BASE)
    assert config.sha256 == hashlib.sha256(BASE.read_bytes()).hexdigest()
    d = config.design
    assert (d.libero_version, d.design_name, d.part_number, d.package) == ("2024.2", "ICICLE_MSS", "MPFS250T", "FCVG484")
    es = read(BOARDS / "icicle_es" / "ICICLE_MSS_mss_cfg.xml").design
    assert (es.libero_version, es.part_number) == ("2022.2", "MPFS250T_ES")
    assert read(BOARDS / "video_kit" / "MSS_video-kit_mss_cfg.xml").design.part_number == "MPFS250TS"


@case("each broken XML is rejected with exactly the code it names; every code of the reader has one")
def _():
    covered = set()
    for fixture, path in broken_cases():
        got = codes_of(path)
        assert got == [expected(fixture)], (fixture.name, got)
        covered.add(got[0])
    assert covered == checks.XML_CODES, sorted(covered ^ checks.XML_CODES)


@case("the codes of the reader are in CODES and in the table of config/README.md (checked by system_yaml)")
def _():
    assert checks.XML_CODES and checks.XML_CODES <= set(checks.CODES)
    assert sorted(checks.XML_CODES) == [f"GEN-E{n:03}" for n in range(40, 53)]


@case("PLL_PHADJ of the MSS PLL: the 0x8 in the 3 bits of REG_OUT3_PHSINIT gives 0x4003, named as a defect, in every reference XML")
def _():
    for path in reference_xmls():
        config = read(path)
        reg = config.register(PLL, "PLL_PHADJ")
        field = reg.field("REG_OUT3_PHSINIT")
        assert (field.bits.width, field.value, field.svd) == (3, 0x8, xml_reader.BitField(11, 3)), path
        assert reg.field("REG_LOADPHS_B").value == 0, path
        assert reg.defect and "REG_LOADPHS_B" in reg.defect and "0x4003" in reg.defect, path
        # What Microchip's generator writes (and hw/mss_init.py): the overflow lands on bit 14, REG_LOADPHS_B.
        assert reg.value == config.value(PLL, "PLL_PHADJ") == 0x4003, (path, hex(reg.value))
        assert [r.name for r in config.registers if r.defect] == ["PLL_PHADJ"], path


@case("a register is found by section and name: PLL_CTRL of the MSS PLL is not that of the other PLLs")
def _():
    config = read(BASE)
    assert config.value(PLL, "PLL_CTRL") == 0x01000037
    raises(KeyError, lambda: config.register("mss_clocks/sgmii_pll", "PLL_CTRL"), "no register PLL_CTRL")
    raises(KeyError, lambda: config.register(PLL, "PLL_CNTL"))
    raises(KeyError, lambda: config.register(PLL, "PLL_CTRL").field("LOCK_NOT_A_FIELD"))


@case("a value is the sum of the RW fields at their offsets; other fields have no value")
def _():
    config = read(BASE)
    for reg in config.registers:
        if reg.value is None:
            continue
        assert reg.value == sum(f.value << f.bits.offset for f in reg.fields if f.access == "RW"), reg.name
        assert all((f.value is None) == (f.access != "RW") for f in reg.fields), reg.name
    tip = config.register("mss_sgmii/tip", "PLL_CNTL")
    assert any(f.access != "RW" and f.value is None for f in tip.fields)


@case("the layout comes from the SVD where the SVD has the register; decimal sections are decimal")
def _():
    config = read(BASE)
    assert sum(1 for r in config.registers if r.svd) == 178
    mode = config.register("mss_sgmii/tip", "SGMII_MODE")
    assert mode.svd == "CFG_DDR_SGMII_PHY.SGMII_MODE" and mode.field("REG_CDR_MOVE_STEP").svd == xml_reader.BitField(22, 1)
    assert config.register(PLL, "PLL_PHADJ").svd == "CFG_DDR_SGMII_PHY.PLL_PHADJ_MAIN"
    assert config.register("mss_io/io_mux_alt", "ALT_IOMUX1_CR").svd == "SYSREG.IOMUX1_CR"
    assert config.register("mss_io/io_mux", "MSSIO_BANK2_CFG_CR").svd == "SCB_REGS.MSSIO_BANK2_CFG_CR"
    assert config.register("mss_memory_map/mpu_gem1", "MPU_CFG_PMP7").svd == "MPUCFG.PMPCFG_ETHERNET1_7"
    assert config.register("mss_memory_map/mpu_fic0", "MPU_CFG_PMP0").size == 64
    assert config.register("mss_memory_map/pmp_h1", "CSR_PMPADDR0").size == 64
    assert config.register("mss_memory_map/cache", "WAY_ENABLE").svd is None
    assert config.clocks == {"MSS_EXT_SGMII_REF_CLK": 125_000_000, "MSS_COREPLEX_CPU_CLK": 600_000_000,
                             "MSS_SYSTEM_CLK": 600_000_000, "MSS_RTC_TOGGLE_CLK": 1_000_000,
                             "MSS_AXI_CLK": 300_000_000, "MSS_APB_AHB_CLK": 150_000_000, "DDR_CLK": 1_600_000_000}
    assert config.value("mss_memory_map/nvm_map", "ENVM_MSS_END_PAGE") == 511
    assert [len(xml_reader.needed(f"mss_memory_map/mpu_{m}", xml_reader.svd_layout(SVD)))
            for m in xml_reader.MPU_MASTERS] == [16, 16, 8, 4, 8, 8, 4, 4, 8, 2]


@case("numbers: 0x and hex everywhere, decimal digits in the decimal sections, bare 0 to 9 in the hex ones")
def _():
    number = xml_reader._number
    assert [number(t, False) for t in ("0x1F", "0X0", "7", "07", "10", "", "0x", "1_0")] == [31, 0, 7, 7, None, None, None, None]
    assert [number(t, True) for t in ("600000000", "0x1", "0", "007", "6e8")] == [600000000, 1, 0, None, None]


@case("the memory elements and the reset vectors")
def _():
    mems = {m.name: m for m in read(BASE).mem_elements}
    assert mems["RESET_VECTOR_HART0"].address == 0x20220000 and mems["RESET_VECTOR_HART0"].size == 4
    assert mems["DDR_64_CACHE"].address == 0x1000000000


@case("the values that hw/mss_init.py writes are those of the Icicle Kit XMLs, with the known exceptions")
def _():
    for board in ("icicle", "icicle_es"):
        config = read(BOARDS / board / "ICICLE_MSS_mss_cfg.xml")
        io = "mss_io/io_mux"
        # RTC: the period; mss_init.py writes it with the clock off first and then sets ENABLE (bit 16).
        assert config.value("mss_clocks/mss_sys", "RTC_CLOCK_CR") == mss_init.RTC_PERIOD
        # SGMII_MODE: mss_init.py clears REG_CDR_MOVE_STEP (bit 22) on purpose.
        assert config.value("mss_sgmii/tip", "SGMII_MODE") == mss_init.SGMII_MODE_VALUE | 1 << 22
        for name, value in (("CH0_CNTL", 0x37F07770), ("CH1_CNTL", 0x37F07770), ("RECAL_CNTL", 0x000020C8),
                            ("CLK_CNTL", 0xF00050CC), ("SPARE_CNTL", 0xFF000000), ("PLL_CNTL", 0x80140101)):
            assert config.value("mss_sgmii/tip", name) == value, (board, name)
        bank4 = tuple(config.value(io, f"MSSIO_BANK4_IO_CFG_{i}_{i + 1}_CR") for i in range(0, 14, 2))
        bank2 = tuple(config.value(io, f"MSSIO_BANK2_IO_CFG_{i}_{i + 1}_CR") for i in range(0, 24, 2))
        assert (bank4, bank2) == (mss_init._BANK4, mss_init._BANK2), board
        assert config.value(io, "MSSIO_BANK2_CFG_CR") == 0x00080907 and config.value(io, "MSSIO_BANK4_CFG_CR") == 0x00040A0D
        for name, value in (("PLL_REF_FB", 0x500), ("PLL_DIV_0_1", 0x01000100), ("PLL_DIV_2_3", 0x4B000300),
                            ("PLL_CTRL2", 0x1020), ("PLL_FRACN", 0), ("SSCG_REG_0", 0), ("SSCG_REG_1", 0),
                            ("SSCG_REG_2", 0x60), ("SSCG_REG_3", 1), ("PLL_CTRL", 0x01000037),
                            ("PLL_PHADJ", 0x4003)):
            assert config.value(PLL, name) == value, (board, name)
        for section, name, value in (("mss_cfm", "PLL_CKMUX", 0x155), ("mss_cfm", "BCLKMUX", 0x208),
                                     ("mss_cfm", "FMETER_ADDR", 0), ("mss_cfm", "FMETER_DATAW", 0),
                                     ("sgmii_cfm", "CLK_XCVR", 0x2C30)):
            assert config.value(f"mss_clocks/{section}", name) == value, (board, name)
        iomux = tuple(config.value(io, f"IOMUX{i}_CR") for i in range(7))
        if board == "icicle_es":
            assert iomux == mss_init._IOMUX
        else:
            # The 2024.2 design differs in IOMUX0 (bit 3) and IOMUX4 (pads 4 and 5: 6 instead of C).
            assert iomux == (0x00000FD5,) + mss_init._IOMUX[1:4] + (0x88664444,) + mss_init._IOMUX[5:], iomux


@case("the messages name the file, the code and the path of the register or field")
def _():
    path = dict(broken_cases())[BROKEN / "e050_phadj_other_value.edit"]
    err = raises(ConfiguratorXmlError, lambda: read(path, name="x.xml"))
    assert str(err) == ("x.xml: GEN-E050 mss_clocks/mss_pll/PLL_PHADJ.REG_OUT3_PHSINIT: "
                        "0x9 does not fit the 3 bits of the field"), str(err)
    err = raises(ConfiguratorXmlError, lambda: read(BROKEN / "e042_unknown_version.xml", name="v.xml"))
    assert str(err) == "v.xml: GEN-E042 design_information/xml_format_version: 0.6.6 is not one of 0.6.5, 0.6.8"


@case("several mistakes are all reported; a missing file is GEN-E040")
def _():
    text = BASE.read_text().replace('name="SPARE_CNTL"', 'name="X"').replace(">600000000<", ">6e8<", 1)
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "two.xml"
        path.write_text(text)
        assert sorted(codes_of(path)) == ["GEN-E044", "GEN-E047"], codes_of(path)
        assert codes_of(Path(tmp) / "none.xml") == ["GEN-E040"]


@case("the model is immutable")
def _():
    config = read(BASE)
    raises(dataclasses.FrozenInstanceError, lambda: setattr(config, "sha256", "x"))
    raises(dataclasses.FrozenInstanceError, lambda: setattr(config.registers[0], "value", 1))
    assert isinstance(config.registers, tuple) and isinstance(config.registers[0].fields, tuple)


@case("the command line: xml --check prints ok, xml prints the registers, a broken XML is status 2")
def _():
    files = [str(p) for p in reference_xmls()]
    done = cli("xml", "--check", "--svd", str(SVD), *files)
    assert done.returncode == 0 and done.stdout.count(": ok\n") == len(files), (done.stdout, done.stderr)
    done = cli("xml", "--fields", "--svd", str(SVD), str(BASE))
    assert done.returncode == 0, done.stderr
    lines = done.stdout.splitlines()
    assert "mss_sgmii/tip/SGMII_MODE = 0x08c0_f2ff  [CFG_DDR_SGMII_PHY.SGMII_MODE]" in lines
    assert "mss_clocks/clocks/MSS_COREPLEX_CPU_CLK = 600000000" in lines
    assert "mss_clocks/mss_pll/PLL_PHADJ = 0x0000_4003  [CFG_DDR_SGMII_PHY.PLL_PHADJ_MAIN]  # known defect of the configurator" in lines
    assert "  .REG_OUT3_PHSINIT [11+3] RW = 0x0008  svd [11+3]" in lines
    assert lines[-1].startswith("# validated only: mss_io/hsio, mss_ddr/options")
    done = cli("xml", "--svd", str(SVD), str(BROKEN / "e041_doctype.xml"))
    assert done.returncode == 2 and "GEN-E041" in done.stderr, done


finish()
