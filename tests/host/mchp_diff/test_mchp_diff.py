# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
#
# @verifies GEN-005
"""tools/mchp_diff/mchp_diff.py: the reference XMLs of config/boards agree with Microchip's generator; a stand-in
output of the generator with a changed value, a define that maps to nothing, a define given twice and a missing
register fail and name the define; the exception list admits a difference only with a reason and refuses an
entry that admits nothing; the pin of the generator is checked. Needs the merged SVD (tools/svd.py ensure) and
the generator (fetched into build/mchp_diff on the first run)."""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent.parent
sys.path[:0] = [str(ROOT / "tools" / "mchp_diff"), str(HERE.parent / "gen_ada")]

import mchp_diff
from gen_ada import errors, svdread
from harness import case, finish, raises
from mpfs_gen import xml_reader

TOOL = ROOT / "tools" / "mchp_diff" / "mchp_diff.py"
SVD = svdread.ensure(ROOT)
ICICLE = ROOT / "config" / "boards" / "icicle" / "ICICLE_MSS_mss_cfg.xml"
TMP = Path(tempfile.mkdtemp(prefix="mchp_diff_test-"))
SCRIPT = mchp_diff.ensure_generator(mchp_diff.load_oracle())
GENERATED = mchp_diff.run_generator(SCRIPT, ICICLE, TMP / "generated")
EMPTY = TMP / "empty.yaml"
EMPTY.write_text("exceptions: []\n")


def run(*args):
    """The tool on the command line: (status, stdout + stderr)."""
    result = subprocess.run([sys.executable, "-I", str(TOOL), "--svd", str(SVD), *map(str, args)],
                            capture_output=True, text=True, check=False)
    return result.returncode, result.stdout + result.stderr


def stand_in(name, edit):
    """A copy of the generator's output for the Icicle Kit; edit(directory) changes it."""
    copy = TMP / name
    shutil.copytree(GENERATED, copy)
    edit(copy)
    return copy


def replace(path, old, new):
    text = path.read_text()
    assert text.count(old) == 1, f"{old!r} in {path.name}"
    path.write_text(text.replace(old, new))


def exceptions(name, body):
    path = TMP / name
    path.write_text(body)
    return path


PLL = "clocks/hw_clk_mss_pll.h"
CHANGED = stand_in("changed", lambda d: replace(d / PLL, "LIBERO_SETTING_MSS_PLL_CTRL    0x01000037UL",
                                                "LIBERO_SETTING_MSS_PLL_CTRL    0x01000035UL"))
ENTRY = ("exceptions:\n  - define: LIBERO_SETTING_MSS_PLL_CTRL\n    xml: config/boards/icicle/ICICLE_MSS_mss_cfg.xml\n"
         "    defect: microchip\n    reason: {reason}\n")


@case("the reference XMLs agree with Microchip's generator, with nothing unmapped or missing")
def _():
    status, out = run()
    assert status == 0, out
    summaries = [line for line in out.splitlines() if line.startswith("config/boards/")]
    assert len(summaries) == len(sorted((ROOT / "config" / "boards").glob("*/*.xml"))) == 5, out
    for line in summaries:
        assert "differ 0)" in line and "unmapped 0; missing 0" in line and "compared 0 " not in line, line


@case("the committed exception list is empty")
def _():
    assert mchp_diff.load_exceptions() == []


@case("a stand-in output with a changed value fails and names the define and both values")
def _():
    status, out = run("--exceptions", EMPTY, "--generator-output", CHANGED, ICICLE)
    assert status == 1, out
    line = next(line for line in out.splitlines() if line.startswith("differs"))
    assert "LIBERO_SETTING_MSS_PLL_CTRL" in line and "mss_clocks/mss_pll/PLL_CTRL" in line, line
    assert "ours 0x01000037" in line and "microchip 0x01000035" in line, line
    assert "1 difference(s)" in out, out


@case("an entry with a reason admits the difference and says whose defect it is")
def _():
    status, out = run("--exceptions", exceptions("admit.yaml", ENTRY.format(reason="a test")),
                      "--generator-output", CHANGED, ICICLE)
    assert status == 0, out
    assert "[admitted, defect of microchip: a test]" in out, out


@case("an entry without a reason, with an empty reason, another defect, an unknown key or given twice is refused")
def _():
    for name, body, message in (
            ("no_reason.yaml", ENTRY.replace("    reason: {reason}\n", ""), "needs exactly the keys"),
            ("empty_reason.yaml", ENTRY.format(reason='" "'), "reason must be a text that is not empty"),
            ("defect.yaml", ENTRY.format(reason="x").replace("microchip", "nobody"), "is not one of ours, microchip"),
            ("key.yaml", ENTRY.format(reason="x") + "    note: y\n", "needs exactly the keys"),
            ("twice.yaml", ENTRY.format(reason="x") + ENTRY.format(reason="y").removeprefix("exceptions:\n"),
             "listed twice"),
            ("no_list.yaml", "exceptions: {}\n", "the one key `exceptions`")):
        status, out = run("--exceptions", exceptions(name, body), "--generator-output", CHANGED, ICICLE)
        assert status == 2 and message in out, f"{name}: {status} {out}"
        raises(errors.InputError, lambda path=TMP / name: mchp_diff.load_exceptions(path), message)


