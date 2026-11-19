# SPDX-FileCopyrightText: 2021 Microchip FPGA Embedded Systems Solutions.
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: MIT
# Derived from SoftConsole/extras/mpfs/mpfsBootmodeProgrammer-src.zip (mpfsBootmodeProgrammer 3.7, MIT); rewritten in Python.
#
# The boot mode programmer of the PolarFire SoC: payloads, the certificate and fpgenprog, as a library.
"""Prepare and program the boot mode (0..3) of a PolarFire SoC with fpgenprog.

A Python port of Microchip's mpfsBootmodeProgrammer 3.7, the Java tool of Microchip. It does what the tool
does: it turns the boot program (an ELF) into the image of the boot mode (a binary, with a header or a
certificate in front for the modes 1 to 3), builds the fpgenprog project (boot mode, eNVM or sNVM client),
lets fpgenprog generate the differential bitstream and programs it through FlashPro.

    boot mode 0   idle boot: no boot program, a one byte eNVM client
    boot mode 1   non-secure boot from eNVM: a dummy header (256 bytes) in front of the image
    boot mode 2   user secure boot from sNVM: the image behind a header of 60 bytes (UBLI), stored in sNVM
    boot mode 3   factory secure boot from eNVM: a certificate (SBIC), signed with ECDSA P-384, in front

What differs from the Java tool: no Java; the ELF may be a file of any directory (the Java tool wants it
below its working directory); --keys never falls through into --verify (the Java tool sets --verify for
--keys by a missing break); the key pair of --keys GENERATE is reported as not saved; the public key must
belong to the private key; and a FlashPro can be chosen by its serial number (see select_flashpro: this
part is not in the Java tool, and needs a lab with more than one FlashPro to prove).

bootmode.py is the command line of this module. objcopy and readelf come from the pinned GNAT cross
toolchain (lab.toolchain_bin()), fpgenprog from Libero SoC or the Program Debug Tool.
"""
import datetime
import hashlib
import re
import secrets
import shutil
import struct
import subprocess
import time
from dataclasses import dataclass
from enum import IntEnum
from pathlib import Path
from typing import Callable

# 128 KiB of eNVM (boot modes 1 and 3)
ENVM_LOW = 0x20220000
ENVM_HIGH = 0x2023FFFF
ENVM_SIZE = ENVM_HIGH - ENVM_LOW + 1
ENVM_PAGE_SIZE = 256

# 1920 KiB of Local Integrated Memory (boot mode 2)
LIM_LOW = 0x08000000
LIM_HIGH = 0x081DFFFF

# sNVM (boot mode 2)
SNVM_PAGE_SIZE_AUTHENTICATED = 236
SNVM_PAGES = 221
SNVM_SIZE_AUTHENTICATED = SNVM_PAGES * SNVM_PAGE_SIZE_AUTHENTICATED

SBIC_SIZE = 208
UBLI_SIZE = 60
TRAMPOLINE = 0x1000006F  # jal x0, +256: the fake header of boot mode 1 jumps to the next page

DIES = ("MPFS025T", "MPFS095T", "MPFS160T", "MPFS250T", "MPFS460T",
        "MPFS025T_ES", "MPFS095T_ES", "MPFS160T_ES", "MPFS250T_ES", "MPFS460T_ES")
PACKAGES = ("FCG1152", "FCSG325", "FCSG536", "FCVG484", "FCVG784")

PROJECT_NAME = "fpgenprogProject"
LOG_NAME = "debugLog.txt"


class BootMode(IntEnum):
    IDLE = 0
    NON_SECURE_ENVM = 1
    USER_SECURE_SNVM = 2
    FACTORY_SECURE_ENVM = 3

    @property
    def description(self) -> str:
        return {0: "idle boot", 1: "non-secure boot from eNVM", 2: "user secure boot from sNVM",
                3: "factory secure boot from eNVM"}[self.value]

    def __str__(self) -> str:
        return f"{self.value} - {self.description}"


class SetupError(Exception):
    """The options or the boot program are wrong: nothing was done."""


class BootError(Exception):
    """A step failed while the image was prepared or the target programmed."""


@dataclass
class Options:
    """What the command line says. elf is None for boot mode 0; fpgenprog is the full path of the executable."""
    workdir: Path
    mode: BootMode
    fpgenprog: Path
    bin_dir: Path                      # the bin directory of the cross toolchain: riscv64-elf-objcopy, -readelf
    die: str = "MPFS250T_ES"
    package: str = "FCVG484"
    elf: Path | None = None
    usk: str | None = None             # boot mode 2: 12 bytes as 24 hex digits; None or zero: generated
    snvm_page: int = 0
    encrypt: bool = False              # boot mode 2: authenticated ciphertext instead of authenticated plaintext
    private_key: Path | None = None    # boot mode 3: both or none (none: a key pair is generated and not saved)
    public_key: Path | None = None
    verify: bool = False
    prepare_only: bool = False         # everything except programming (the Java tool's --dryrun)
    flashpro: str | None = None        # serial number of the FlashPro to use; None: what fpgenprog picks
    programmer_element: str | None = None  # the <programmer> element FlashPro Express wrote for it (type, connection); None: a minimal one
    program_command: Callable[[str], list[str]] | None = None
    # the command for an action (PROGRAM, VERIFY) in place of fpgenprog run_action: fpgenprog has no way to pick one FlashPro
    # (its script runs the action on every connected programmer), so a lab with several programs through FlashPro Express

    @property
    def out_dir(self) -> Path:
        return self.workdir / f"bootmode{int(self.mode)}"

    @property
    def project_dir(self) -> Path:
        return self.out_dir / PROJECT_NAME


