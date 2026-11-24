# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""tools/gen_ada/svdread.py: peripherals, groups, readActions, interrupts and the layout of registers of small SVDs;
ensure."""
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent.parent
sys.path[:0] = [str(HERE), str(ROOT / "tools")]

from gen_ada import errors, svdread  # noqa: E402
from harness import case, finish, raises  # noqa: E402

SVD = """<?xml version="1.0"?>
<device><peripherals>
  <peripheral><name>UART0_LO</name><groupName>UART</groupName>
    <interrupt><name>UART0</name><value>90</value><description>First
      UART  interrupt</description></interrupt>
    <registers><register><name>RBR</name><fields>
      <field><name>DATA</name><readAction>modifyExternal</readAction></field>
    </fields></register></registers></peripheral>
  <peripheral derivedFrom="UART0_LO"><name>UART0_HI</name></peripheral>
  <peripheral derivedFrom="UART0_HI"><name>UART1_LO</name>
    <interrupt><name> UART1 </name><value> 91 </value></interrupt></peripheral>
  <peripheral><name>TIMER</name><groupName> TIMER </groupName>
    <registers><register><name>COUNT</name><fields><field><name>VALUE</name></field></fields></register></registers>
  </peripheral>
  <peripheral><name>OTHER</name></peripheral>
  <peripheral derivedFrom="B"><name>A</name></peripheral>
  <peripheral derivedFrom="A"><name>B</name><groupName>LOOP</groupName></peripheral>
  <peripheral><name>PLIC</name>
    <interrupt><name>NOVALUE</name></interrupt></peripheral>
</peripherals></device>
"""


def svd_root(tmp, text=SVD):
    path = Path(tmp) / "t.svd"
    path.write_text(text, encoding="utf-8")
    return svdread.load(path)


@case("peripherals come in file order with their group, resolved through derivedFrom")
def _():
    with tempfile.TemporaryDirectory() as t:
        got = [(p.name, p.group) for p in svdread.peripherals(svd_root(t))]
    assert got == [("UART0_LO", "UART"), ("UART0_HI", "UART"), ("UART1_LO", "UART"), ("TIMER", "TIMER"),
                   ("OTHER", ""), ("A", "LOOP"), ("B", "LOOP"), ("PLIC", "")], got


@case("a readAction counts for the peripheral and for the ones that derive from it, at any depth")
def _():
    with tempfile.TemporaryDirectory() as t:
        reads = {p.name: p.reads for p in svdread.peripherals(svd_root(t))}
    assert reads == {"UART0_LO": True, "UART0_HI": True, "UART1_LO": True, "TIMER": False, "OTHER": False,
                     "A": False, "B": False, "PLIC": False}, reads


@case("a cycle of derivedFrom ends")
def _():
    with tempfile.TemporaryDirectory() as t:
        names = [p.name for p in svdread.peripherals(svd_root(t))]
    assert "A" in names and "B" in names


@case("the interrupts are those of all peripherals, stripped, with the description in one line")
def _():
    with tempfile.TemporaryDirectory() as t:
        got = [(i.name, i.value, i.description) for i in svdread.interrupts(svd_root(t))]
    assert got == [("UART0", "90", "First UART interrupt"), ("UART1", "91", ""), ("NOVALUE", "", "")], got


@case("an SVD without peripherals or interrupts gives empty lists")
def _():
    with tempfile.TemporaryDirectory() as t:
        root = svd_root(t, "<device/>")
    assert svdread.peripherals(root) == [] and svdread.interrupts(root) == []


LAYOUT = """<?xml version="1.0"?>
<device><size>32</size><peripherals>
  <peripheral><name>PHY</name>
    <registers>
      <register><name>MODE</name><fields>
        <field><name>A</name><bitOffset>0</bitOffset><bitWidth>3</bitWidth></field>
        <field><name>B</name><lsb>4</lsb><msb>7</msb></field>
        <field><name>C</name><bitRange>[15:8]</bitRange></field>
        <field><name>D</name><bitOffset>x</bitOffset></field>
        <field><name>E</name></field>
      </fields></register>
      <register><name>WIDE</name><size>0x40</size><fields>
        <field><name>ADDR</name><bitOffset>0</bitOffset><bitWidth>36</bitWidth></field>
      </fields></register>
    </registers></peripheral>
  <peripheral derivedFrom="PHY"><name>PHY2</name></peripheral>
  <peripheral><name>NARROW</name><size>16</size>
    <registers><register><name>R</name></register></registers></peripheral>
