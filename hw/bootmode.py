#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Switch the boot mode (0..3) of a PolarFire SoC board with fpgenprog, through the FlashPro.

    bootmode.py N [ELF] [--yes] [--dry-run] [--prepare-only] [--workdir DIR] [--lab FILE]
                [--die DIE] [--package PKG] [--flashpro ID] [--verify]
                [--snvm-page PAGE] [--usk KEY] [--encrypt] [--keys PRIVATE.pem PUBLIC.pem]

A Python port of the Java mpfsBootmodeProgrammer of Microchip (hw/bootprog.py; no Java): it makes the image of the
boot mode from the boot program ELF (a header or a certificate in front for the boot modes 1 to 3), builds an
fpgenprog project with it, lets fpgenprog generate the differential bitstream (Libero) and programs it through
FlashPro. The paths of fpgenprog (full path, file name included), the die, the package and the FlashPro come
from hw/lab.conf, whose defaults are in hw/lab.conf.example; objcopy and readelf come from the pinned GNAT cross
toolchain. The boot program ELF is a file of any directory; without ELF the example bare_hello is built (./x build
bare_hello) and used. Boot mode 0 (idle boot) needs no boot program. Without --lab, LAB_CONF and hw/lab.conf,
hw/lab.conf.example is copied to hw/lab.conf first, without its header lines.

The programming is PERMANENT: it survives power cycles, it is undone only by switching again or by programming
another design, and it rewrites the configuration of the FPGA part. So nothing is written to the board unless
--yes is given or the word "yes" is typed at the prompt; without --yes and without a terminal the script refuses
(exit status 2). The image and the bitstream are made first, in <workdir>/bootmode<N>/, and the prompt comes after
that. --dry-run does nothing and only says what it would do; --prepare-only makes the image, the project and the
bitstream and stops before the programming (no prompt, no FlashPro needed).

With more than one FlashPro connected, --flashpro ID (or FLASHPRO_ID in lab.conf) names the one to use: the name the
programming tools of Microchip give it, which ./x hw program --scan lists with the model. It is not in general the USB
serial number that ./x hw flashpros shows, and a FlashPro whose USB descriptor has no serial number (shown with - there) has
only this name. Without FLASHPRO_ID, a FlashPro5 that FLASHPRO_SERIAL names is taken to be S2 and that serial number (an
assumption), and otherwise FLASHPRO_SERIAL is used as it is.
fpgenprog cannot pick one of several FlashPros: its script runs the action on every connected programmer (both were programmed
when two were connected). So FlashPro Express (FPEXPRESS in lab.conf, or the one next to fpgenprog) is asked which
programmers are connected. With one and none named, that one is taken and fpgenprog programs. With several and none named, or a
name that is not among them, the script stops before it does anything (exit status 2) and lists them; with a name the image and
the bitstream are made with fpgenprog and the programming file it leaves in the project is programmed with ./x hw program, for
that programmer only (not run on a board with two FlashPros). Without FlashPro Express the name is written into the project as
a minimal element, which fpgenprog does not honour with several connected: before it programs, the script runs a verify (it
writes nothing) and refuses to go on if the output of fpgenprog shows any other programmer. After every run the programmers its
output names are printed.

The boot mode 2 options (--snvm-page, --usk, --encrypt) and the boot mode 3 option (--keys) are those of the
Java tool; a USK of zero or none is replaced by a generated one that is saved next to the image. Boot mode
3 without --keys generates a key pair whose private key is NOT saved. Boot mode 0 was verified on an Icicle Kit by
the project owner; the boot modes 1 to 3 have not been run on a board (their images and fpgenprog calls are
identical to those of the Java tool, see tests/host/hw).

Every set-up error is printed together with the help text, which describes the boot modes.