class Log:
    """What goes to the console (info, warn, error: through <emit>) and, with the debug lines, to debugLog.txt
    of the output directory once there is one."""

    def __init__(self, emit: Callable[[str, str], None]):
        self.emit = emit
        self.path: Path | None = None

    def _file(self, level: str, message: str) -> None:
        if self.path is not None:
            stamp = datetime.datetime.now().strftime("%H:%M:%S")
            with open(self.path, "a", encoding="utf-8") as f:
                f.write(f"{stamp} {level:<5} - {message}\n")

    def info(self, message: str) -> None:
        self.emit("info", message)
        self._file("INFO", message)

    def warn(self, message: str) -> None:
        self.emit("warn", message)
        self._file("WARN", message)

    def error(self, message: str) -> None:
        self.emit("error", message)
        self._file("ERROR", message)

    def debug(self, message: str) -> None:
        self._file("DEBUG", message)


# ----------------------------------------------------------------------------------------------------------
# Validation
# ----------------------------------------------------------------------------------------------------------

def normalize_usk(text: str | None) -> str | None:
    """The USK as the Java tool takes it: a leading 0x is dropped."""
    if text is None:
        return None
    return text[2:] if text.startswith("0x") else text


def validate(opt: Options, log: Log, check_elf: bool = True) -> None:
    """The checks of the Java tool that need no tool: raises SetupError. A zero or missing USK of boot mode 2
    is replaced by a generated one (and warned about), so opt.usk is set afterwards."""
    mode = opt.mode
    if opt.die not in DIES:
        raise SetupError(f'Invalid die "{opt.die}" specified.')
    if opt.package not in PACKAGES:
        raise SetupError(f'Invalid package "{opt.package}" specified.')
    if opt.usk is not None and mode != BootMode.USER_SECURE_SNVM:
        raise SetupError("The --usk option is only valid for boot mode 2.")
    if mode == BootMode.USER_SECURE_SNVM:
        usk = opt.usk if opt.usk is not None else "0"
        if not re.fullmatch(r"[0-9a-fA-F]+", usk):
            raise SetupError(f'Invalid --usk key value specified "{usk}".')
        if int(usk, 16) == 0:
            usk = secrets.token_hex(12)
            log.warn(f'--usk key is not specified or specifies zero so the script will use a randomly generated USK '
                     f'"{usk}" instead.')
        if len(usk) != 24:
            raise SetupError(f'Invalid --usk key value specified "{usk}".')
        opt.usk = usk
        if not 0 <= opt.snvm_page < SNVM_PAGES:
            raise SetupError(f'Invalid sNVM page "{opt.snvm_page}". --snvm_page must specify a page in the range '
                             f'0-{SNVM_PAGES - 1}.')
    elif opt.snvm_page != 0:
        raise SetupError("The --snvm_page option is only valid for boot mode 2.")
    if opt.encrypt and mode != BootMode.USER_SECURE_SNVM:
        raise SetupError("The --encrypt option is only valid for boot mode 2.")
    keys = (opt.private_key is not None, opt.public_key is not None)
    if any(keys) and mode != BootMode.FACTORY_SECURE_ENVM:
        raise SetupError("Only bootmode 3 is allowed to specify the public/private keys.")
    if keys[0] != keys[1]:
        raise SetupError("The private and the public key file must be given together.")
    for key in (opt.private_key, opt.public_key):
        if key is not None and not key.is_file():
            raise SetupError(f'Key file "{key}" doesn\'t exist, make sure your arguments point to existing files.')
    if mode != BootMode.IDLE and check_elf:
        if opt.elf is None:
            raise SetupError(f"Boot mode {int(mode)} needs a boot program (an ELF file).")
        if not opt.elf.is_file():
            raise SetupError(f'File "{opt.elf}" does not exist.')
    if opt.flashpro is not None and not re.fullmatch(r"[0-9A-Za-z]+", opt.flashpro):
        raise SetupError(f'"{opt.flashpro}" is not a FlashPro serial number (letters and digits).')


# ----------------------------------------------------------------------------------------------------------
# The payload: pure functions on bytes
# ----------------------------------------------------------------------------------------------------------

def put_u32(buf: bytearray, offset: int, value: int) -> None:
    """A 32-bit word, little endian, as the target reads it."""
    struct.pack_into("<I", buf, offset, value & 0xFFFFFFFF)


def bootcfg_bm1(boot_vector: int) -> str:
    """The reset vector of each of the five harts, 20 bytes as 40 hex digits."""
    return f"{boot_vector:08X}" * 5


def bootcfg_bm2(start_page: int, usk: str) -> str:
    """U_MSS_BOOT_SNVM_PAGE (1 byte), 3 reserved bytes, the USK (12 bytes), 4 bytes of padding."""
    return f"{0:08X}{usk}{0:06X}{start_page:02X}"


def bootcfg_bm3(sbic_address: int, revocation: int = 0) -> str:
    """U_MSS_SBIC_ADDR (4 bytes), U_MSS_REVOCATION_ENABLE (4 bytes), 12 bytes of padding."""
    return f"{0:024X}{revocation & 0xFFFFFFFF:08X}{sbic_address & 0xFFFFFFFF:08X}"


