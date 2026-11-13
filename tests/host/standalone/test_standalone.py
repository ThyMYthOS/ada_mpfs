# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""config/gen/standalone.py: the two outputs on fixtures, the defaults, the contract with the linker
scripts, --check, the inputs it refuses and the rule violations it must NOT refuse (the Ada checks of
the package do that, see run.sh). Needs no toolchain."""
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent.parent
sys.path[:0] = [str(HERE.parent / "gen_ada"), str(ROOT / "tools")]

from gen_ada import spdx  # noqa: E402
from harness import case, finish  # noqa: E402

GEN = ROOT / "config" / "gen" / "standalone.py"
FIX = HERE / "fixtures"
CASES = {
    "e51_default": ["--hart", "e51"],
    "u54_default": ["--hart", "u54"],
    "u54_secondary_scratchpad": ["--hart", "u54", "--harts", "2", "--role", "secondary", "--memory",
                                 "scratchpad", "--profile", "light-tasking"],
    "e51_local_memories": ["--hart", "e51", "--itim-length", "0x2000", "--dtim-length", "0x2000",
                           "--console", "mmuart4", "--console-init", "0", "--profile", "embedded"],
}
sys.path.insert(0, str(ROOT / "config" / "gen"))
import standalone  # noqa: E402


def run(args, cwd=None, env=None):
    return subprocess.run([sys.executable, "-I", str(GEN), *args], capture_output=True, text=True, cwd=cwd,
                          env=env)


def generate(args, tmp):
    """Run the generator into tmp; returns (package text, defsyms dict in file order)."""
    out = Path(tmp) / "mpfs_partition.ads"
    done = run([*args, "--output", str(out)])
    assert done.returncode == 0, done.stderr
    return out.read_text(), read_defsyms(out.with_name("mpfs_partition.defsyms"))


def read_defsyms(path):
    pairs = [line.split("=", 1) for line in path.read_text().splitlines() if line and not line.startswith("#")]
    return dict(pairs) if len({k for k, _ in pairs}) == len(pairs) else None


def with_tmp(fn):
    with tempfile.TemporaryDirectory() as tmp:
        return fn(tmp)


@case("the output of each fixture case is the committed fixture, byte for byte")
def _():
    for name, args in CASES.items():
        def one(tmp):
            package, _ = generate(args, tmp)
            assert package == (FIX / name / "mpfs_partition.ads").read_text(), name
            assert (Path(tmp) / "mpfs_partition.defsyms").read_text() == \
                (FIX / name / "mpfs_partition.defsyms").read_text(), name
        with_tmp(one)


@case("--check: the committed fixtures are current (status 0, nothing written)")
def _():
    for name, args in CASES.items():
        done = run([*args, "--check", "--output", str(FIX / name / "mpfs_partition.ads")])
        assert done.returncode == 0, (name, done.stderr)
        assert done.stdout == "" and done.stderr == ""


@case("--check: a changed package, a changed list and a missing file are not current (status 1, a diff)")
def _():
    def one(tmp):
        shutil.copytree(FIX / "e51_default", Path(tmp) / "f")
        args = [*CASES["e51_default"], "--check", "--output", str(Path(tmp) / "f" / "mpfs_partition.ads")]
        pkg = Path(tmp) / "f" / "mpfs_partition.ads"
        lst = Path(tmp) / "f" / "mpfs_partition.defsyms"
        old_pkg, old_lst = pkg.read_text(), lst.read_text()
        pkg.write_text(old_pkg.replace("Stack_Size               : constant := 16384",
                                       "Stack_Size               : constant := 8192"))
        done = run(args)
        assert done.returncode == 1 and "is not current" in done.stderr and "-   Stack_Size" in done.stderr \
            and "config/gen/standalone.py" in done.stderr, done.stderr
        assert "8192" in pkg.read_text(), "--check must not write"
        pkg.write_text(old_pkg)
        lst.write_text(old_lst.replace("__stack_size=16384", "__stack_size=8192"))
        done = run(args)
        assert done.returncode == 1 and "mpfs_partition.defsyms is not current" in done.stderr, done.stderr
        lst.unlink()
        done = run(args)
        assert done.returncode == 1 and "mpfs_partition.defsyms is missing" in done.stderr, done.stderr
        assert not lst.exists()
    with_tmp(one)


@case("the output is deterministic: another directory, hash seed, umask and time zone give the same bytes")
def _():
    def one(tmp):
        a, b = Path(tmp, "a"), Path(tmp, "b" * 20)
        a.mkdir()
        b.mkdir()
        env = dict(os.environ, PYTHONHASHSEED="7", TZ="Pacific/Auckland")
        first = run([*CASES["u54_secondary_scratchpad"], "--output", "x/mpfs_partition.ads"], cwd=a)
        second = run([*CASES["u54_secondary_scratchpad"], "--output", "y/mpfs_partition.ads"], cwd=b, env=env)
        assert first.returncode == second.returncode == 0
        for name in ("mpfs_partition.ads", "mpfs_partition.defsyms"):
            assert (a / "x" / name).read_bytes() == (b / "y" / name).read_bytes(), name
    with_tmp(one)


@case("both outputs start with the licence header assembled by gen_ada.spdx; the package has no body")
def _():
    for name in CASES:
        package = (FIX / name / "mpfs_partition.ads").read_text()
        assert package.startswith(spdx.header("ada", "Apache-2.0")), name
        listing = (FIX / name / "mpfs_partition.defsyms").read_text()
        assert listing.startswith(spdx.header("shell", "Apache-2.0")), name
        assert "package MPFS_Partition is" in package and "pragma Pure;" in package
        assert not re.search(r"^\s*package body", package, re.M)
        assert package.rstrip().endswith("end MPFS_Partition;")


@case("defaults: the E51 console is MMUART0, a U54 console MMUART1, LIM is 15 ways (1920 KB), 1 primary hart")
def _():
    def one(tmp):
        _, e51 = generate(["--hart", "e51"], tmp)
        assert e51["__mpfs_console_base"] == "0x20000000" and e51["__mpfs_harts_mask"] == "1"
        assert e51["__mpfs_boot_role"] == "1" and e51["__mpfs_console_init"] == "1"
        assert (e51["__mpfs_console_dlr"], e51["__mpfs_console_dfr"]) == ("22", "0")
        assert e51["MPFS_LIM_LENGTH"] == "0x1e0000" and int(e51["MPFS_LIM_LENGTH"], 16) == 15 * 128 * 1024
        assert e51["MPFS_SCRATCHPAD_LENGTH"] == "0x0"
        assert (e51["__stack_size"], e51["__interrupt_stack_size"]) == ("16384", "8192")
        _, u54 = generate(["--hart", "u54"], tmp)
        assert u54["__mpfs_console_base"] == "0x20100000" and u54["__mpfs_harts_mask"] == "2"
        package, _ = generate(["--hart", "u54"], tmp)
        for text in ("Cache_Ways               : constant := 1;", "LIM_Ways                 : constant := 15;",
                     "Scratchpad_Ways          : constant := 0;"):
            assert text in package, text
    with_tmp(one)


@case("the default console is the MMUART of the lowest hart of the mask; --console overrides it")
def _():
    def one(tmp):
        bases = {0: "0x20000000", 1: "0x20100000", 2: "0x20102000", 3: "0x20104000", 4: "0x20106000"}
        _, got = generate(["--hart", "e51"], tmp)
        assert got["__mpfs_console_base"] == bases[0]
        for hart in range(1, 5):
            _, got = generate(["--hart", "u54", "--harts", str(hart)], tmp)
            assert got["__mpfs_console_base"] == bases[hart], hart
            assert (got["__mpfs_console_dlr"], got["__mpfs_console_dfr"]) == (("21", "45") if hart == 4 else ("22", "0"))
        for harts, lowest in (("2-4", 2), ("4,3", 3), ("1,4", 1), ("1-4", 1)):
            _, got = generate(["--hart", "u54", "--harts", harts], tmp)
            assert got["__mpfs_console_base"] == bases[lowest], harts
        _, got = generate(["--hart", "e51", "--harts", "0,3"], tmp)
        assert got["__mpfs_console_base"] == bases[0]
        _, got = generate(["--hart", "u54", "--harts", "3", "--console", "mmuart0"], tmp)
        assert got["__mpfs_console_base"] == bases[0]
        _, got = generate(["--hart", "u54", "--harts", "3", "--console", "none"], tmp)
        assert got["__mpfs_console_base"] == "0x0"
    with_tmp(one)


@case("the harts: U54 hart 1 is the default, --harts 2 to 4, a set and a range give their masks; --mask is raw")
def _():
    def one(tmp):
        for args, mask in ((["--harts", "1"], "2"), (["--harts", "2"], "4"), (["--harts", "3"], "8"),
                           (["--harts", "4"], "16"), (["--harts", "1-4"], "30"), (["--harts", "1,3"], "10"),
                           (["--mask", "0x1f"], "31")):
            _, values = generate(["--hart", "u54", *args], tmp)
            assert values["__mpfs_harts_mask"] == mask, (args, values["__mpfs_harts_mask"])
    with_tmp(one)


@case("the console: the five MMUARTs (MMUART4 with the fraction 45), none and init 0")
def _():
    def one(tmp):
        want = {"mmuart0": ("0x20000000", "22", "0"), "mmuart1": ("0x20100000", "22", "0"),
                "mmuart2": ("0x20102000", "22", "0"), "mmuart3": ("0x20104000", "22", "0"),
                "mmuart4": ("0x20106000", "21", "45"), "none": ("0x0", "22", "0")}
        for console, values in want.items():
            _, got = generate(["--hart", "e51", "--console", console, "--console-init", "0"], tmp)
            assert (got["__mpfs_console_base"], got["__mpfs_console_dlr"], got["__mpfs_console_dfr"]) == values
            assert got["__mpfs_console_init"] == "0"
    with_tmp(one)


@case("the memory profiles: lim and envm 15 ways of LIM, scratchpad 13 ways of LIM and 2 of scratchpad")
def _():
    def one(tmp):
        for memory, lim, pad in (("lim", "0x1e0000", "0x0"), ("envm", "0x1e0000", "0x0"),
                                 ("scratchpad", "0x1a0000", "0x40000")):
            package, got = generate(["--hart", "e51", "--memory", memory], tmp)
            assert (got["MPFS_LIM_LENGTH"], got["MPFS_SCRATCHPAD_LENGTH"]) == (lim, pad), memory
            assert "Cache_Ways               : constant := 1;" in package
        _, got = generate(["--hart", "e51", "--cache-ways", "0", "--lim-ways", "12", "--scratchpad-ways", "4"], tmp)
        assert (got["MPFS_LIM_LENGTH"], got["MPFS_SCRATCHPAD_LENGTH"]) == ("0x180000", "0x80000")
    with_tmp(one)


@case("the local memories: the ITIM goes to the harts of the mask, the generic window follows its first hart")
def _():
    def one(tmp):
        _, got = generate(["--hart", "u54", "--harts", "2,3", "--itim-length", "0x4000"], tmp)
        assert [got[f"MPFS_U54_{n}_ITIM_LENGTH"] for n in (1, 2, 3, 4)] == ["0x0", "0x4000", "0x4000", "0x0"]
        assert got["MPFS_E51_ITIM_LENGTH"] == "0x0"
        assert (got["MPFS_LOCAL_ITIM_ORIGIN"], got["MPFS_LOCAL_ITIM_LENGTH"]) == ("0x1810000", "0x4000")
        _, got = generate(["--hart", "u54", "--harts", "4"], tmp)
        assert (got["MPFS_LOCAL_ITIM_ORIGIN"], got["MPFS_LOCAL_ITIM_LENGTH"]) == ("0x1800000", "0x0")
        _, got = generate(["--hart", "e51", "--dtim-length", "0x2000"], tmp)
        assert got["MPFS_DTIM_LENGTH"] == "0x2000"
    with_tmp(one)


@case("the secondary stack follows the profile unless it is given")
def _():
    def one(tmp):
        for profile, size in (("light", "16384"), ("light-tasking", "8192"), ("embedded", "16384")):
            package, _ = generate(["--hart", "e51", "--profile", profile], tmp)
            assert f"Secondary_Stack_Size     : constant := {size};" in package, profile
        package, _ = generate(["--hart", "e51", "--secondary-stack-size", "4096"], tmp)
        assert "Secondary_Stack_Size     : constant := 4096;" in package
    with_tmp(one)


@case("the interrupt stack follows the profile unless it is given: 8 KiB, and 12 912 bytes for embedded")
def _():
    def one(tmp):
        for profile, size in (("light", "8192"), ("light-tasking", "8192"), ("embedded", "12912")):
            package, got = generate(["--hart", "u54", "--profile", profile], tmp)
            assert f"Interrupt_Stack_Size     : constant := {size};" in package, profile
            assert got["__interrupt_stack_size"] == size, profile
        assert 12912 % 16 == 0
        for profile in ("light", "embedded"):
            package, got = generate(["--hart", "e51", "--profile", profile, "--interrupt-stack-size", "4096"], tmp)
            assert "Interrupt_Stack_Size     : constant := 4096;" in package, profile
            assert got["__interrupt_stack_size"] == "4096", profile
    with_tmp(one)


@case("the clock: Clocks.Rtc_Toggle_Hz is 1 MHz by default, --rtc-toggle-hz changes it, the check is not refused here")
def _():
    def one(tmp):
        package, _ = generate(["--hart", "e51"], tmp)
        assert "Rtc_Toggle_Hz : constant := 1_000_000;" in package
        assert "System.BB.Board_Parameters.Clock_Frequency /= Clocks.Rtc_Toggle_Hz" in package
        package, got = generate(["--hart", "e51", "--rtc-toggle-hz", "999999"], tmp)
        assert "Rtc_Toggle_Hz : constant := 999_999;" in package
        assert "pragma Pure;" in package
        assert not any("rtc" in name.lower() for name in got), "the clock is not a link symbol"
    with_tmp(one)


@case("the list: every link symbol once, in the order of VALUE_SYMBOLS; --omit leaves exactly one out")
def _():
    def one(tmp):
        _, got = generate(["--hart", "e51"], tmp)
        assert list(got) == list(standalone.VALUE_SYMBOLS)
        for name in standalone.VALUE_SYMBOLS:
            _, got = generate(["--hart", "e51", "--omit", name], tmp)
            assert name not in got and len(got) == len(standalone.VALUE_SYMBOLS) - 1, name
    with_tmp(one)


@case("the contract: every value symbol is used by the linker scripts or the runtime, every layout symbol "
      "is defined by the linker scripts")
def _():
    crate = ROOT / "crates" / "mpfs_rts"
    ld = "".join(p.read_text() for p in sorted((crate / "ld").glob("*.ld")))
    runtime = "".join(p.read_text(errors="replace") for p in sorted((crate / "mpfs").rglob("*")) if p.is_file())
    for name in standalone.VALUE_SYMBOLS:
        assert name in ld or name in runtime, f"{name} is read by neither the linker scripts nor the runtime"
    for name in standalone.LAYOUT_SYMBOLS:
        assert re.search(r"^\s*(PROVIDE\(\s*)?" + re.escape(name) + r"\s*=", ld, re.M), \
            f"{name} is not defined by ld/*.ld"
    assert not set(standalone.VALUE_SYMBOLS) & set(standalone.LAYOUT_SYMBOLS)


@case("the package is flat: every Compile_Time_Error names a static Boolean constant declared above it, "
      "with names and literals only")
def _():
    for name in CASES:
        text = (FIX / name / "mpfs_partition.ads").read_text()
        declared = {}
        for found in re.finditer(r"^   (\w+)\s*: constant (Boolean )?:=\s*(.*?);", text, re.M | re.S):
            declared[found.group(1)] = (found.group(2), found.group(3))
        pragmas = re.findall(r"pragma Compile_Time_Error\s*\(\s*(\w+),", text)
        assert len(pragmas) >= 14, (name, len(pragmas))
        for check in pragmas:
            kind, expression = declared[check]
            assert kind, f"{check} is not a Boolean constant"
            # the clock check names the runtime's constant and the nested package Clocks: both static
            expression = expression.replace("System.BB.Board_Parameters.Clock_Frequency", "Clock_Frequency")
            expression = expression.replace("Clocks.Rtc_Toggle_Hz", "Clock_Frequency")
            for word in re.findall(r"[A-Za-z_][A-Za-z_0-9]*", re.sub(r"16#[0-9A-F_]+#", "", expression)):
                assert word in declared or word == "Clock_Frequency" or word in ("and", "or", "then", "else", "mod"), (check, word)
            assert "'" not in expression and "(" not in expression, f"{check} is not a flat expression"
        for line in text.splitlines():
            assert len(line) <= 79, (name, line)


@case("inputs it refuses: status 2, a message, nothing written")
def _():
    bad = [(["--hart", "e51", "--console", "mmuart9"], "invalid choice"),
           (["--hart", "e51", "--console", "MMUART0"], "invalid choice"),
           (["--hart", "z80"], "invalid choice"),
           ([], "--hart"),
           (["--hart", "e51", "--profile", "full"], "invalid choice"),
           (["--hart", "e51", "--memory", "ddr"], "invalid choice"),
           (["--hart", "e51", "--stack-size", "big"], "not an integer"),
           (["--hart", "e51", "--stack-size", "-16"], "negative"),
           (["--hart", "e51", "--interrupt-stack-size", ""], "not an integer"),
           (["--hart", "e51", "--role", "boss"], "not an integer"),
           (["--hart", "u54", "--harts", "5"], "not a set of harts"),
           (["--hart", "u54", "--harts", "3-1"], "not a set of harts"),
           (["--hart", "u54", "--harts", "1,x"], "not a set of harts"),
           (["--hart", "u54", "--harts", ""], "not a set of harts"),
           (["--hart", "u54", "--harts", "1", "--mask", "2"], "not allowed with"),
           (["--hart", "e51", "--console-init", "2"], "invalid choice"),
           (["--hart", "e51", "--omit", "__mpfs_nothing"], "invalid choice"),
           (["--hart", "e51", "--itim-length", "0x"], "not an integer"),
           (["--hart", "e51", "--no-such-option"], "unrecognized arguments")]
    for args, message in bad:
        def one(tmp, args=args, message=message):
            done = run([*args, "--output", str(Path(tmp) / "o" / "mpfs_partition.ads")])
            assert done.returncode == 2, (args, done.returncode, done.stderr)
            assert message in done.stderr, (args, done.stderr)
            assert not (Path(tmp) / "o").exists(), (args, "wrote something")
        with_tmp(one)


@case("rule violations are not refused: the package carries the value and the Ada check refuses it")
def _():
    def one(tmp):
        for args, text in ((["--hart", "e51", "--harts", "0,1"], "Harts_Mask               : constant := 16#3#;"),
                           (["--hart", "e51", "--mask", "0x20"], "Harts_Mask               : constant := 16#20#;"),
                           (["--hart", "e51", "--mask", "0"], "Harts_Mask               : constant := 16#0#;"),
                           (["--hart", "e51", "--role", "2"], "Boot_Role                : constant := 2;"),
                           (["--hart", "e51", "--stack-size", "16392"], "Stack_Size               : constant := 16392;"),
                           (["--hart", "e51", "--interrupt-stack-size", "8200"], ": constant := 8200;"),
                           (["--hart", "e51", "--secondary-stack-size", "1000"], ": constant := 1000;"),
                           (["--hart", "e51", "--console", "ram_fifo"], "Console_Kind             : constant := 2;"),
                           (["--hart", "e51", "--cache-ways", "2"], "Cache_Ways               : constant := 2;"),
                           (["--hart", "e51", "--cache-ways", "0", "--lim-ways", "16"],
                            "LIM_Ways                 : constant := 16;"),
                           (["--hart", "u54", "--dtim-length", "0x1000"], "DTIM_Length              : constant := 16#1000#;"),
                           (["--hart", "e51", "--itim-length", "0x4000"], "ITIM_Length_0            : constant := 16#4000#;")):
            package, _ = generate(args, tmp)
            assert text in package, (args, text)
    with_tmp(one)


finish()
