#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Show what the serial ports of the Icicle Kit print.

    monitor.py [--secs N] [--port N] [--expect REGEX] [--lab FILE]

Reads MMUART0 .. MMUART<UART_COUNT-1> (lab.conf) for N seconds (default 10) and prints the text of
every port that printed. --port reads one port only. With --expect REGEX the exit status says whether
the text matched: 0 if REGEX (Python syntax) matches, 1 if not (also if nothing was printed); without
it the exit status is 0 when the ports could be read. 2: set-up error.
"""
import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lab  # noqa: E402
from ocd import Serial  # noqa: E402


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--secs", type=float, default=10)
    ap.add_argument("--port", type=int)
    ap.add_argument("--expect", metavar="REGEX")
    ap.add_argument("--lab", metavar="FILE")
    a = ap.parse_args(argv)
    regex = None
    if a.expect is not None:
        try:
            regex = re.compile(a.expect)
        except re.error as e:
            raise SystemExit(f"monitor: invalid --expect regular expression: {e}")
    lab_conf = lab.load(a.lab)
    count = int(lab_conf["UART_COUNT"])
    if a.port is not None and a.port not in range(count):
        raise SystemExit(f"monitor: --port {a.port} is outside MMUART0 .. MMUART{count - 1}")
    ports = [a.port] if a.port is not None else list(range(count))
    s = Serial({i: lab.serial_path(lab_conf, i) for i in ports})
    s.pump(a.secs)
    s.close()
    printed = False
    for i in sorted(s.data):
        if s.data[i]:
            printed = True
            print(f"MMUART{i}:")
            print(s.data[i].decode("latin1").replace("\r", ""))
    if not printed:
        print("no serial output")
    if regex is None:
        return 0
    text = "\n".join(d.decode("latin1").replace("\r", "") for d in s.data.values())
    if regex.search(text):
        print(f"expect: matched /{regex.pattern}/")
        return 0
    print(f"expect: NOT matched /{regex.pattern}/")
    return 1


if __name__ == "__main__":
    sys.exit(lab.run(main, uses_hart=False))