def xy_hex(number: int) -> str:
    """A coordinate of the public key as the 96 hex digits (48 bytes) fpgenprog wants."""
    return f"{number:096x}"


def envm_page(address: int) -> int:
    """The start page of an address in eNVM (not rounded up: this is an index, not a size)."""
    return (address - ENVM_LOW) // ENVM_PAGE_SIZE


def sbic_address_before_image(boot_vector: int) -> int:
    """The SBIC goes into the page in front of the image."""
    return (envm_page(boot_vector) - 1) * ENVM_PAGE_SIZE + ENVM_LOW


def make_ubli(image: bytes, boot_vector: int) -> bytes:
    """User Boot Loader Image of boot mode 2: IMAGEADDR, IMAGELEN (32-bit words), the five boot vectors, the
    SHA-256 of the image (60 bytes), then the image."""
    header = bytearray(28)
    put_u32(header, 0, boot_vector)
    put_u32(header, 4, (len(image) + 3) // 4)
    for hart in range(5):
        put_u32(header, 8 + 4 * hart, boot_vector)
    return bytes(header) + hashlib.sha256(image).digest() + image


def make_fake_sbic(boot_vector: int, size: int) -> bytes:
    """The header of boot mode 1, one eNVM page: a jump to the next page, the length, the boot vectors, an
    illegal instruction, "BOOT MODE 1 DUMMY SBIC" and another illegal instruction."""
    header = bytearray(ENVM_PAGE_SIZE)
    put_u32(header, 0, TRAMPOLINE)
    put_u32(header, 4, size)
    for hart in range(5):
        put_u32(header, 8 + 4 * hart, boot_vector)
    put_u32(header, 208, 0xFFFFFFFF)
    header[212:236] = b"BOOT MODE 1 DUMMY SBIC\0\0"
    put_u32(header, 236, 0xFFFFFFFF)
    return bytes(header)


def make_sbic_header(image: bytes, boot_vector: int) -> bytes:
    """The 104 bytes of the certificate that are signed: IMAGEADDR, IMAGELEN, the boot vectors, options,
    version and DSN zero, and the SHA-384 of the image at offset 56."""
    header = bytearray(104)
    put_u32(header, 0, boot_vector)
    put_u32(header, 4, len(image))
    for hart in range(5):
        put_u32(header, 8 + 4 * hart, boot_vector)
    header[56:104] = hashlib.sha384(image).digest()
    return bytes(header)


def make_sbic(image: bytes, boot_vector: int, sign: Callable[[bytes], bytes]) -> bytes:
    """The certificate of boot mode 3: the header, then its DER ECDSA signature padded with zeros to 104 bytes."""
    header = make_sbic_header(image, boot_vector)
    signature = sign(header)
    if len(signature) > 104:
        raise BootError(f"The signature is {len(signature)} bytes long, more than the 104 bytes of CODESIG.")
    return header + signature.ljust(104, b"\0")


def combine_sbic_with_image(image: bytes, sbic: bytes, sbic_size: int | None = None) -> bytes:
    """The certificate, zeros up to the next eNVM page, then the image."""
    size = len(sbic) if sbic_size is None else sbic_size
    return sbic + bytes(max(0, ENVM_PAGE_SIZE - size)) + image


def envm_sanity_check(boot_vector: int, size: int, elf: Path) -> None:
    """The boot vector must be in eNVM, on a page boundary, and the image must fit."""
    if not ENVM_LOW <= boot_vector <= ENVM_HIGH:
        raise BootError(f'ELF file linked incorrectly. The boot vector for the eNVM must be between "0x{ENVM_LOW:08X}" '
                        f'and "0x{ENVM_HIGH:08X}" but the selected ELF file "{elf}" has boot vector '
                        f'"0x{boot_vector:08X}". Check the linker script used to link the program.')
    if boot_vector % ENVM_PAGE_SIZE:
        raise BootError(f'ELF file linked incorrectly. The IMAGEADDR (inferred from bootvector 0x{boot_vector:08X}) '
                        'must be aligned to a 256 byte eNVM page. Check the linker script used to link the program.')
    if boot_vector + size > ENVM_HIGH:
        raise BootError(f'Cannot place program in eNVM. eNVM is "0x{ENVM_SIZE:08X}" bytes, while the selected ELF file '
                        f'"{elf}" is "0x{size:08X}" bytes long and placed at eNVM page "{envm_page(boot_vector)}" '
                        f'("0x{boot_vector - ENVM_LOW:08X}" bytes off from the start of eNVM region) causing it to exceed '
                        'the available eNVM space. Shrink your application if you can and/or change your linker script '
                        'to use lower offset.')


def snvm_and_lim_sanity_check(boot_vector: int, size: int, snvm_page: int, elf: Path) -> None:
    """For boot mode 2: the boot vector must be in LIM, word aligned, the length a multiple of 4, and the image
    with its 60 byte header must fit into the sNVM from the start page on."""
    if not LIM_LOW <= boot_vector <= LIM_HIGH:
        raise BootError(f'ELF file linked incorrectly. The boot vector for boot mode 2 must be between "0x{LIM_LOW:08X}" '
                        f'and "0x{LIM_HIGH:08X}" but the selected ELF file "{elf}" has boot vector '
                        f'"0x{boot_vector:08X}". Check the linker script used to link the program.')
    if boot_vector % 4:
        raise BootError(f'ELF file linked incorrectly. The IMAGEADDR (inferred from bootvector "0x{boot_vector:08X}") '
                        'must be 32-bit word aligned. Check the linker script used to link the program.')
    if size % 4:
        raise BootError(f'ELF file linked incorrectly. The image length "0x{size:08X}" must be 32-bit word aligned. '
                        'Check the linker script used to link the program.')
    if boot_vector + size > LIM_HIGH:
        raise BootError(f'The application\'s offset "0x{boot_vector:08X}" and size "0x{size:08X}" combined make it too big '
                        f'to fit into the LIM (LIM ends at "0x{LIM_HIGH:08X}"). Linking at a lower LIM address, or making '
                        'the application smaller could resolve this issue.')
    if snvm_page * SNVM_PAGE_SIZE_AUTHENTICATED + size + UBLI_SIZE > SNVM_SIZE_AUTHENTICATED:
        raise BootError(f'Cannot place program in sNVM. The boot mode 2 sNVM size is maximum "0x{SNVM_SIZE_AUTHENTICATED:08X}" '
                        f'bytes, however application will not fit into the sNVM with the size of the selected ELF file '
                        f'"{elf}" which is "0x{size:08X}" bytes, together with the sNVM_page "{snvm_page}" which is at '
                        f'"0x{snvm_page * SNVM_PAGE_SIZE_AUTHENTICATED:08X}" bytes offset within the sNVM. Consider '
                        'lowering the snvm_page offset and/or shrinking the application.')


# ----------------------------------------------------------------------------------------------------------
# ECDSA P-384 (boot mode 3)
# ----------------------------------------------------------------------------------------------------------

class Signer:
    """The key pair of boot mode 3: the private key signs the header, the coordinates of the public key go into
    the fpgenprog project (--ucskx, --ucsky)."""

    def __init__(self, private_key, x: int, y: int):
        self.private_key = private_key
        self.x = x
        self.y = y

    @classmethod
    def generate(cls) -> "Signer":
        ec = _ec()
        key = ec.generate_private_key(ec.SECP384R1())
        numbers = key.public_key().public_numbers()
        return cls(key, numbers.x, numbers.y)

    @classmethod
    def from_files(cls, private_pem: Path, public_pem: Path) -> "Signer":
        """Keys of NIST P-384 (secp384r1): the private key PKCS#8 ('BEGIN PRIVATE KEY'), the public key X.509
        ('BEGIN PUBLIC KEY'), without a password. They must belong together."""
        ec = _ec()
        from cryptography.hazmat.primitives import serialization
        try:
            private = serialization.load_pem_private_key(private_pem.read_bytes(), password=None)
            public = serialization.load_pem_public_key(public_pem.read_bytes())
        except (OSError, ValueError, TypeError) as e:
            raise BootError(f"Failed to read the ECC (Elliptic Curve Cryptography) keys from the files: {e}. "
                            f"{KEY_EXPLANATION}") from e
        for name, key in (("private", private), ("public", public)):
            if not isinstance(key, (ec.EllipticCurvePrivateKey, ec.EllipticCurvePublicKey)) or key.curve.name != "secp384r1":
                raise BootError(f"The {name} key is not an elliptic curve key of NIST P-384 (secp384r1). {KEY_EXPLANATION}")
        mine = private.public_key().public_numbers()
        theirs = public.public_numbers()
        if (mine.x, mine.y) != (theirs.x, theirs.y):
            raise BootError("The public key does not belong to the private key: the certificate would not verify.")
        return cls(private, theirs.x, theirs.y)

    def sign(self, content: bytes) -> bytes:
        """SHA384withECDSA, DER encoded."""
        ec = _ec()
        from cryptography.hazmat.primitives import hashes
        return self.private_key.sign(content, ec.ECDSA(hashes.SHA384()))


KEY_EXPLANATION = (
    "Keys have to use elliptical curve NIST P-384 (secp384r1). The private key needs to be in PKCS#8 format with "
    "'-----BEGIN PRIVATE KEY-----', without a password; the public key in X.509 format with "
    "'-----BEGIN PUBLIC KEY-----'. With OpenSSL: openssl ecparam -name secp384r1 -genkey -noout -out combined.ec.key; "
    "openssl pkcs8 -topk8 -nocrypt -in combined.ec.key -out private.pem; "
    "openssl ec -in private.pem -pubout -out public.pem")


def _ec():
    try:
        from cryptography.hazmat.primitives.asymmetric import ec
    except ImportError as e:
        raise BootError("boot mode 3 needs the Python package cryptography: ./x toolchain install installs it "
                        "into the virtual environment of the host tools") from e
    return ec


# ----------------------------------------------------------------------------------------------------------
# External tools
# ----------------------------------------------------------------------------------------------------------

def run_tool(command: list[str], log: Log, show: bool = True, stream: bool = False) -> tuple[int, str]:
    """Run a tool, return (exit status, its output). stdout and stderr are shown line by line when <show> (info
    lines), or kept for the caller; <stream> shows them as they come instead of at the end."""
    log.debug(f'Invoking command: "{" ".join(command)}".')
    try:
        proc = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, errors="replace", bufsize=1)
    except OSError as e:
        raise BootError(f'Exception occurred when invoking "{command[0]}" command: {e}') from e
    lines = []
    assert proc.stdout is not None
    try:
        for line in proc.stdout:
            lines.append(line)
            if show and stream:
                log.info(line.rstrip("\n"))
        status = proc.wait()
    except BaseException:
        proc.kill()
        proc.wait()
        raise
    output = "".join(lines)
    if show and not stream:
        for line in lines:
            log.info(line.rstrip("\n"))
    log.debug(f'Finished with exit code: "{status}".')
    return status, output


