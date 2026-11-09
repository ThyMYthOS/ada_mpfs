# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""A tiny register map in the format of tools/regmap2svd.py, for the tests.

  write(DIR)   DIR/MSS/pfsoc_mss_top_foo.htm and ..._bar.htm (UTF-16; bar has two further
               instances), DIR/pfsoc_regmap.htm (instance table) and DIR/Release Notes.htm
"""
from pathlib import Path


def table(rows):
    return "<table>" + "".join("<tr>" + "".join(f"<td>{c}</td>" for c in r) + "</tr>" for r in rows) + "</table>"


def page(name, regs, summary_rows, instances=None):
    html = [f"<html><body><h2>pfsoc_mss_top_{name}</h2>", "<h2>Foo Register Mapping Summary</h2>",
            table([["Register Name", "Register Width (bits)"]] + summary_rows)]
    for inst, addr in instances or []:
        html.append(f"<h3><a>x</a><a>{inst} Register Summary</a></h3>")
        html.append(table([["Register Name", "Physical Address"], ["R", addr]]))
    html.append("<h2>Foo Register Descriptions</h2>")
    for reg, addr, off, typ, fields in regs:
        html.append(f"<h3>Reg: {reg}</h3>")
        html.append(table([["Physical Address:", addr], ["Address Offset:", off],
                           ["Description:", f"{reg} register"], ["Type:", typ]]))
        html.append(table([["Bits", "Name", "Description", "Type", "Reset"]] + fields))
    html.append("</body></html>")
    return "".join(html)


def write(directory):
    d = Path(directory)
    (d / "MSS").mkdir(parents=True, exist_ok=True)
    (d / "MSS" / "pfsoc_mss_top_foo.htm").write_text(page(
        "foo",
        [("CTRL", "0x20001000", "0x0", "RW", [["[7:0]", "data", "The data", "RW", "0x5"],
                                              ["[8]", "reserved", "r", "RO", "0x1"],
                                              ["[9]", "en", "enable", "RO", "0"]]),
         ("STATUS", "0x20001000", "0x4", "RO", [["[31:0]", "val", "value", "RO", "0"]])],
        [["CTRL", "32"], ["STATUS", "32"]]), encoding="utf-16")
    (d / "MSS" / "pfsoc_mss_top_bar.htm").write_text(page(
        "bar",
        [("CTRL", "0x20002000", "0x0", "RW", [["[7:0]", "data", "d", "RW", "0"]])],
        [["CTRL", "32"]], instances=[("BAR0", "0x20002000"), ("BAR1", "0x20003000")]), encoding="utf-16")
    (d / "pfsoc_regmap.htm").write_text(
        "<html><body>" + table([["Instance Name", "Address"], ["ENVMCFG", "0x20000000"]]) + "</body></html>",
        encoding="utf-16")
    (d / "Release Notes.htm").write_text(
        "<html><body>" + table([["Version", "Date", "Details"], ["1.0", "1/2/2026", "first -- release"],
                                ["1.1", "3/4/2026", "second"]]) + "</body></html>", encoding="cp1252")