</peripherals></device>
"""


@case("registers: the size and the fields in the three forms of bits; a derived peripheral has its base's")
def _():
    with tempfile.TemporaryDirectory() as t:
        regs = svdread.registers(svd_root(t, LAYOUT))
    mode = regs[("PHY", "MODE")]
    assert mode.size == 32 and mode.fields == {"A": svdread.Field(0, 3), "B": svdread.Field(4, 4),
                                               "C": svdread.Field(8, 8)}, mode
    assert regs[("PHY", "WIDE")].size == 64 and regs[("PHY", "WIDE")].fields["ADDR"] == svdread.Field(0, 36)
    assert regs[("PHY2", "MODE")] == mode
    assert regs[("NARROW", "R")] == svdread.Register(16, {})
    assert sorted(regs) == [("NARROW", "R"), ("PHY", "MODE"), ("PHY", "WIDE"), ("PHY2", "MODE"), ("PHY2", "WIDE")]


BLOCKS = """<?xml version="1.0"?>
<device><size>32</size><peripherals>
  <peripheral><name>CLINT</name><baseAddress>0x02000000</baseAddress>
    <registers>
      <register><name>MSIP%s</name><addressOffset>0x0</addressOffset><dim>5</dim><dimIncrement>4</dimIncrement></register>
      <register><name>MTIME</name><addressOffset>0xBFF8</addressOffset><size>0x40</size></register>
      <register><name>NONE</name></register>
    </registers></peripheral>
  <peripheral derivedFrom="CLINT"><name>CLINT_HI</name><baseAddress>0x2000000</baseAddress></peripheral>
  <peripheral><name>EMPTY</name><baseAddress>0x20</baseAddress></peripheral>
  <peripheral><name>NOWHERE</name><baseAddress>x</baseAddress></peripheral>
</peripherals></device>
"""


@case("blocks: the base, the span of the registers (a <dim> array whole, a 64-bit register 8 bytes), the offsets "
      "and the step of an array")
def _():
    with tempfile.TemporaryDirectory() as t:
        found = svdread.blocks(svd_root(t, BLOCKS))
    assert sorted(found) == ["CLINT", "CLINT_HI", "EMPTY"], found
    clint = found["CLINT"]
    assert (clint.base, clint.span, clint.offsets) == (0x0200_0000, 0xC000, {"MSIP%s": 0, "MTIME": 0xBFF8}), clint
    assert clint.steps == {"MSIP%s": 4}, clint
    assert found["CLINT_HI"] == clint
    assert found["EMPTY"] == svdread.Block(0x20, 0, {})


@case("ensure: a failing tools/svd.py raises the error of the caller with its output")
def _():
    class Mine(errors.GenError):
        pass
    with tempfile.TemporaryDirectory() as t:
        tools = Path(t) / "tools"
        tools.mkdir()
        (tools / "svd.py").write_text("import sys\nprint('no svdtools')\nsys.exit(3)\n")
        raises(Mine, lambda: svdread.ensure(Path(t), error=Mine), "no svdtools")
        (tools / "svd.py").write_text("")
        assert svdread.ensure(Path(t)) == Path(t) / "build" / "svd" / "PolarfireSoC.svd"


@case("load: a missing file and a file that is no XML raise the error of the caller, naming the file")
def _():
    class Mine(errors.GenError):
        pass
    with tempfile.TemporaryDirectory() as t:
        missing = Path(t) / "missing.svd"
        raises(errors.InputError, lambda: svdread.load(missing), f"{missing}: cannot read the SVD")
        garbage = Path(t) / "garbage.svd"
        garbage.write_text("this is not xml")
        raises(Mine, lambda: svdread.load(garbage, error=Mine), f"{garbage}: cannot read the SVD")


MAP_SVD = """<?xml version="1.0"?>
<device><size>32</size><peripherals>
  <peripheral><name>BLOCK_A</name><groupName>BLOCK</groupName><baseAddress>0x1000</baseAddress>
    <registers>
      <register><name>CTRL</name><addressOffset>0x4</addressOffset></register>
      <register><name>DATA%s</name><addressOffset>0x10</addressOffset><dim>2</dim><dimIncrement>0x8</dimIncrement></register>
      <register><name>WIDE</name><addressOffset>0x30</addressOffset><size>64</size></register>
    </registers></peripheral>
  <peripheral derivedFrom="BLOCK_A"><name>BLOCK_B</name><baseAddress>0x2000</baseAddress></peripheral>
</peripherals></device>
"""


@case("register_map: registers by absolute address, derived peripherals at their own base, dim elements, sizes")
def _():
    with tempfile.TemporaryDirectory() as t:
        got = svdread.register_map(svd_root(t, MAP_SVD))
    assert got[0x1004] == svdread.RegisterAt("BLOCK_A", "BLOCK", "CTRL", 32, False), got[0x1004]
    assert got[0x2004] == svdread.RegisterAt("BLOCK_B", "BLOCK", "CTRL", 32, False), got[0x2004]
    assert got[0x1010].array and got[0x1018].array and got[0x1018].name == "DATA", got[0x1018]
    assert got[0x1030].size == 64 and 0x1005 not in got and 0x1014 not in got
    assert len(got) == 8, sorted(hex(a) for a in got)


finish()