def objcopy(opt: Options, log: Log, args: list[str], what: str) -> None:
    command = [str(opt.bin_dir / "riscv64-elf-objcopy"), *args]
    status, output = run_tool(command, log, show=False)
    if status != 0:
        raise BootError(f"Failed to run OBJCOPY to {what}: {' '.join(command)}\n{output.strip()}")


def elf_to_bin(opt: Options, log: Log, elf: Path, out: Path) -> None:
    objcopy(opt, log, ["-O", "binary", str(elf), str(out)], f'convert ELF file "{elf}" to a BIN file "{out}"')


def bin_to_hex(opt: Options, log: Log, source: Path, out: Path, offset: int = 0) -> None:
    """A binary as Intel hex; with an offset the data lies at that address (a load address added to 0)."""
    args = ["-I", "binary", "-O", "ihex"]
    if offset:
        args += ["--change-section-lma", f"*+0x{offset:08X}"]
    objcopy(opt, log, [*args, str(source), str(out)], f'convert BIN file "{source}" to a HEX file "{out}"')


def read_boot_vector(opt: Options, log: Log, elf: Path) -> int:
    """The entry point of the ELF, from `readelf --program-headers`."""
    command = [str(opt.bin_dir / "riscv64-elf-readelf"), "--program-headers", str(elf)]
    status, output = run_tool(command, log, show=False)
    if status != 0:
        raise BootError(f'Failed to run READELF "{command[0]}" to get the entry point from the ELF file "{elf}".')
    for line in output.splitlines():
        if line.strip().startswith("Entry point"):
            try:
                vector = int(line.strip()[len("Entry point"):].strip(), 16)
            except ValueError as e:
                raise BootError(f'Failed to find the entry point from the output READELF "{command[0]}". '
                                f'The output was: "{output}".') from e
            log.debug(f'The detected entry address is "{vector:x}".')
            return vector
    raise BootError(f'Failed to find the entry point from the output READELF "{command[0]}". The output was: "{output}".')


