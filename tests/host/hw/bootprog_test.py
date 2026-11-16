#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Tests of hw/bootprog.py, the Python port of the Java mpfsBootmodeProgrammer, without a board.

    bootprog_test.py <bin dir of the pinned gnat_riscv64_elf> <scratch directory>

What it compares with: GOLDEN holds what the Java tool (mpfsBootmodeProgrammer 3.7 from SoftConsole v2022.2,
run with --dryrun and the real fpgenprog from the Program Debug Tool) made from the same boot programs: the
SHA-256 of every file of boot modes 0, 1 and 2 and the argument lines of every fpgenprog call (boot modes 0
to 3). Boot mode 3 is signed with a random number, so its certificate is checked by what must hold (the
header equals the Java header, the signature verifies against the public key, the layout) and not by a hash.
The boot programs are assembled here from one source, so the images are reproducible.

What this cannot show: that fpgenprog behaves like the stand-in (tests/host/hw/fake_fpgenprog.py) on a board, and
that a FlashPro is chosen by its serial number (it is a stand-in that is told to honour the project file).
"""
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "hw"))
import bootprog as bp  # noqa: E402

BIN = Path(sys.argv[1])
TMP = Path(sys.argv[2])
TMP.mkdir(parents=True, exist_ok=True)
LOG = TMP / "fp.log"
FP = TMP / "fpgenprog"
FP.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{ROOT / "tests/host/hw/fake_fpgenprog.py"}" "$@"\n')
FP.chmod(0o755)
os.environ["FAKE_FP_LOG"] = str(LOG)

GOLDEN = json.loads(r"""
{
 "bm0": {
  "files": {
   "bootmode0.hex": "446dab9055b3afe1fd1a61e5b9ea697921babdcfcae8125d239d0cc54c702b95"
  },
  "calls": [
   "new_project --location @W@/bootmode0/fpgenprogProject --target_die MPFS250T_ES --target_package FCVG484",
   "mss_boot_info --location @W@/bootmode0/fpgenprogProject --u_mss_bootmode 0",
   "envm_client --location @W@/bootmode0/fpgenprogProject --number_of_bytes 1 --content_file_format intel-hex --content_file @W@/bootmode0/bootmode0.hex --start_page 0 --client_name bootmode0_0",
   "generate_bitstream --location @W@/bootmode0/fpgenprogProject"
  ]
 },
 "bm1": {
  "files": {
   "app-bm1-dummySbic.bin": "ddc943b1793af6f59c1c8c86f94674d5dc18fe04f1f298cfee85d71ba26fdbd8",
   "app-bm1-p0.bin": "832c79e4de3751ad80c674bced58cbe20e21deef42d4a703b1364d0004d7b4c4",
   "app-bm1-p0.hex": "470cd010cd8de2e040b0f0cee4552b48d2983c3501a98a787bddff39356d1dd7",
   "app.bin": "2f6d7130528cf332557dc2bd5f93a59917eb1bc1dfec529da0bb5e4dd4642637"
  },
  "calls": [
   "new_project --location @W@/bootmode1/fpgenprogProject --target_die MPFS250T_ES --target_package FCVG484",
   "mss_boot_info --location @W@/bootmode1/fpgenprogProject --u_mss_bootmode 1 --u_mss_bootcfg 2022010020220100202201002022010020220100",
   "envm_client --location @W@/bootmode1/fpgenprogProject --number_of_bytes 568 --content_file_format intel-hex --content_file @W@/bootmode1/app-bm1-p0.hex --start_page 0 --client_name bootmode1_0 --mem_file_base_address 20220000",
   "generate_bitstream --location @W@/bootmode1/fpgenprogProject"
  ]
 },
 "bm2": {
  "files": {
   "app-bm2-p3-ap.bin": "0959675817a6c7e677ec3fb33b04d2a8485fd7afbd28957015bbd1f06c3eed15",
   "app-bm2-p3-ap.hex": "03f1876703aa5bda422e1ceed1f7a667072622adcb30c0dcca419d504670410c",
   "app-bm2-usk.txt": "8865fea8edb697169ac2b4f5e6339e16439381033640eeb4f55edbad9bdc2d3d",
   "app.bin": "2f6d7130528cf332557dc2bd5f93a59917eb1bc1dfec529da0bb5e4dd4642637"
  },
  "calls": [
   "new_project --location @W@/bootmode2/fpgenprogProject --target_die MPFS250T_ES --target_package FCVG484",
   "mss_boot_info --location @W@/bootmode2/fpgenprogProject --u_mss_bootmode 2 --u_mss_bootcfg 000000000123456789abcdef0123456700000003",
   "snvm_client --location @W@/bootmode2/fpgenprogProject --number_of_bytes 372 --content_file_format intel-hex --content_file @W@/bootmode2/app-bm2-p3-ap.hex --start_page 3 --client_name bootmode2 --usk_key 0123456789abcdef01234567 --authenticated --mem_file_base_address 08000000 --fabric_access_read 0 --fabric_access_write 0 --mss_access_read 1 --mss_access_write 0",
   "generate_bitstream --location @W@/bootmode2/fpgenprogProject"
  ]
 },
 "bm2enc": {
  "files": {
   "app-bm2-p0-ac.bin": "0959675817a6c7e677ec3fb33b04d2a8485fd7afbd28957015bbd1f06c3eed15",
   "app-bm2-p0-ac.hex": "03f1876703aa5bda422e1ceed1f7a667072622adcb30c0dcca419d504670410c",
   "app-bm2-usk.txt": "8865fea8edb697169ac2b4f5e6339e16439381033640eeb4f55edbad9bdc2d3d",
   "app.bin": "2f6d7130528cf332557dc2bd5f93a59917eb1bc1dfec529da0bb5e4dd4642637"
  },
  "calls": [
   "new_project --location @W@/bootmode2/fpgenprogProject --target_die MPFS250T_ES --target_package FCVG484",
   "mss_boot_info --location @W@/bootmode2/fpgenprogProject --u_mss_bootmode 2 --u_mss_bootcfg 000000000123456789abcdef0123456700000000",
   "snvm_client --location @W@/bootmode2/fpgenprogProject --number_of_bytes 372 --content_file_format intel-hex --content_file @W@/bootmode2/app-bm2-p0-ac.hex --start_page 0 --client_name bootmode2 --usk_key 0123456789abcdef01234567 --encrypted_authenticated --mem_file_base_address 08000000 --fabric_access_read 0 --fabric_access_write 0 --mss_access_read 1 --mss_access_write 0",
   "generate_bitstream --location @W@/bootmode2/fpgenprogProject"
  ]
 },
 "bm3": {
  "files": {
   "app.bin": "2f6d7130528cf332557dc2bd5f93a59917eb1bc1dfec529da0bb5e4dd4642637"
  },
  "calls": [
   "new_project --location @W@/bootmode3/fpgenprogProject --target_die MPFS250T_ES --target_package FCVG484",
   "mss_boot_info --location @W@/bootmode3/fpgenprogProject --u_mss_bootmode 3 --u_mss_bootcfg 0000000000000000000000000000000020220000 --ucskx @X@ --ucsky @Y@ --reset_sbic_version",
   "envm_client --location @W@/bootmode3/fpgenprogProject --number_of_bytes 568 --content_file_format intel-hex --content_file @W@/bootmode3/app-bm3-p0.hex --start_page 0 --client_name bootmode3_0 --mem_file_base_address 20220000",
   "generate_bitstream --location @W@/bootmode3/fpgenprogProject"
  ],
  "sbic_header_sha256": "5630142c6dfccae44c9e428219554ef98c645cd7338bfc3c02512ded134b439d"
 }
}
""")

fails = 0


def check(condition, description):
    global fails
    if condition:
        print(f"ok:   {description}")
    else:
        print(f"FAIL: {description}", file=sys.stderr)
        fails += 1


def raises(exception, needle, description, function, *args, **kwargs):
    """The call raises <exception> and the message has <needle>."""
    try:
        function(*args, **kwargs)
    except exception as e:
        check(needle in str(e), f"{description} (message: {str(e)[:120]})" if needle not in str(e) else description)
        return
    except Exception as e:  # noqa: BLE001
        check(False, f"{description} (raised {type(e).__name__}: {e})")
        return
    check(False, f"{description} (nothing raised)")


# --- the boot programs ----------------------------------------------------------------------------------
SOURCE = TMP / "image.S"
SOURCE.write_text("\t.option norvc\n\t.section .text\n\t.globl _start\n_start:\n\tj _start\n\t.rept 75\n\t.word 0x00000013\n"
                  "\t.endr\n\t.section .data\n\t.word 0xdeadbeef, 0x12345678\n")
ODD = TMP / "odd.S"
ODD.write_text(SOURCE.read_text() + "\t.byte 1\n")
BIG = TMP / "big.S"
BIG.write_text(SOURCE.read_text() + "\t.space 140000\n")


def build(name, address, source=SOURCE):
    """The boot program <name>/app.elf: the Java tool names its files after the ELF, so does the port."""
    elf = TMP / "elf" / name / "app.elf"
    elf.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([str(BIN / "riscv64-elf-gcc"), "-nostdlib", "-march=rv64imac", "-mabi=lp64", "-Wl,-N",
                    f"-Wl,-Ttext={address:#x}", "-o", str(elf), str(source)], check=True, capture_output=True)
    return elf


ENVM = build("envm", 0x20220100)
LIM = build("lim", 0x08000000)
PAGE0 = build("page0", 0x20220000)
LOW = build("low", 0x1000)
ODD_LIM = build("odd_lim", 0x08000000, ODD)
BIG_ENVM = build("big_envm", 0x20220100, BIG)
BIG_LIM = build("big_lim", 0x08000000, BIG)

messages = []
log = bp.Log(lambda kind, text: messages.append((kind, text)))


def options(name, mode, elf=None, **kw):
    return bp.Options(workdir=TMP / name, mode=bp.BootMode(mode), fpgenprog=FP, bin_dir=BIN, elf=elf, **kw)


def calls():
    return LOG.read_text().splitlines() if LOG.exists() else []


def fresh():
    LOG.unlink(missing_ok=True)
    messages.clear()


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


# --- the payload functions ------------------------------------------------------------------------------
check(bp.bootcfg_bm1(0x20220100) == "20220100" * 5, "boot configuration of mode 1: the reset vector five times")
check(bp.bootcfg_bm2(3, "0123456789abcdef01234567") == "000000000123456789abcdef0123456700000003",
      "boot configuration of mode 2: the USK and the start page (as the Java tool writes it)")
check(bp.bootcfg_bm3(0x20220000) == "0000000000000000000000000000000020220000", "boot configuration of mode 3: the SBIC address")
check(bp.xy_hex(5) == "0" * 95 + "5", "a coordinate of the public key is 96 hex digits")
check(bp.envm_page(0x20220100) == 1 and bp.sbic_address_before_image(0x20220100) == 0x20220000,
      "the SBIC lies in the page in front of the image")
check(bp.normalize_usk("0xAB") == "AB" and bp.normalize_usk("AB") == "AB" and bp.normalize_usk(None) is None,
      "a leading 0x of the USK is dropped")
header = bp.make_fake_sbic(0x20220100, 312)
check(len(header) == 256 and header[:4] == bytes.fromhex("6f000010") and header[212:234] == b"BOOT MODE 1 DUMMY SBIC",
      "the header of mode 1 is a page: a jump, the length, the identification")
check(bp.combine_sbic_with_image(b"I" * 4, bytes(208)) == bytes(256) + b"IIII", "the certificate is padded to the next page")

# --- the same as the Java tool, boot modes 0, 1 and 2 ---------------------------------------------------------
for name, mode, elf, kw in (("bm0", 0, None, {}), ("bm1", 1, ENVM, {}),
                            ("bm2", 2, LIM, dict(usk="0123456789abcdef01234567", snvm_page=3)),
                            ("bm2enc", 2, LIM, dict(usk="0123456789abcdef01234567", encrypt=True))):
    fresh()
    opt = options(name, mode, elf, **kw)
    bp.prepare(opt, log)
    gold = GOLDEN[name]
    out = opt.out_dir
    for file, digest in gold["files"].items():
        check((out / file).is_file() and sha(out / file) == digest, f"{name}: {file} is what the Java tool made")
    want = [line.replace("@W@/", f"{opt.workdir}/") for line in gold["calls"]]
    check(calls() == want, f"{name}: the fpgenprog calls are those of the Java tool"
          + ("" if calls() == want else f"\n  got:  {calls()}\n  want: {want}"))
    check((out / "debugLog.txt").is_file(), f"{name}: the debug log is written")

# --- boot mode 3 ----------------------------------------------------------------------------------------
from cryptography.hazmat.primitives import hashes, serialization  # noqa: E402
from cryptography.hazmat.primitives.asymmetric import ec  # noqa: E402

key = ec.generate_private_key(ec.SECP384R1())
PRIVATE, PUBLIC = TMP / "private.pem", TMP / "public.pem"
PRIVATE.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
PUBLIC.write_bytes(key.public_key().public_bytes(serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo))
numbers = key.public_key().public_numbers()


def check_bm3(name, signer_public, x, y):
    out = TMP / name / "bootmode3"
    image = (out / "app.bin").read_bytes()
    sbic = (out / "app-bm3-sbic.bin").read_bytes()
    combined = (out / "app-bm3-p0.bin").read_bytes()
    check(hashlib.sha256(image).hexdigest() == GOLDEN["bm3"]["files"]["app.bin"], f"{name}: the image is the one of the Java tool")
    check(len(sbic) == 208 and hashlib.sha256(sbic[:104]).hexdigest() == GOLDEN["bm3"]["sbic_header_sha256"],
          f"{name}: the 104 bytes of the certificate that are signed equal those of the Java tool")
    check(sbic[56:104] == hashlib.sha384(image).digest(), f"{name}: the certificate holds the SHA-384 of the image")
    der_length = sbic[105] + 2
    try:
        signer_public.verify(sbic[104:104 + der_length], sbic[:104], ec.ECDSA(hashes.SHA384()))
        verified = True
    except Exception:  # noqa: BLE001
        verified = False
    check(verified and not any(sbic[104 + der_length:]), f"{name}: the signature verifies against the public key and the rest is zeros")
    check(combined == sbic + bytes(48) + image, f"{name}: the combined image is the certificate, 48 bytes of zeros and the image")
    want = [line.replace("@W@/", f"{TMP / name}/").replace("@X@", f"{x:096x}").replace("@Y@", f"{y:096x}")
            for line in GOLDEN["bm3"]["calls"]]
    check(calls() == want, f"{name}: the fpgenprog calls are those of the Java tool, with the key of this run"
          + ("" if calls() == want else f"\n  got:  {calls()}\n  want: {want}"))
    xy = (out / "app-bm3-public-key-xy.txt").read_text()
    check(xy == f"ucskx={x:096x}\nucsky={y:096x}\n", f"{name}: the public key is written next to the image")


fresh()
done = bp.prepare(options("bm3", 3, ENVM, private_key=PRIVATE, public_key=PUBLIC), log)
check_bm3("bm3", key.public_key(), numbers.x, numbers.y)
check(done.private_key_saved and not [m for m in messages if m[0] == "warn"], "bm3: keys from files: no warning")

fresh()
opt = options("bm3gen", 3, ENVM)
done = bp.prepare(opt, log)
xy = (opt.out_dir / "app-bm3-public-key-xy.txt").read_text().split()
x, y = (int(line.split("=")[1], 16) for line in xy)
generated = ec.EllipticCurvePublicNumbers(x, y, ec.SECP384R1()).public_key()
check_bm3("bm3gen", generated, x, y)
check(not done.private_key_saved and any("private key is not saved" in t for k, t in messages if k == "warn"),
      "bm3 without keys: a key pair is generated and the warning says the private key is not saved")

other = ec.generate_private_key(ec.SECP384R1())
OTHER = TMP / "other.pem"
OTHER.write_bytes(other.public_key().public_bytes(serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo))
raises(bp.BootError, "does not belong to the private key", "bm3: a public key of another private key is refused",
       bp.prepare, options("bm3x", 3, ENVM, private_key=PRIVATE, public_key=OTHER), log)
P256 = ec.generate_private_key(ec.SECP256R1())
(TMP / "p256.pem").write_bytes(P256.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
(TMP / "p256pub.pem").write_bytes(P256.public_key().public_bytes(serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo))
raises(bp.BootError, "NIST P-384", "bm3: a key of another curve is refused", bp.prepare,
       options("bm3y", 3, ENVM, private_key=TMP / "p256.pem", public_key=TMP / "p256pub.pem"), log)
(TMP / "junk.pem").write_text("not a key\n")
raises(bp.BootError, "Failed to read the ECC", "bm3: a file that is no key is refused", bp.prepare,
       options("bm3z", 3, ENVM, private_key=TMP / "junk.pem", public_key=PUBLIC), log)

# --- a generated USK ------------------------------------------------------------------------------------------
fresh()
opt = options("usk0", 2, LIM, usk="0")
bp.prepare(opt, log)
usk_file = opt.out_dir / "app-bm2-usk.txt"
saved = usk_file.read_text()
check(len(saved) == 24 and int(saved, 16) != 0 and saved == opt.usk, "a USK of zero is replaced by a generated one that is saved")
check(any("randomly generated USK" in t for k, t in messages if k == "warn"), "the generated USK is announced")
check(any(f"--usk_key {saved} " in c for c in calls()) and any(f"--u_mss_bootcfg 00000000{saved}000000" in c for c in calls()),
      "the generated USK is the one passed to fpgenprog, in the sNVM client and in the boot configuration")

# --- the options ----------------------------------------------------------------------------------------------
def opt_for(mode, elf=ENVM, **kw):
    return options("v", mode, elf, **kw)


for description, needle, o in (
        ("a die that does not exist", "Invalid die", opt_for(1, die="MPFS999T")),
        ("a package that does not exist", "Invalid package", opt_for(1, package="XYZ")),
        ("--usk outside boot mode 2", "only valid for boot mode 2", opt_for(1, usk="1")),
        ("a USK that is not hex", "Invalid --usk", opt_for(2, LIM, usk="xyz")),
        ("a USK of the wrong length", "Invalid --usk", opt_for(2, LIM, usk="abcd")),
        ("an sNVM page out of range", "range 0-220", opt_for(2, LIM, usk="1" * 24, snvm_page=221)),
        ("--snvm_page outside boot mode 2", "only valid for boot mode 2", opt_for(1, snvm_page=1)),
        ("--encrypt outside boot mode 2", "only valid for boot mode 2", opt_for(1, encrypt=True)),
        ("keys outside boot mode 3", "Only bootmode 3", opt_for(1, private_key=PRIVATE, public_key=PUBLIC)),
        ("one key file only", "given together", opt_for(3, private_key=PRIVATE)),
        ("a key file that does not exist", "doesn't exist", opt_for(3, private_key=TMP / "none.pem", public_key=PUBLIC)),
        ("no boot program for mode 1", "needs a boot program", opt_for(1, None)),
        ("a boot program that does not exist", "does not exist", opt_for(1, TMP / "none.elf")),
        ("a FlashPro serial with a space", "not a FlashPro serial", opt_for(1, flashpro="a b"))):
    raises(bp.SetupError, needle, f"validate: {description} is refused", bp.validate, o, log)
bp.validate(opt_for(0, None), log)
check(True, "validate: boot mode 0 needs no boot program")

# --- the checks of the image --------------------------------------------------------------------------------
for description, needle, mode, elf, kw in (
        ("mode 1: linked for eNVM page 0", "must be linked for address 0x20220100", 1, PAGE0, {}),
        ("mode 3: linked for eNVM page 0", "must be linked for address 0x20220100", 3, PAGE0, {}),
        ("mode 1: boot vector outside eNVM", "boot vector for the eNVM", 1, LOW, {}),
        ("mode 1: image too big for eNVM", "Cannot place program in eNVM", 1, BIG_ENVM, {}),
        ("mode 2: boot vector outside LIM", "boot vector for boot mode 2", 2, LOW, dict(usk="1" * 24)),
        ("mode 2: length not word aligned", "32-bit word aligned", 2, ODD_LIM, dict(usk="1" * 24)),
        ("mode 2: image too big for sNVM", "Cannot place program in sNVM", 2, BIG_LIM, dict(usk="1" * 24))):
    raises(bp.BootError, needle, f"{description} is refused", bp.prepare, options("chk", mode, elf, **kw), log)

# --- fpgenprog fails ------------------------------------------------------------------------------------------
for sub, needle in (("new_project", "Failed to create fpgenprog project"), ("mss_boot_info", "Unable to select the boot mode"),
                    ("envm_client", "Unable to add eNVM client"), ("generate_bitstream", "Generation of the bitstream")):
    os.environ["FAKE_FP_FAIL"] = sub
    raises(bp.BootError, needle, f"a failing fpgenprog {sub} stops the preparation", bp.prepare, options("failing", 1, ENVM), log)
os.environ["FAKE_FP_FAIL"] = "snvm_client"
raises(bp.BootError, "Unable to add sNVM client", "a failing fpgenprog snvm_client stops the preparation", bp.prepare,
       options("failing", 2, LIM, usk="1" * 24), log)
del os.environ["FAKE_FP_FAIL"]
bad_fp = TMP / "no_fpgenprog"
raises(bp.SetupError, "is not the fpgenprog executable", "a missing fpgenprog is a set-up error", bp.prepare,
       bp.Options(workdir=TMP / "nofp", mode=bp.BootMode.IDLE, fpgenprog=bad_fp, bin_dir=BIN), log)
raises(bp.SetupError, "riscv64-elf-objcopy", "a toolchain without objcopy is a set-up error", bp.prepare,
       bp.Options(workdir=TMP / "notc", mode=bp.BootMode.IDLE, fpgenprog=FP, bin_dir=TMP), log)

# --- the output folder is made new ------------------------------------------------------------------------
stale = TMP / "bm0" / "bootmode0" / "stale.txt"
stale.write_text("old")
bp.prepare(options("bm0", 0), log)
check(not stale.exists(), "the previous content of the output folder is deleted")

# --- programming and the FlashPro -------------------------------------------------------------------------
def prepared(name="flash", **kw):
    fresh()
    return bp.prepare(options(name, 1, ENVM, **kw), log)


def actions():
    return [c.split("--action ")[1] for c in calls() if c.startswith("run_action")]


done = prepared()
seen = bp.flash(done, log)
check(actions() == ["PROGRAM"] and seen > 0, "flash: without a serial number only PROGRAM runs, and its output is seen")
check(any("FlashPro used: STANDIN1" in t for k, t in messages), "flash: the FlashPro that fpgenprog used is reported")
done = prepared(verify=True)
bp.flash(done, log)
check(actions() == ["PROGRAM", "VERIFY"], "flash: --verify verifies after programming")

os.environ["FAKE_FP_HONOUR"] = "1"
done = prepared(flashpro="SN4242")
check(bp.programmer_in_project(done.opt) == "SN4242" and "SN4242" in bp.project_file(done.opt).read_text()
      and bp.project_file(done.opt).read_text().index("<programmer") < bp.project_file(done.opt).read_text().index("<Servers>"),
      "a FlashPro serial is written into the project in front of <Servers>")
bp.flash(done, log)
check(actions() == ["VERIFY", "PROGRAM"], "flash: with a serial number a verify (which writes nothing) comes before PROGRAM")
check(bp.programmer_in_project(done.opt) == "SN4242", "flash: fpgenprog that honours the project programs through the FlashPro asked for")
del os.environ["FAKE_FP_HONOUR"]

done = prepared(flashpro="SN4242")
raises(bp.BootError, "instead of SN4242", "flash: fpgenprog that takes another FlashPro is stopped before it programs", bp.flash, done, log)
check(actions() == ["VERIFY"], "flash: ... and PROGRAM did not run")

os.environ["FAKE_FP_FAIL"] = "run_action"
done = prepared()
raises(bp.BootError, "PROGRAM action failed", "flash: a failing PROGRAM is an error", bp.flash, done, log)
del os.environ["FAKE_FP_FAIL"]
os.environ["FAKE_FP_SILENT"] = "1"
done = prepared()
check(bp.flash(done, log) == 0, "flash: a PROGRAM that prints nothing is reported as zero bytes")
del os.environ["FAKE_FP_SILENT"]

pro = bp.project_file(done.opt)
pro.write_text("<project/>")
raises(bp.BootError, "cannot be selected", "a project file of another format is an error for --flashpro", bp.select_flashpro, done.opt, log, "SN1")

print(f"summary: {fails} failure(s)")
sys.exit(1 if fails else 0)
