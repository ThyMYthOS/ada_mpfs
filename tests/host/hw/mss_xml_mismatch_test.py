# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""The warning of a build whose MSS set-up table is not made from the XML of hw/lab.conf: hw/lab.py
(mss_xml_mismatch, warn_mss_xml_mismatch), called by ./x for an example that has the key MSS_XML.

    mss_xml_mismatch_test.py

Prints "ok:" or "FAIL:" per case; exits non-zero if one failed.
"""
import contextlib
import io
import os
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path[:0] = [str(ROOT / "hw"), str(ROOT / "tests" / "host" / "gen_ada")]

import lab
from harness import case, finish

ES = ROOT / "config" / "boards" / "icicle_es" / "ICICLE_MSS_mss_cfg.xml"
OTHER = ROOT / "config" / "boards" / "icicle" / "ICICLE_MSS_mss_cfg.xml"


def conf(**more):
    values = lab.read_env_file(lab.EXAMPLE)
    values.update(more)
    return values


@case("no MSS_XML in the lab settings: no warning, whatever the build takes")
def _():
    assert lab.mss_xml_mismatch(None, conf()) is None
    assert lab.mss_xml_mismatch(ES, conf()) is None


@case("the same file, written relative or absolute, is no mismatch")
def _():
    relative = str(ES.relative_to(ROOT))
    assert lab.mss_xml_mismatch(ES, conf(MSS_XML=relative)) is None
    assert lab.mss_xml_mismatch(ES, conf(MSS_XML=str(ES))) is None
    assert lab.mss_xml_mismatch(ROOT / "config" / ".." / relative, conf(MSS_XML=relative)) is None


@case("another XML than the one of the lab settings is named with both files")
def _():
    message = lab.mss_xml_mismatch(ES, conf(MSS_XML=str(OTHER)))
    assert message and str(OTHER) in message and str(ES) in message, message


@case("a build from the table of the source tree against a lab XML says so and names MSS_XML of example.conf")
def _():
    message = lab.mss_xml_mismatch(None, conf(MSS_XML=str(OTHER)))
    assert message and str(OTHER) in message and "table of the source tree" in message and "example.conf" in message, message


@case("warn_mss_xml_mismatch prints one line to stderr for the lab file in LAB_CONF, nothing for none or a bad one")
def _():
    with tempfile.TemporaryDirectory() as tmp:
        good, bad = Path(tmp) / "lab.conf", Path(tmp) / "bad.conf"
        good.write_text(f"MSS_XML={OTHER}\n")
        bad.write_text("UART_BAUD=12345\n")
        saved = os.environ.get("LAB_CONF")
        try:
            os.environ["LAB_CONF"] = str(good)
            err = io.StringIO()
            with contextlib.redirect_stderr(err):
                lab.warn_mss_xml_mismatch(None)
            assert err.getvalue().startswith("x: warning: MSS_XML of hw/lab.conf names ") and err.getvalue().count("\n") == 1, err.getvalue()
            os.environ["LAB_CONF"] = str(bad)
            err = io.StringIO()
            with contextlib.redirect_stderr(err):
                lab.warn_mss_xml_mismatch(None)
            assert err.getvalue() == "", err.getvalue()
        finally:
            if saved is None:
                os.environ.pop("LAB_CONF", None)
            else:
                os.environ["LAB_CONF"] = saved


finish()