# ----------------------------------------------------------------------------------------------------------
# fpgenprog
# ----------------------------------------------------------------------------------------------------------

def fp_new_project(opt: Options) -> list[str]:
    return [str(opt.fpgenprog), "new_project", "--location", str(opt.project_dir),
            "--target_die", opt.die, "--target_package", opt.package]


def fp_select_bootmode(opt: Options, bootcfg: str | None = None, x: int | None = None, y: int | None = None) -> list[str]:
    command = [str(opt.fpgenprog), "mss_boot_info", "--location", str(opt.project_dir),
               "--u_mss_bootmode", str(int(opt.mode))]
    if bootcfg is not None:
        command += ["--u_mss_bootcfg", bootcfg]
    if x is not None and y is not None:
        command += ["--ucskx", xy_hex(x), "--ucsky", xy_hex(y), "--reset_sbic_version"]
    return command


def fp_envm_client(opt: Options, hex_file: Path, start_page: int, size: int, address: int | None = None) -> list[str]:
    command = [str(opt.fpgenprog), "envm_client", "--location", str(opt.project_dir),
               "--number_of_bytes", str(size), "--content_file_format", "intel-hex",
               "--content_file", str(hex_file), "--start_page", str(start_page),
               "--client_name", f"bootmode{int(opt.mode)}_{start_page}"]
    if address is not None:
        # no 0x in front: fpgenprog rejects '0x20220000' as "not valid hex string"
        command += ["--mem_file_base_address", f"{address:08X}"]
    return command


def fp_snvm_client(opt: Options, hex_file: Path, size: int, address: int) -> list[str]:
    command = [str(opt.fpgenprog), "snvm_client", "--location", str(opt.project_dir),
               "--number_of_bytes", str(size), "--content_file_format", "intel-hex",
               "--content_file", str(hex_file), "--start_page", str(opt.snvm_page),
               "--client_name", f"bootmode{int(opt.mode)}", "--usk_key", str(opt.usk),
               "--encrypted_authenticated" if opt.encrypt else "--authenticated",
               "--mem_file_base_address", f"{address:08X}",
               "--fabric_access_read", "0", "--fabric_access_write", "0", "--mss_access_read", "1", "--mss_access_write", "0"]
    return command


def fp_generate_bitstream(opt: Options) -> list[str]:
    return [str(opt.fpgenprog), "generate_bitstream", "--location", str(opt.project_dir)]


def action_command(opt: Options, action: str) -> list[str]:
    """The command that does <action> on the project: program_command if there is one, else fpgenprog run_action."""
    return opt.program_command(action) if opt.program_command is not None else fp_run_action(opt, action)


def fp_run_action(opt: Options, action: str) -> list[str]:
    return [str(opt.fpgenprog), "run_action", "--location", str(opt.project_dir), "--action", action]


def fp_step(opt: Options, log: Log, command: list[str], failed: str, show: bool = False) -> None:
    """One fpgenprog step. Its output is shown if <show>; when it fails its output is shown in any case."""
    status, output = run_tool(command, log, show=show)
    if status != 0:
        if not show:
            for line in output.splitlines():
                log.info(line)
        raise BootError(failed)


# --- the FlashPro of the project ----------------------------------------------------------------------------

def project_file(opt: Options) -> Path:
    return opt.project_dir / "proj_fp" / "proj_fp.pro"