@case("an entry that admits nothing is refused")
def _():
    status, out = run("--exceptions", exceptions("stale.yaml", ENTRY.format(reason="x")),
                      "--generator-output", GENERATED, ICICLE)
    assert status == 2 and "admits what does not differ" in out and "LIBERO_SETTING_MSS_PLL_CTRL" in out, out


@case("a define that maps to no register is reported: unknown name, missing prefix, unknown header, given twice")
def _():
    def edit(d):
        with (d / PLL).open("a") as f:
            f.write("#define LIBERO_SETTING_MSS_NO_SUCH_REG 0x1UL\n#define LIBERO_SETTING_PLL_CTRL 0x1UL\n")
        (d / "clocks" / "hw_new.h").write_text("#define LIBERO_SETTING_NEW_THING 0x1UL\n")
        with (d / "io" / "hw_mssio_mux.h").open("a") as f:
            f.write("#define LIBERO_SETTING_IOMUX0_CR 0x0UL\n")
    status, out = run("--exceptions", EMPTY, "--generator-output", stand_in("unmapped", edit), ICICLE)
    assert status == 1 and "4 difference(s)" in out, out
    unmapped = {line.split()[1]: line for line in out.splitlines() if line.startswith("unmapped ")}
    assert "mss_clocks/mss_pll has no register NO_SUCH_REG" in unmapped["LIBERO_SETTING_MSS_NO_SUCH_REG"]
    assert "lacks the prefix LIBERO_SETTING_MSS_" in unmapped["LIBERO_SETTING_PLL_CTRL"]
    assert "not a header of a known section" in unmapped["LIBERO_SETTING_NEW_THING"]
    assert "defined before in io/hw_mssio_mux.h" in unmapped["LIBERO_SETTING_IOMUX0_CR"]


@case("a register of the model that no define gives is reported as missing")
def _():
    def edit(d):
        text = (d / PLL).read_text()
        (d / PLL).write_text(text.replace("#define LIBERO_SETTING_MSS_PLL_CTRL ", "#define NOT_A_SETTING "))
    status, out = run("--exceptions", EMPTY, "--generator-output", stand_in("missing", edit), ICICLE)
    assert status == 1, out
    assert any(line.startswith("missing") and "LIBERO_SETTING_MSS_PLL_CTRL" in line
               and "mss_clocks/mss_pll/PLL_CTRL (clocks/hw_clk_mss_pll.h)" in line for line in out.splitlines()), out


@case("a value that is not a C integer is reported; decimal sections compare as decimal")
def _():
    config = xml_reader.read(ICICLE, SVD)
    header = "clocks/hw_mss_clks.h"
    rows = mchp_diff.compare(config, [mchp_diff.Define(header, "LIBERO_SETTING_MSS_RTC_TOGGLE_CLK", "1000000"),
                                      mchp_diff.Define(header, "LIBERO_SETTING_MSS_AXI_CLK", "0x11E1A300")])
    assert rows[0].kind == "agrees" and rows[0].ours == "1000000", rows[0]
    assert rows[1].kind == "agrees", rows[1]
    rows = mchp_diff.compare(config, [mchp_diff.Define(header, "LIBERO_SETTING_MSS_AXI_CLK", "300 MHz")])
    assert rows[0].kind == "unmapped" and "is not a C integer" in rows[0].target, rows[0]


@case("C literals: hex, octal, decimal and their suffixes; strings")
def _():
    for text, value in (("0x01000037UL", 0x01000037), ("0xFFFFFFFFFFFFFFFFULL", 2 ** 64 - 1), ("125000000", 125000000),
                        ("0", 0), ("010", 8), ("7u", 7), ("1LU", 1)):
        assert mchp_diff.c_integer(text) == value, text
    for text in ("", "0x", "08", "1.0", "1UUL", "abc", '"1"'):
        assert mchp_diff.c_integer(text) is None, text
    assert mchp_diff.c_string('"ICICLE_MSS"') == "ICICLE_MSS" and mchp_diff.c_string("ICICLE_MSS") is None


@case("the pinned generator: another commit or a changed script is refused")
def _():
    oracle = mchp_diff.load_oracle()
    cache = TMP / "cache"
    clone = cache / f"platform-{oracle.commit}"
    shutil.copytree(SCRIPT.parents[1], clone, symlinks=True)
    assert mchp_diff.ensure_generator(oracle, cache) == clone / oracle.script
    with (clone / oracle.script).open("a") as f:
        f.write("\n")
    raises(errors.InputError, lambda: mchp_diff.ensure_generator(oracle, cache), "not the SHA-256")
    other = mchp_diff.Oracle(oracle.repo, "0" * 40, oracle.date, oracle.script, oracle.sha256)
    (cache / f"platform-{other.commit}").symlink_to(clone)
    raises(errors.InputError, lambda: mchp_diff.ensure_generator(other, cache), "not at the pinned")
    bad = TMP / "oracle.env"
    bad.write_text("MCHP_PLATFORM_REPO=x\nMCHP_PLATFORM_COMMIT=8d52d59\n")
    raises(errors.InputError, lambda: mchp_diff.load_oracle(bad), "no MCHP_PLATFORM_DATE")


@case("a generator that gives up without its output (status 0) is an error")
def _():
    script = TMP / "gives_up.py"
    script.write_text("import sys\nsys.exit()\n")
    raises(errors.InputError, lambda: mchp_diff.run_generator(script, ICICLE, TMP / "gives_up"),
           "Microchip's generator failed")


shutil.rmtree(TMP, ignore_errors=True)
finish()
