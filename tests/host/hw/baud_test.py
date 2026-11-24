# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""The baud rate of the serial devices: hw/lab.py (UART_BAUD, UART<n>_BAUD, --baud N=RATE) and hw/ocd.py (Serial).

    baud_test.py

A pty stands in for a serial device: Serial opens its slave side and sets the speed, which is read back from the
slave. The default stays 115200 for every port. Prints "ok:" or "FAIL:" per case; exits non-zero if one failed.
"""
import os
import sys
import termios
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path[:0] = [str(ROOT / "hw"), str(ROOT / "tests" / "host" / "gen_ada")]

import lab
import ocd
from harness import case, finish, raises


def conf(**more):
    values = lab.read_env_file(lab.EXAMPLE)
    values.update(more)
    return values


def speed_of(rate):
    master, slave = os.openpty()
    path = os.ttyname(slave)
    try:
        serial = ocd.Serial({0: path}, baud={0: rate} if rate else None)
        try:
            return termios.tcgetattr(slave)[4]
        finally:
            serial.close()
    finally:
        os.close(master)
        os.close(slave)


@case("lab.conf.example has UART_BAUD=115200 and a port without a key gets it")
def _():
    values = conf()
    assert values["UART_BAUD"] == "115200"
    assert lab.uart_bauds(values, [0, 2]) == {0: 115200, 2: 115200}


@case("UART<n>_BAUD is the rate of that port alone, --baud N=RATE wins over it and over UART_BAUD")
def _():
    values = conf(UART0_BAUD="230400")
    assert lab.uart_bauds(values, [0, 2]) == {0: 230400, 2: 115200}
    assert lab.uart_bauds(values, [0, 2], ["0=57600", "2=230400"]) == {0: 57600, 2: 230400}
    assert lab.uart_bauds(conf(UART_BAUD="9600"), [1]) == {1: 9600}


@case("a rate that no serial device has, a rate that is no number and a bad --baud are errors")
def _():
    raises(SystemExit, lambda: lab.baud_rate("12345", "UART_BAUD"), "not a baud rate")
    raises(SystemExit, lambda: lab.baud_rate("fast", "UART_BAUD"), "not a baud rate")
    raises(SystemExit, lambda: lab.uart_bauds(conf(), [0], ["230400"]), "N=RATE")
    raises(SystemExit, lambda: lab.uart_bauds(conf(), [0], ["x=230400"]), "N=RATE")
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "lab.conf"
        path.write_text("UART1_BAUD=12345\n")
        raises(SystemExit, lambda: lab.load(str(path)), "UART1_BAUD")


@case("Serial opens a device at 115200 by default and at the rate it is given")
def _():
    assert speed_of(None) == termios.B115200
    assert speed_of(230400) == termios.B230400


finish()