PROGRAMMER_RE = re.compile(r"<programmer\b.*?</programmer>", re.S)
PROGRAMMER_GAP_RE = re.compile(r"[ \t]*<programmer\b.*?</programmer>[ \t]*\n?", re.S)
USED_RE = re.compile(r"programmer '([^']+)' : device '[^']*' : Executing action", re.I)
SERVERS_RE = re.compile(r"^([ \t]*)<Servers>", re.M)   # the programmer element stands in front of it
PROGRAMMER_ID_RE = re.compile(r"<id>\s*(\S+)\s*</id>")


def select_flashpro(opt: Options, log: Log, serial: str) -> None:
    """Write the FlashPro with <serial> into the project, where fpgenprog takes the programmer from.

    A new project (fpgenprog new_project) has an empty <Servers> element and no programmer; after a run with a
    board, fpgenprog has put <programmer status="enable" ...><name>SN</name><id>SN</id></programmer> in front of
    <Servers> (what the Java tool leaves to fpgenprog: it picks the programmer it finds). This puts that element
    in before the run, with the serial number as name and id, or replaces the one that is there. THAT FPGENPROG
    TAKES THE PROGRAMMER FROM IT IS NOT PROVEN: it needs a lab with more than one FlashPro. check_flashpro reads
    back which programmer fpgenprog used, and flash() does not program unless that is the one asked for."""
    pro = project_file(opt)
    try:
        text = pro.read_text(encoding="utf-8")
    except OSError as e:
        raise BootError(f"Cannot read the project file {pro} to select the FlashPro: {e}") from e
    element = opt.programmer_element or f'<programmer status="enable"><name>{serial}</name><id>{serial}</id></programmer>'
    stripped = PROGRAMMER_GAP_RE.sub("", text)   # the elements that are there (and the lines they leave empty) go
    new, count = SERVERS_RE.subn(lambda m: f"{m.group(1)}{element}\n{m.group(0)}", stripped, count=1)
    if not count:
        raise BootError(f"The project file {pro} has no <Servers> element: "
                        "fpgenprog changed its format; the FlashPro cannot be selected")
    pro.write_text(new, encoding="utf-8")
    log.debug(f"FlashPro {serial} written into {pro}.")


def programmer_in_project(opt: Options) -> str | None:
    """The serial number (id) of the programmer that the project names, or None."""
    try:
        text = project_file(opt).read_text(encoding="utf-8")
    except OSError:
        return None
    block = PROGRAMMER_RE.search(text)
    found = PROGRAMMER_ID_RE.search(block.group(0)) if block else None
    return found.group(1) if found else None


def programmers_used(output: str) -> list[str]:
    """The programmers that fpgenprog ran the action on, in the order its output names them (once each): FlashPro Express
    prints "programmer 'NAME' : device 'target' : Executing action VERIFY" for each. With two FlashPros connected a
    project that names one programmer still had both do the action (they program in parallel)."""
    seen: list[str] = []
    for name in USED_RE.findall(output):
        if name not in seen:
            seen.append(name)
    return seen


def check_flashpro(opt: Options, log: Log, serial: str, output: str) -> None:
    """Raises BootError unless the action that printed <output> ran on FlashPro <serial> and on no other programmer.
    The project file says nothing about that: it is what select_flashpro wrote, fpgenprog does not change it."""
    used = programmers_used(output)
    if used != [serial]:
        what = ("on " + ", ".join(used)) if used else "on none that its output names (it may have stopped early; see the log)"
        raise BootError(f"fpgenprog ran the action {what} instead of only on {serial}: nothing was programmed. Naming "
                        f"{serial} in the project does not make this fpgenprog use that FlashPro alone, or {serial} is "
                        "not connected. Disconnect the other FlashPro and run it again.")
    log.info(f"FlashPro {serial} is the only programmer fpgenprog ran the action on.")


# ----------------------------------------------------------------------------------------------------------
# The steps
# ----------------------------------------------------------------------------------------------------------

@dataclass
class Prepared:
    """What prepare() leaves for flash(): the project is ready and the bitstream generated."""
    opt: Options
    boot_vector: int | None = None
    size: int | None = None
    usk_file: Path | None = None
    public_key_file: Path | None = None
    private_key_saved: bool = True


def prepare_output(opt: Options, log: Log) -> None:
    """A fresh <workdir>/bootmode<N>/ (the previous content is deleted) with the log file in it."""
    log.info(f'"{opt.out_dir}" is the output folder and the previous contents of this folder will be deleted.')
    try:
        if opt.out_dir.exists():
            shutil.rmtree(opt.out_dir)
        opt.out_dir.mkdir(parents=True)
    except OSError as e:
        raise BootError(f'Cannot create directory "{opt.out_dir}". Make sure that it is not in use by another '
                        f'application and that you have access rights: {e}') from e
    log.path = opt.out_dir / LOG_NAME
    log.path.write_text("\n", encoding="utf-8")


