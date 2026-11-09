# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""tools/gen_ada/svdread.py: peripherals, groups, readActions and interrupts of a small SVD."""
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


finish()
