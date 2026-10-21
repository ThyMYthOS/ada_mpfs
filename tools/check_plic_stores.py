#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Fail if code stores 64 bits through an address of the PLIC window.

The PLIC of PolarFire SoC (and QEMU's model of it) accepts 32-bit accesses
only. The compiler turns an assignment of an aggregate to an array of registers
(`Enables := (others => 0)`) into 64-bit stores, which is the defect no. 3 of
the master plan (the upstream s-bbripl.adb did it). This check disassembles
objects, libraries (.a) or images with the pinned RISC-V objdump and looks for
a 64-bit store (`sd`, `fsd`, `sc.d`, `amo*.d`, the compressed forms) whose base
register holds an address of the window 0x0C00_0000 .. 0x1000_0000.

The base register is found by a data-flow analysis over each function: a
register is "in the window" after `lui` with an immediate whose address is in
the window, and stays so through the arithmetic that builds an address from it
(addi, add, slli, mul, mv, ...); a load or a `csrr` gives an ordinary value.
The analysis follows the branches of a function (a store in a loop whose base is
advanced at the end of the loop is found) and ends at a call: the caller-saved
registers are ordinary values afterwards. Stores through sp are stack accesses.
Limit: the analysis is per function, so an address that a called function
computes and returns is not followed (the runtime computes it inline).

usage: check_plic_stores.py [--objdump PATH] [--lo ADDR] [--hi ADDR] [-q] FILE...

Exit status: 0 no such store, 1 at least one store found (listed), 2 usage or
tool error (no objdump, unreadable file, nothing disassembled).
"""

import argparse
import os
import re
import shutil
import subprocess
import sys

INT_REGS = set(
    ["zero", "ra", "sp", "gp", "tp", "fp"]
    + [f"t{i}" for i in range(7)]
    + [f"s{i}" for i in range(12)]
    + [f"a{i}" for i in range(8)]
)
CALLER_SAVED = {"ra", "t0", "t1", "t2", "t3", "t4", "t5", "t6"} | {f"a{i}" for i in range(8)}

STORES_64 = {"sd", "sdsp", "fsd", "fsdsp"}
LOADS = {"lb", "lbu", "lh", "lhu", "lw", "lwu", "ld", "lwsp", "ldsp", "lr.w", "lr.d",
         "flw", "fld", "flwsp", "fldsp", "lq", "lqsp"}
NO_RESULT = {"j", "jr", "ret", "tail", "call", "jal", "jalr", "nop", "ebreak", "ecall",
             "mret", "sret", "wfi", "fence", "fence.i", "unimp", "c.unimp"}
BRANCHES = {"beq", "bne", "blt", "bge", "bltu", "bgeu", "beqz", "bnez", "blez", "bgez",
            "bltz", "bgtz", "bgt", "ble", "bgtu", "bleu"}
UNCONDITIONAL = {"j", "jr", "ret", "tail", "mret", "sret", "unimp", "c.unimp"}

INSN_LINE = re.compile(r"^\s*([0-9a-f]+):\t[0-9a-f ]+\t(\S+)(?:\s+([^#<]*?))?\s*(?:#.*|<.*>)?\s*$")
FUNC = re.compile(r"^([0-9a-f]+) <([^>]+)>:\s*$")
SECTION = re.compile(r"^Disassembly of section (\S+):")
MEMBER = re.compile(r"^(\S.*):\s+file format ")


def die(msg, code=2):
    print(f"check_plic_stores: {msg}", file=sys.stderr)
    sys.exit(code)


def regs_of(operands):
    """The integer register names in an operand string, in order."""
    return [t for t in re.findall(r"[a-z][a-z0-9]*", operands) if t in INT_REGS]


def parse_int(text):
    try:
        return int(text, 0)
    except ValueError:
        return None


def window_imm(imm20, lo, hi):
    """lui rd, imm20 puts imm20 << 12 into rd (sign-extended from bit 31)."""
    value = (imm20 & 0xFFFFF) << 12
    if value & 0x80000000:
        value -= 1 << 32
    return lo <= value < hi


def transfer(mnemonic, operands, state, lo, hi):
    """The set of registers that hold a window address after one instruction."""
    m = mnemonic[2:] if mnemonic.startswith("c.") else mnemonic
    state = set(state)
    ops = [o.strip() for o in operands.split(",")] if operands.strip() else []
    if m in STORES_64 or m in BRANCHES or m in {"sb", "sh", "sw", "swsp", "sq",
                                               "fsw", "fswsp", "nop", "fence", "fence.i"}:
        return state
    if m in {"jal", "jalr", "call"} or m == "tail":
        if m == "tail":
            return state
        return {r for r in state if r not in CALLER_SAVED}
    if m in NO_RESULT:
        return state
    if not ops or ops[0] not in INT_REGS:
        return state
    rd = ops[0]
    if rd == "zero":
        return state
    if m == "lui":
        imm = parse_int(ops[1]) if len(ops) > 1 else None
        taint = imm is not None and window_imm(imm, lo, hi)
    elif m == "li":
        imm = parse_int(ops[1]) if len(ops) > 1 else None
        taint = imm is not None and lo <= imm < hi
    elif m in LOADS or m.startswith("csr") or m == "auipc" or m.startswith("amo") \
            or m.startswith("sc.") or m.startswith("lr.") or m.startswith("f"):
        taint = False
    else:
        taint = any(r in state for r in regs_of(",".join(ops[1:])))
    if taint:
        state.add(rd)
    else:
        state.discard(rd)
    return state


def store_base(mnemonic, operands):
    """The base register of a 64-bit store, or None if the instruction is none."""
    m = mnemonic[2:] if mnemonic.startswith("c.") else mnemonic
    if m in STORES_64:
        found = re.search(r"\(([a-z0-9]+)\)", operands)
        if found:
            return found.group(1)
        return None
    if m == "sc.d" or (m.startswith("amo") and m.endswith(".d")):
        found = re.search(r"\(([a-z0-9]+)\)", operands)
        return found.group(1) if found else None
    return None


def branch_target(mnemonic, operands):
    """The address that a branch or jump goes to, if it is in the listing."""
    m = mnemonic[2:] if mnemonic.startswith("c.") else mnemonic
    if m in BRANCHES or m == "j" or m == "jal":
        found = re.findall(r"\b([0-9a-f]+)\s*$", operands.strip())
        if found:
            return int(found[-1], 16)
    return None


def analyse_function(insns, lo, hi):
    """insns: [(addr, mnemonic, operands, text)]; returns the offending ones."""
    index = {addr: i for i, (addr, _, _, _) in enumerate(insns)}
    states = [None] * len(insns)
    work = []
    if insns:
        states[0] = set()
        work.append(0)
    findings = {}
    while work:
        i = work.pop()
        addr, mnemonic, operands, text = insns[i]
        before = states[i]
        base = store_base(mnemonic, operands)
        if base is not None and base != "sp" and base in before:
            findings[addr] = text
        after = transfer(mnemonic, operands, before, lo, hi)
        m = mnemonic[2:] if mnemonic.startswith("c.") else mnemonic
        successors = []
        if m not in UNCONDITIONAL:
            successors.append(i + 1)
        target = branch_target(mnemonic, operands)
        if target is not None and target in index and m != "jal":
            successors.append(index[target])
        for s in successors:
            if s >= len(insns):
                continue
            merged = after if states[s] is None else states[s] | after
            if states[s] is None or merged != states[s]:
                states[s] = merged
                work.append(s)
    return sorted(findings.items())


def disassemble(objdump, path):
    try:
        out = subprocess.run([objdump, "-d", path], capture_output=True, text=True, check=False)
    except OSError as exc:
        die(f"cannot run {objdump}: {exc}")
    if out.returncode != 0:
        die(f"{objdump} -d {path} failed: {out.stderr.strip()}")
    return out.stdout


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("files", nargs="+")
    ap.add_argument("--objdump", default=None, help="riscv64-elf-objdump (default: from PATH)")
    ap.add_argument("--lo", type=lambda s: int(s, 0), default=0x0C000000)
    ap.add_argument("--hi", type=lambda s: int(s, 0), default=0x10000000)
    ap.add_argument("-q", "--quiet", action="store_true", help="print only the findings")
    args = ap.parse_args()

    objdump = args.objdump or os.environ.get("OBJDUMP") or shutil.which("riscv64-elf-objdump")
    if not objdump or not shutil.which(objdump):
        die("no riscv64-elf-objdump (./x toolchain install gnat; the pinned one is on PATH after "
            "sourcing tools/mpfs-env.sh)")

    total = 0
    functions = 0
    bad = 0
    for path in args.files:
        if not os.path.isfile(path):
            die(f"{path}: no such file")
        member = os.path.basename(path)
        current = None
        insns = []

        def flush():
            nonlocal bad, functions
            if current is None or not insns:
                return
            functions += 1
            for addr, text in analyse_function(insns, args.lo, args.hi):
                bad += 1
                print(f"{member}: {current}: 0x{addr:x}: {text}")

        for line in disassemble(objdump, path).splitlines():
            if MEMBER.match(line):
                flush(); current = None; insns = []
                member = MEMBER.match(line).group(1)
                continue
            if SECTION.match(line):
                flush(); current = None; insns = []
                continue
            f = FUNC.match(line)
            if f:
                name = f.group(2)
                if name.startswith(".L"):
                    continue   # a label inside a function
                flush(); insns = []
                current = name
                continue
            mi = INSN_LINE.match(line)
            if mi and current is not None:
                total += 1
                addr = int(mi.group(1), 16)
                mnemonic = mi.group(2)
                operands = mi.group(3) or ""
                insns.append((addr, mnemonic, operands, f"{mnemonic} {operands}".strip()))
        flush()

    if total == 0:
        die("nothing was disassembled (no instruction in " + ", ".join(args.files) + ")")
    if bad:
        print(f"check_plic_stores: FAIL: {bad} 64-bit store(s) through the PLIC window "
              f"0x{args.lo:08X}-0x{args.hi:08X} in {functions} function(s) checked",
              file=sys.stderr)
        return 1
    if not args.quiet:
        print(f"check_plic_stores: ok: no 64-bit store into 0x{args.lo:08X}-0x{args.hi:08X} "
              f"({total} instructions, {functions} functions, {len(args.files)} file(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main())