Exit status: 0 programmed (or --dry-run, --prepare-only), 1 the prompt was not answered with "yes", or a step
failed, 2 a set-up error (bad N or option, missing fpgenprog, toolchain or ELF, no --yes without a terminal,
OpenOCD running), 130 after Ctrl+C.
"""
import argparse
import os
import shlex
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import Callable

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bootprog  # noqa: E402
import flashpros  # noqa: E402
import fpexpress  # noqa: E402
import lab  # noqa: E402

BARE_HELLO = "bare_hello"

MODES_HELP = """\
boot modes (as mpfsBootmodeProgrammer describes them):
  0  idle boot
  1  non-secure boot from eNVM
  2  user secure boot from sNVM
  3  factory secure boot from eNVM

ELF is the boot program for boot modes 1 to 3 (mode 0 needs none), a file of any directory. Mode 1 and 3 programs
are linked for eNVM page 1 or higher (0x20220100 ...: the page in front of the image takes the header or the
certificate), mode 2 programs for the LIM (0x08000000 ...). Without ELF the example bare_hello is built and used (it
is linked into the L2 LIM, not for the linkage of a boot mode: a stand-in until a real image is given).
Stop OpenOCD before you run this (./x hw openocd): it and the programmer both use the FlashPro.
The programming is permanent: see above. Defaults of die, package, fpgenprog and FlashPro: hw/lab.conf.example."""


class Parser(argparse.ArgumentParser):
    """An argument error is printed with the help text, like every other set-up error."""

    def error(self, message):
        self.exit(2, f"{paint('error', 'bootmode: ' + message)}\n\n{self.format_help()}")


NEXT_STEPS = """\
bootmode: the programmer ended with status 0. What to do now:
  1. Power-cycle the board (the new boot mode takes effect at power-on).
  2. Start OpenOCD (./x hw openocd) and run ./x hw reset.
  3. Halt the E51 (hart 0) and read its PC. In boot mode 0 the hart waits in the boot stub (SCB_REGS.BOOT_ROM0..7),
     so the PC of a halted hart is between 0x20003120 and 0x2000312E (docs/lab/openocd.md, "The boot stub").
     Another boot mode runs other code.
  If the PC does not match, the switch did not take effect: run this command again or restore the boot mode that
  docs/lab/icicle.md records for the board."""


def mode(text: str) -> int:
    """The boot mode: an integer 0..3."""
    if not text.isdigit() or not 0 <= int(text) <= 3:
        raise argparse.ArgumentTypeError(f"'{text}' is not a boot mode (0, 1, 2 or 3)")
    return int(text)


COLORS = {"error": "1;31", "warn": "1;33", "ok": "1;32", "info": "36"}


def use_color(stream) -> bool:
    """Colour only on a terminal that supports it: NO_COLOR turns it off, FORCE_COLOR turns it on, and TERM=dumb
    or a stream that is not a terminal get none."""
    if os.environ.get("NO_COLOR"):
        return False
    if os.environ.get("FORCE_COLOR"):
        return True
    return stream.isatty() and os.environ.get("TERM", "dumb") != "dumb"


def paint(kind: str, text: str, stream=None) -> str:
    """<text> in the colour of <kind> (error, warn, ok, info) if <stream> (default stderr) supports colour."""
    stream = stream or sys.stderr
    return f"\033[{COLORS[kind]}m{text}\033[0m" if use_color(stream) else text


def say(kind: str, text: str, stream=None, **kwargs) -> None:
    """Print one message of the script, coloured by <kind>."""
    stream = stream or sys.stdout
    print(paint(kind, text, stream), file=stream, **kwargs)


def emit(kind: str, text: str) -> None:
    """The messages of bootprog: the lines of the tools as they are, warnings and errors coloured on stderr."""
    if kind == "info":
        print(text, flush=True)
    else:
        say(kind, text, sys.stderr, flush=True)


def fail(message: str):
    """A set-up error: the message and the help text, exit status 2."""
    raise SystemExit(f"{paint('error', 'bootmode: ' + message)}\n\n{PARSER.format_help()}")


def resolve_tools(lab_conf: dict[str, str]) -> tuple[Path, Path]:
    """fpgenprog and the bin directory of the cross toolchain, resolved; a missing one is an error that says what
    to do."""
    fpgenprog = lab_conf["FPGENPROG"]
    if not os.path.isabs(fpgenprog) or not os.path.isfile(fpgenprog) or not os.access(fpgenprog, os.X_OK):
        fail(f"FPGENPROG '{fpgenprog}' is not the full path of the fpgenprog executable, file name included "
             "(a name on PATH is not enough): it comes with Libero SoC or the Program Debug Tool; "
             "set FPGENPROG in hw/lab.conf")
    try:
        bin_dir = lab.toolchain_bin()
    except SystemExit as e:
        fail(str(e.code))
    return Path(fpgenprog), bin_dir


def openocd_running(lab_conf: dict[str, str]) -> bool:
    """True if something answers on the OpenOCD telnet port of lab.conf: an OpenOCD holds the FlashPro."""
    try:
        with socket.create_connection((lab_conf["OCD_HOST"], int(lab_conf["OCD_PORT"])), timeout=1.0):
            return True
    except OSError:
        return False


def boot_elf(elf: str | None, mode_number: int, dry_run: bool) -> Path | None:
    """The boot program. A given ELF is used where it is (a missing one is a set-up error); without one,
    bare_hello is built (not in a dry run, which names it only). Boot mode 0 (idle boot) takes none: an ELF
    that is given is ignored, as the Java tool does."""
    if mode_number == 0:
        if elf is not None:
            say("warn", f"bootmode: boot mode 0 needs no boot program: ignoring {elf}", sys.stderr)
        return None
    if elf is not None:
        source = Path(elf)
        if not source.is_file():
            fail(f"ELF '{elf}' does not exist")
        return source
    if dry_run:
        return Path(f"{BARE_HELLO}.elf")
    built = subprocess.run([str(lab.ROOT / "x"), "build", BARE_HELLO, "--hart", "e51"]).returncode
    if built != 0:
        fail(f"building {BARE_HELLO} for the boot program failed (status {built}): give an ELF or fix the build")
    found = sorted((lab.ROOT / "examples" / BARE_HELLO / "bin-e51").glob("*.elf"))
    if not found:
        fail(f"building {BARE_HELLO} produced no bin-e51/*.elf: give an ELF")
    return found[0]


def confirm(mode_number: int, command: list[str]) -> bool:
    """True if the person typed "yes". A run without a terminal refuses (exit status 2)."""
    if not sys.stdin.isatty():
        fail("refusing to write without --yes: this changes the FPGA configuration for good "
             "and there is no terminal to ask (nothing was done)")
    say("warn", "This programs the board through FlashPro. The change is PERMANENT: it survives power cycles and is undone "
          "only by switching again or by programming another design. It rewrites the configuration of the FPGA part.")
    print(f"Command: {shlex.join(command)}")
    answer = input(f"Switch the boot mode to {mode_number}? Type 'yes' to go on: ")
    return answer.strip() == "yes"


def ensure_lab_conf(named: str | None) -> None:
    """Without --lab, LAB_CONF and hw/lab.conf, create hw/lab.conf (git ignores it) from hw/lab.conf.example,
    without the header of the example (its first comment paragraph, up to the first line that is only "#"), and
    say so."""
    target = lab.HERE / "lab.conf"
    if named or os.environ.get("LAB_CONF") or target.exists():
        return
    try:
        lines = lab.EXAMPLE.read_text().splitlines(keepends=True)
        if "#\n" in lines:
            lines = lines[lines.index("#\n") + 1:]
        target.write_text("".join(lines))
    except OSError as e:
        say("warn", f"bootmode: cannot create {target} from {lab.EXAMPLE.name}: {e}; the defaults of the example are used",
            sys.stderr)
        return
    say("warn", f"bootmode: {target} did not exist: created it from {lab.EXAMPLE.name}. Edit it if your Libero is installed "
        "elsewhere.", sys.stderr)


def make_parser() -> argparse.ArgumentParser:
    ap = Parser(prog="./x hw bootmode", description=__doc__.split("\n")[0] + "\n\nThis programs the board through FlashPro. The change is PERMANENT: it survives "
                "power cycles and is undone only by switching again or by programming another design. It rewrites the "
                "configuration of the FPGA part.",
                epilog=MODES_HELP, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", type=mode, metavar="N", help="boot mode 0..3 (see below)")
    ap.add_argument("elf", nargs="?", metavar="ELF", help="boot program for modes 1 to 3 (default: the example bare_hello, built; none for mode 0)")
    ap.add_argument("--yes", action="store_true", help="do not ask: write the boot mode (PERMANENT, see above)")
    ap.add_argument("--dry-run", action="store_true", help="say what would be done and do nothing")
    ap.add_argument("--prepare-only", action="store_true",
                    help="make the image, the project and the bitstream, but do not program (the --dryrun of the Java tool)")
    ap.add_argument("--workdir", metavar="DIR", default=str(lab.ROOT / "build" / "bootmode"),
                    help="where bootmode<N>/ is written: the image, the project, debugLog.txt (default: build/bootmode)")
    ap.add_argument("--lab", metavar="FILE", help="lab settings (default: hw/lab.conf, on top of hw/lab.conf.example)")
    ap.add_argument("--die", metavar="DIE", help=f"target die (default: BOOTMODE_DIE of lab.conf); one of {', '.join(bootprog.DIES)}")
    ap.add_argument("--package", metavar="PKG", help=f"target package (default: BOOTMODE_PACKAGE of lab.conf); one of {', '.join(bootprog.PACKAGES)}")
    ap.add_argument("--flashpro", metavar="ID",
                    help="the FlashPro to use when several are connected, as the programming tools of Microchip name it (./x hw program --scan "
                    "lists the names), not necessarily its USB serial number (default: FLASHPRO_ID of lab.conf, else a FlashPro5 "
                    "that FLASHPRO_SERIAL names as S2 and the serial number, else FLASHPRO_SERIAL, else the one fpgenprog picks)")
    ap.add_argument("--verify", action="store_true", help="verify the target after programming")
    ap.add_argument("--snvm-page", "--snvm_page", dest="snvm_page", metavar="PAGE", type=int, default=0,
                    help=f"boot mode 2 only: the sNVM page the image is stored from (0 to {bootprog.SNVM_PAGES - 1}, default 0)")
    ap.add_argument("--usk", metavar="KEY",
                    help="boot mode 2 only: the User sNVM Key, 12 bytes as 24 hex digits (0x in front is allowed); 0 or none: a random one, saved next to the image")
    ap.add_argument("--encrypt", action="store_true", help="boot mode 2 only: store the image as authenticated ciphertext instead of authenticated plaintext")
    ap.add_argument("--keys", nargs=2, metavar=("PRIVATE", "PUBLIC"),
                    help="boot mode 3 only: the ECDSA P-384 key pair of the certificate, PEM files (private: PKCS#8 without password; public: X.509); default: a generated pair whose private key is not saved")
    return ap


PARSER = make_parser()


def describe(opt: bootprog.Options) -> str:
    """One line on what is to be done."""
    parts = [f"boot mode {opt.mode}", f"die {opt.die}", f"package {opt.package}",
             f"boot program {opt.elf if opt.elf else '(none)'}", f"output {opt.out_dir}",
             f"fpgenprog {opt.fpgenprog}", f"FlashPro {opt.flashpro or 'the one fpgenprog picks'}"]
    return ", ".join(parts)


def summary(done: bootprog.Prepared) -> None:
    """What prepare() made, for the person who answers the prompt."""
    opt = done.opt
    say("info", f"bootmode: prepared in {opt.out_dir}")
    if done.boot_vector is not None:
        say("info", f"bootmode: boot vector 0x{done.boot_vector:08X}, image {done.size} bytes")
    if done.usk_file is not None:
        say("info", f"bootmode: USK {opt.usk} (saved in {done.usk_file}: keep it)")
    if done.public_key_file is not None:
        say("info", f"bootmode: public key in {done.public_key_file}")
    if not done.private_key_saved:
        say("warn", "bootmode: the private key of the certificate was generated and is not saved", sys.stderr)


def name_programmer(lab_conf: dict[str, str], workdir: Path,
                    requested: str | None) -> tuple[str | None, str | None, bool]:
    """The programmer to use, its <programmer> element for the project of fpgenprog, and whether more than one programmer is
    connected, from FlashPro Express.

    With more than one FlashPro connected fpgenprog does not know which one to take, so the project has to name it, as the
    project of ./x hw program does. FlashPro Express lists the programmers and writes that element (with type and connection).
    <requested> (--flashpro, FLASHPRO_ID, ...) must be one of them; without it one programmer is taken, several are an error.
    FlashPro Express not found: (requested, None, False): the project gets a minimal element, or none, as before."""
    path = fpexpress.resolve_fpexpress(lab_conf, required=False)
    if path is None:
        say("warn", "bootmode: FlashPro Express not found (FPEXPRESS in hw/lab.conf): the programmer is not checked and, with "
            "more than one FlashPro, fpgenprog picks one", sys.stderr)
        return requested, None, False
    run = fpexpress.Run(path, workdir / "fpexpress", log_name="fpexpress.log")
    try:
        names, models, _ = fpexpress.find_programmers(run, run.workdir / fpexpress.JOB_DIR)
        found = ", ".join(f"{n} ({models[n]})" if n in models else n for n in names) or "none"
        if requested and requested not in names:
            fail(f"the FlashPro '{requested}' is not among the programmers FlashPro Express sees: {found}. "
                 "Name one of them with --flashpro or FLASHPRO_ID (./x hw flashpros lists the USB devices)")
        if not requested and len(names) != 1:
            fail("no FlashPro was found by FlashPro Express (log: " + str(run.log.name) + ")" if not names else
                 f"more than one FlashPro is connected: {found}. Name the one to program with --flashpro or FLASHPRO_ID")
        name = requested or names[0]
        job = run.workdir / fpexpress.JOB_DIR
        return name, fpexpress.programmer_element(run, job, name), len(names) > 1
    except fpexpress.FpExpressError as e:
        fail(str(e))
    finally:
        run.close()


def fpexpress_command(opt: bootprog.Options, lab_arg: str | None) -> Callable[[str], list[str]]:
    """The command for an action when more than one FlashPro is connected: ./x hw program on the PPD file that fpgenprog made, for
    the one programmer. fpgenprog cannot do it: it has no option for a programmer, and its script runs the action on every
    connected programmer (seen with two FlashPros: both were programmed, one of them failed)."""
    def command(action: str) -> list[str]:
        ppd = opt.project_dir / "proj_fp" / "target.ppd"
        if not ppd.is_file():
            raise bootprog.BootError(f"fpgenprog made no programming file {ppd}: it cannot be programmed through FlashPro Express")
        return [sys.executable, str(Path(__file__).resolve().parent / "program.py"), str(ppd), "--programmer", str(opt.flashpro),
                "--action", action, "--yes", "--workdir", str(opt.workdir / "program"), *(["--lab", lab_arg] if lab_arg else [])]
    return command


def main(argv=None):
    a = PARSER.parse_args(argv)
    ensure_lab_conf(a.lab)
    lab_conf = lab.load(a.lab)
    fpgenprog, bin_dir = resolve_tools(lab_conf)
    programming = not a.dry_run and not a.prepare_only
    if programming and openocd_running(lab_conf):
        fail(f"OpenOCD is running ({lab_conf['OCD_HOST']}:{lab_conf['OCD_PORT']} answers): stop it first, it and the "
             "programmer both use the FlashPro (nothing was done)")
    if programming and not a.yes and not sys.stdin.isatty():
        fail("refusing to write without --yes: this changes the FPGA configuration for good "
             "and there is no terminal to ask (nothing was done)")
    workdir = Path(a.workdir).resolve()
    elf = boot_elf(a.elf, a.mode, a.dry_run)
    requested = (a.flashpro or lab_conf.get("FLASHPRO_ID") or flashpros.flashpro5_id(lab_conf)
                 or lab_conf.get("FLASHPRO_SERIAL") or None)
    element, several = None, False
    if programming:
        requested, element, several = name_programmer(lab_conf, workdir, requested)
    usk = bootprog.normalize_usk(a.usk)
    opt = bootprog.Options(
        workdir=workdir, mode=bootprog.BootMode(a.mode), fpgenprog=fpgenprog, bin_dir=bin_dir,
        die=(a.die or lab_conf["BOOTMODE_DIE"]).upper(), package=(a.package or lab_conf["BOOTMODE_PACKAGE"]).upper(),
        elf=elf, usk=usk, snvm_page=a.snvm_page, encrypt=a.encrypt,
        private_key=Path(a.keys[0]) if a.keys else None, public_key=Path(a.keys[1]) if a.keys else None,
        verify=a.verify, prepare_only=a.prepare_only,
        flashpro=requested, programmer_element=element)
    if several:
        opt.program_command = fpexpress_command(opt, a.lab)
    log = bootprog.Log(emit)
    try:
        # a dry run names the stand-in boot program without building it, so the ELF may not exist yet
        bootprog.validate(opt, log, check_elf=not (a.dry_run and a.elf is None))
    except bootprog.SetupError as e:
        fail(str(e))
    if a.dry_run:
        say("info", f"bootmode: dry run, nothing is done. Would make the image and the fpgenprog project and generate the "
            f"bitstream, then program: {describe(opt)}")
        say("info", f"bootmode: programming command: {shlex.join(bootprog.fp_run_action(opt, 'PROGRAM'))}")
        return 0
    start = time.monotonic()
    try:
        try:
            done = bootprog.prepare(opt, log)
        except bootprog.SetupError as e:
            fail(str(e))
        summary(done)
        if a.prepare_only:
            say("ok", f"bootmode: prepared; not programmed (--prepare-only). The project is {opt.project_dir}")
            return 0
        if not a.yes and not confirm(a.mode, bootprog.action_command(opt, "PROGRAM")):
            say("warn", "bootmode: not confirmed, nothing was written to the board", sys.stderr)
            return 1
        seen = bootprog.flash(done, log)
    except bootprog.BootError as e:
        say("error", f"bootmode: {e}", stream=sys.stderr)
        if log.path is not None:
            say("error", f"bootmode: details in {log.path}; the boot mode was not changed or the board is in an unknown "
                "state: check the output above, the FlashPro connection and fpgenprog, then run it again", stream=sys.stderr)
        return 1
    except KeyboardInterrupt:
        say("error", f"bootmode: interrupted after {time.monotonic() - start:.1f} s; if it was programming, the FPGA "
              "configuration may be half written: run the command again before you trust the board", stream=sys.stderr)
        return 130
    say("info", f"bootmode: the programmer took {time.monotonic() - start:.1f} s")
    if seen == 0:
        say("error", f"bootmode: fpgenprog ended with status 0 but printed nothing: not trusted; check fpgenprog "
              f"({fpgenprog}), then run it again", stream=sys.stderr)
        return 1
    first, _, rest = NEXT_STEPS.partition("\n")
    say("ok", first)
    print(rest)
    return 0


if __name__ == "__main__":
    sys.exit(lab.run(main, uses_hart=False))
