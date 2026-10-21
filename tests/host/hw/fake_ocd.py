# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""A stand-in for the telnet port of OpenOCD, for the tests of hw/.

    fake_ocd.py PORT_FILE LOG [--uart FILE --print TEXT] [--trap] [--result HEX] [--hang-on CMD]

Listens on a free port, which it writes to PORT_FILE once it listens, and serves one connection
after the other. Every command line it receives is appended to LOG. It answers like the telnet
port: the echo of the command, the output, then the prompt "> ".

  --uart FILE --print TEXT   on "resume", append TEXT (and CR LF) to FILE, as a guest writing to a UART
  --trap                     the trap recorder at 0x08101000 reports a trap (mcause 2, mepc 0x1234)
  --hang-on CMD              a command that starts with CMD (and every later one) gets no answer, as from an
                             OpenOCD that is stuck on a hung bus; the connection stays open
  --result HEX               the first word of the probe result block (0x08102000) reads HEX
"""
import socket
import sys


def main():
    args = sys.argv[1:]
    port_file, log = args[0], args[1]
    opts = args[2:]
    uart = text = None
    trap = "--trap" in opts
    result = 0
    hang = opts[opts.index("--hang-on") + 1] if "--hang-on" in opts else None
    if "--uart" in opts:
        uart = opts[opts.index("--uart") + 1]
        text = opts[opts.index("--print") + 1]
    if "--result" in opts:
        result = int(opts[opts.index("--result") + 1], 16)

    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 0))
    srv.listen(5)
    with open(port_file, "w") as f:
        f.write(str(srv.getsockname()[1]))

    def answer(cmd):
        if cmd.startswith("resume") and uart:
            with open(uart, "ab") as f:
                f.write(text.encode() + b"\r\n")
        if cmd.startswith("reg "):
            return f"{cmd.split()[1]} (/64): 0x0000000000000000"
        if cmd.startswith("mdd "):
            addr = int(cmd.split()[1], 16)
            value = 0
            if trap and addr == 0x08101000:
                value = 1
            elif trap and addr == 0x08101008:
                value = 2
            elif trap and addr == 0x08101010:
                value = 0x1234
            elif addr == 0x08102000:
                value = result
            return f"0x{addr:08x}: {value:016x}"
        if cmd.startswith("mdw "):
            addr = int(cmd.split()[1], 16)
            return f"0x{addr:08x}: 00000000"
        return ""

    while True:
        conn, _ = srv.accept()
        conn.sendall(b"Open On-Chip Debugger\r\n> ")
        buf = b""
        hung = False
        while True:
            chunk = conn.recv(4096)
            if not chunk:
                break
            buf += chunk
            while b"\n" in buf:
                line, _, buf = buf.partition(b"\n")
                cmd = line.decode().strip()
                with open(log, "a") as f:
                    f.write(cmd + "\n")
                hung = hung or (hang is not None and cmd.startswith(hang))
                if hung:
                    continue
                conn.sendall(cmd.encode() + b"\r\n" + answer(cmd).encode() + b"\r\n> ")
        conn.close()


if __name__ == "__main__":
    sys.exit(main())
