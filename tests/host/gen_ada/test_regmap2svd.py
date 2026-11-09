# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""tools/regmap2svd.py on a tiny register map: the headers of the fragments and the device head come
from gen_ada.spdx, and the generator itself has the one licence of its own header."""
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent.parent
sys.path[:0] = [str(HERE), str(ROOT / "tools")]

from gen_ada import spdx  # noqa: E402
from harness import case, finish  # noqa: E402
import regmap_fixture  # noqa: E402

try:
    import bs4, yaml  # noqa: E401,F401
except ImportError:
    print("skip: regmap2svd needs beautifulsoup4 and PyYAML (./x toolchain install)")
    sys.exit(0)

TOOL = ROOT / "tools" / "regmap2svd.py"


def convert(directory: Path) -> Path:
    regmap_fixture.write(directory / "in")
    out = directory / "out"
    done = subprocess.run([sys.executable, "-I", str(TOOL), str(directory / "in" / "MSS"), str(out)],
                          capture_output=True, text=True)
    assert done.returncode == 0, done.stderr
    return out


with tempfile.TemporaryDirectory() as tmp:
    out = convert(Path(tmp))

    @case("one fragment per page and the device head are written")
    def _():
        assert sorted(p.name for p in out.iterdir()) == ["bar.yaml", "device.svd", "foo.yaml"]

    @case("a fragment starts with the YAML header and has the instances of its family")
    def _():
        text = (out / "bar.yaml").read_text(encoding="utf-8")
        assert text.startswith(spdx.header("yaml", "CC-BY-4.0") + "_add:\n"), text[:200]
        assert "BAR1:" in text and "derivedFrom: BAR0" in text and "groupName: BAR" in text

    @case("the device head starts with the XML declaration and the XML header, then the history")
    def _():
        text = (out / "device.svd").read_text(encoding="utf-8")
        head = '<?xml version="1.0" encoding="utf-8"?>\n' + spdx.header("xml", "CC-BY-4.0")
        assert text.startswith(head + "<!--\nMicrochip register map revision history:\n"), text[:300]
        assert "<version>1.1</version>" in text and "first - - release" in text

    @case("a register that is listed twice is an input error with a message, not a traceback")
    def _():
        bad = Path(tmp) / "bad"
        regmap_fixture.write(bad)
        reg = ("CTRL", "0x20001000", "0x0", "RW", [["[7:0]", "data", "d", "RW", "0"]])
        (bad / "MSS" / "pfsoc_mss_top_foo.htm").write_text(
            regmap_fixture.page("foo", [reg, reg], [["CTRL", "32"]]), encoding="utf-16")
        done = subprocess.run([sys.executable, "-I", str(TOOL), str(bad / "MSS"), str(bad / "out")],
                              capture_output=True, text=True)
        assert done.returncode == 2, (done.returncode, done.stderr)
        assert done.stderr == "regmap2svd: FOO: duplicate register CTRL\n", done.stderr

    @case("the generator is licensed once: only the two lines of its header carry tags")
    def _():
        lines = TOOL.read_text(encoding="utf-8").splitlines()
        assert [n for n, line in enumerate(lines, 1) if "SPDX" + "-" in line] == [2, 3]

finish()