def prepare(opt: Options, log: Log) -> Prepared:
    """Everything up to the bitstream: the image, the project with its boot mode and clients, the bitstream.
    Nothing here touches the FlashPro or the board. Raises SetupError for wrong options, BootError otherwise."""
    validate(opt, log)
    if not opt.fpgenprog.is_file():
        raise SetupError(f'FPGENPROG "{opt.fpgenprog}" is not the fpgenprog executable.')
    for tool in ("riscv64-elf-objcopy", "riscv64-elf-readelf"):
        if not (opt.bin_dir / tool).is_file():
            raise SetupError(f"{opt.bin_dir / tool} not found: ./x toolchain install")
    opt.workdir.mkdir(parents=True, exist_ok=True)
    prepare_output(opt, log)
    log.info(f'Selected boot mode "{opt.mode}" and working in directory "{opt.workdir}".')
    log.debug(f"Workdir={opt.workdir} die={opt.die} diePackage={opt.package} bm={opt.mode} verify={opt.verify} elf={opt.elf}")

    # the project
    shutil.rmtree(opt.project_dir, ignore_errors=True)
    fp_step(opt, log, fp_new_project(opt), f'Failed to create fpgenprog project at location "{opt.project_dir}".')

    done = Prepared(opt)
    if opt.mode == BootMode.IDLE:
        prepare_bm0(opt, log)
    else:
        assert opt.elf is not None
        base = opt.elf.stem
        log.info("Generating BIN file...")
        image_bin = opt.out_dir / f"{base}.bin"
        elf_to_bin(opt, log, opt.elf, image_bin)
        size = image_bin.stat().st_size
        log.debug(f'Size of the BIN file is "{size} (decimal)" or "0x{size:08X} (hex)".')
        boot_vector = read_boot_vector(opt, log, opt.elf)
        done.boot_vector, done.size = boot_vector, size
        tag = f"-bm{int(opt.mode)}"
        if opt.mode == BootMode.NON_SECURE_ENVM:
            prepare_bm1(opt, log, base, tag, image_bin.read_bytes(), boot_vector, size)
        elif opt.mode == BootMode.USER_SECURE_SNVM:
            done.usk_file = prepare_bm2(opt, log, base, tag, image_bin.read_bytes(), boot_vector, size)
        else:
            done.public_key_file, done.private_key_saved = prepare_bm3(opt, log, base, tag, image_bin.read_bytes(),
                                                                       boot_vector, size)
    log.info("Generating bitstream...")
    fp_step(opt, log, fp_generate_bitstream(opt),
            f'Generation of the bitstream file in the project folder "{opt.project_dir}" failed.')
    if opt.flashpro:
        select_flashpro(opt, log, opt.flashpro)
    return done


def prepare_bm0(opt: Options, log: Log) -> None:
    """Idle boot: one dummy byte as the eNVM client, so that the project has a client."""
    log.info("Preparing for bitstream generation...")
    dummy = opt.out_dir / "bootmode0.hex"
    dummy.write_text(":0100000000FF", encoding="utf-8")
    fp_step(opt, log, fp_select_bootmode(opt),
            f'Unable to select the boot mode "{opt.mode}" for the project folder "{opt.project_dir}".', show=True)
    fp_step(opt, log, fp_envm_client(opt, dummy, 0, 1), "Unable to add eNVM client.", show=True)


def prepare_bm1(opt: Options, log: Log, base: str, tag: str, image: bytes, boot_vector: int, size: int) -> None:
    """Non-secure eNVM boot: a dummy header page in front of the image, both programmed into eNVM."""
    envm_sanity_check(boot_vector, size, opt.elf)
    if envm_page(boot_vector) <= 0:
        raise BootError(CANNOT_FIT_SBIC)
    page = envm_page(boot_vector) - 1
    sbic_address = ENVM_LOW + page * ENVM_PAGE_SIZE
    combined_name = f"{base}{tag}-p{page}"
    log.info("Generating header...")
    sbic = make_fake_sbic(boot_vector, size)
    (opt.out_dir / f"{base}{tag}-dummySbic.bin").write_bytes(sbic)
    combined = combine_sbic_with_image(image, sbic, ENVM_PAGE_SIZE)
    (opt.out_dir / f"{combined_name}.bin").write_bytes(combined)
    log.info("Generating HEX file...")
    hex_file = opt.out_dir / f"{combined_name}.hex"
    bin_to_hex(opt, log, opt.out_dir / f"{combined_name}.bin", hex_file, sbic_address)
    log.info("Preparing for bitstream generation...")
    fp_step(opt, log, fp_select_bootmode(opt, bootcfg_bm1(boot_vector)),
            f'Unable to select the boot mode "{opt.mode}" for the project folder "{opt.project_dir}".', show=True)
    fp_step(opt, log, fp_envm_client(opt, hex_file, page, size + ENVM_PAGE_SIZE, sbic_address),
            "Unable to add eNVM client.", show=True)


def prepare_bm2(opt: Options, log: Log, base: str, tag: str, image: bytes, boot_vector: int, size: int) -> Path:
    """User secure boot from sNVM: the image behind a 60 byte header goes into sNVM, the USK and the start page
    into the boot configuration. Returns the file with the USK (it is saved: without it the image cannot be read)."""
    usk_file = opt.out_dir / f"{base}{tag}-usk.txt"
    usk_file.write_text(str(opt.usk), encoding="utf-8")
    log.warn("Ensure that --snvm_page, --usk and boot mode 2 program image size align correctly with the sNVM usage "
             "in the target design's Libero project.")
    snvm_and_lim_sanity_check(boot_vector, size, opt.snvm_page, opt.elf)
    name = f"{base}{tag}-p{opt.snvm_page}{'-ac' if opt.encrypt else '-ap'}"
    ubli = make_ubli(image, boot_vector)
    (opt.out_dir / f"{name}.bin").write_bytes(ubli)
    log.info("Generating HEX file...")
    hex_file = opt.out_dir / f"{name}.hex"
    bin_to_hex(opt, log, opt.out_dir / f"{name}.bin", hex_file)
    log.info("Preparing for bitstream generation...")
    fp_step(opt, log, fp_select_bootmode(opt, bootcfg_bm2(opt.snvm_page, str(opt.usk))),
            f'Unable to select the boot mode "{opt.mode}" for the project folder "{opt.project_dir}".', show=True)
    # the size grows by the header only after it was written, so the header holds the size of the image
    status, output = run_tool(fp_snvm_client(opt, hex_file, size + UBLI_SIZE, boot_vector), log, show=False)
    if status != 0:
        for line in output.splitlines():
            log.info(line)
        raise BootError("Unable to add sNVM client.")
    return usk_file


