#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""A stand-in for fpgenprog, for the tests of hw/bootmode.py (hw/bootprog.py).

It records every call (one line of arguments in $FAKE_FP_LOG), makes the project folder that fpgenprog makes
(proj_fp/proj_fp.pro with an empty <Servers> element, as `fpgenprog new_project` writes it), checks what the real one
checks that matters here (the folder exists, a content file is Intel hex) and prints a line. run_action
rewrites the project the way the real one does after a run with a board: a <programmer> element stands in
front of <Servers>. It does no hardware and no bitstream.

  FAKE_FP_LOG         file that gets one line per call (required)
  FAKE_FP_FAIL        "<subcommand>[:<status>]": that subcommand ends with that status (default 1)
  FAKE_FP_SILENT      1: run_action prints nothing
  FAKE_FP_PROGRAMMER  serial number of the programmer it "finds" (default STANDIN1)
  FAKE_FP_HONOUR      1: run_action takes the programmer named in proj_fp.pro, if there is one, before it
                      takes the one it finds; the real fpgenprog is not known to do this
"""
import os
import re
import shlex
import sys
from pathlib import Path

SERVERS = re.compile(r"^([ \t]*)<Servers>", re.M)
PROGRAMMER = re.compile(r"<programmer\b.*?</programmer>", re.S)
PROJECT = """<project name="proj_fp" version="1.2">
    <ProgrammingInterface>
        JTAGMode
    </ProgrammingInterface>
    <Servers>
    </Servers>
</project>
"""


def option(args: list[str], name: str) -> str | None:
    return args[args.index(name) + 1] if name in args else None


def main(argv: list[str]) -> int:
    with open(os.environ["FAKE_FP_LOG"], "a", encoding="utf-8") as f:
        f.write(shlex.join(argv) + "\n")
    if not argv:
        print("usage: fpgenprog <subcommand>", file=sys.stderr)
        return 2
    sub, args = argv[0], argv[1:]
    fail = os.environ.get("FAKE_FP_FAIL", "")
    if fail.partition(":")[0] == sub:
        print(f"fake fpgenprog: {sub} failed on request", file=sys.stderr)
        return int(fail.partition(":")[2] or 1)
    location = option(args, "--location")
    if location is None:
        print(f"fake fpgenprog: {sub}: --location is required", file=sys.stderr)
        return 2
    project = Path(location)
    pro = project / "proj_fp" / "proj_fp.pro"
    if sub == "new_project":
        pro.parent.mkdir(parents=True, exist_ok=True)
        pro.write_text(PROJECT, encoding="utf-8")
        print("fake fpgenprog: Project saved.")
        return 0
    if not pro.is_file():
        print(f"fake fpgenprog: {sub}: no project in {location}", file=sys.stderr)
        return 2
    if sub in ("envm_client", "snvm_client"):
        content = option(args, "--content_file")
        if content is None or not Path(content).is_file() or not Path(content).read_text().startswith(":"):
            print(f"fake fpgenprog: {sub}: the content file is not Intel hex", file=sys.stderr)
            return 2
        return 0
    if sub in ("mss_boot_info", "generate_bitstream"):
        return 0
    if sub == "run_action":
        action = option(args, "--action")
        text = pro.read_text(encoding="utf-8")
        found = PROGRAMMER.search(text)
        named = re.search(r"<id>\s*(\S+)\s*</id>", found.group(0)) if found else None
        serial = named.group(1) if named and os.environ.get("FAKE_FP_HONOUR") == "1" else os.environ.get("FAKE_FP_PROGRAMMER", "STANDIN1")
        element = f'<programmer status="enable" type="FlashPro6Lite"><name>{serial}</name><id>{serial}</id></programmer>'
        if named and os.environ.get("FAKE_FP_HONOUR") == "1":
            element = found.group(0)   # the programmer is named: its element stays as it is
        text, n = PROGRAMMER.subn(lambda _: element, text, count=1)
        if not n:   # a new project has an empty <Servers>; the programmer goes in front of it
            text = SERVERS.sub(lambda m: f"{m.group(1)}{element}\n{m.group(0)}", text, count=1)
        pro.write_text(text, encoding="utf-8")
        if os.environ.get("FAKE_FP_SILENT") != "1":
            print(f"fake fpgenprog: {action} on FlashPro {serial}")
        return 0
    print(f"fake fpgenprog: unknown subcommand {sub}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