def prepare_bm3(opt: Options, log: Log, base: str, tag: str, image: bytes, boot_vector: int,
                size: int) -> tuple[Path, bool]:
    """Factory secure boot from eNVM: an SBIC signed with ECDSA P-384 in front of the image, the public key in
    the boot mode. Returns the file with the public key and whether the private key exists in a file."""
    envm_sanity_check(boot_vector, size, opt.elf)
    if envm_page(boot_vector) <= 0:
        raise BootError(CANNOT_FIT_SBIC)
    page = envm_page(boot_vector) - 1
    sbic_address = ENVM_LOW + page * ENVM_PAGE_SIZE
    combined_name = f"{base}{tag}-p{page}"
    log.info("Generating SBIC (Secure Boot Image Certificate)...")
    if opt.private_key is None:
        log.info("Generating ECDSA NIST P-384 keys...")
        signer = Signer.generate()
        log.warn("The generated private key is not saved: the board accepts only images signed with it, and this run "
                 "is the only one that can sign. Give --keys files to keep a key.")
        saved = False
    else:
        log.info("Reading ECDSA NIST P-384 keys from files...")
        assert opt.public_key is not None
        signer = Signer.from_files(opt.private_key, opt.public_key)
        saved = True
    xy_file = opt.out_dir / f"{base}{tag}-public-key-xy.txt"
    xy_file.write_text(f"ucskx={xy_hex(signer.x)}\nucsky={xy_hex(signer.y)}\n", encoding="utf-8")
    log.debug(f"Public key X(hex)=0x{xy_hex(signer.x)}")
    log.debug(f"Public key Y(hex)=0x{xy_hex(signer.y)}")
    sbic = make_sbic(image, boot_vector, signer.sign)
    (opt.out_dir / f"{base}{tag}-sbic.bin").write_bytes(sbic)
    combined = combine_sbic_with_image(image, sbic)
    (opt.out_dir / f"{combined_name}.bin").write_bytes(combined)
    log.info("Generating HEX file...")
    hex_file = opt.out_dir / f"{combined_name}.hex"
    bin_to_hex(opt, log, opt.out_dir / f"{combined_name}.bin", hex_file, sbic_address)
    log.info("Preparing for bitstream generation...")
    fp_step(opt, log, fp_select_bootmode(opt, bootcfg_bm3(sbic_address), signer.x, signer.y),
            f'Unable to select the boot mode "{opt.mode}" for the project folder "{opt.project_dir}".', show=True)
    fp_step(opt, log, fp_envm_client(opt, hex_file, page, ENVM_PAGE_SIZE + size, sbic_address),
            "Unable to add eNVM client.", show=True)
    return xy_file, saved


CANNOT_FIT_SBIC = ("ELF file linked for address 0x20220000/eNVM page 0. Boot mode 1 and 3 programs must be linked for "
                   "address 0x20220100/eNVM page 1 or higher to allow space for the SBIC/header to be stored before "
                   "the program image.")


def flash(done: Prepared, log: Log) -> int:
    """Program the target (and verify it if asked) with the project that prepare() made. Returns the number of
    bytes fpgenprog printed while it programmed: no output at all means something is wrong with the tool, not
    a success. Writes to the FPGA configuration: bootmode.py asks first."""
    opt = done.opt
    if opt.program_command is not None:
        log.info(f"Programming through FlashPro Express, on FlashPro {opt.flashpro} only.")
    elif opt.flashpro:
        # A VERIFY changes nothing on the board: it shows which programmer fpgenprog takes, before anything is written.
        log.info(f"Checking that fpgenprog uses FlashPro {opt.flashpro} (a verify, which writes nothing)...")
        status, output = run_tool(fp_run_action(opt, "VERIFY"), log, show=False)
        log.debug(f"The check ended with status {status}.")
        check_flashpro(opt, log, opt.flashpro, output)
        select_flashpro(opt, log, opt.flashpro)
    log.info("Programming the target...")
    start = time.monotonic()
    status, output = run_tool(action_command(opt, "PROGRAM"), log, show=True, stream=True)
    log.debug(f"PROGRAM took {time.monotonic() - start:.1f} s")
    if status != 0:
        raise BootError(f'Running the fpgenprog PROGRAM action failed (status {status}).')
    seen = len(output.strip())
    used = programmers_used(output)
    if used:
        log.info(f"FlashPro used: {', '.join(used)}")
    if opt.flashpro and used != [opt.flashpro]:
        log.warn(f"fpgenprog ran PROGRAM on {', '.join(used) or '(none that its output names)'}, not only on {opt.flashpro}.")
    if opt.verify:
        log.info("Verifying the target...")
        status, _ = run_tool(action_command(opt, "VERIFY"), log, show=True, stream=True)
        if status != 0:
            raise BootError("Verification of bitstream on the target failed.")
    return seen
