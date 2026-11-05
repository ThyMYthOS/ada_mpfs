# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""A stand-in for a UART that socat tunnels to a TCP port, for the tests of hw/.

    fake_uart.py PORT_FILE [--listen PORT] STEP...

Listens on a free port of 127.0.0.1 (or on PORT), which it writes to PORT_FILE once it listens, and plays the steps to
every client that connects (one thread per client), as the socat on the machine of the board would:

  send=BYTES   send BYTES (a Python bytes literal, e.g. send='b"line\\r\\n"')
  sleep=SECS   wait
  hold         then keep the connection open until the client closes it (or 60 s pass)
  reset        then end the connection with a reset (RST) instead of a close

Without hold and reset the connection is closed after the last step.
"""
import ast
import socket
import struct
import sys
import threading
import time


def serve(conn, steps):
    try:
        for step in steps:
            key, _, arg = step.partition("=")
            if key == "send":
                conn.sendall(ast.literal_eval(arg))
            elif key == "sleep":
                time.sleep(float(arg))
            elif key == "hold":
                conn.settimeout(60)
                try:
                    while conn.recv(4096):
                        pass
                except OSError:
                    pass
            elif key == "reset":
                conn.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
            else:
                raise SystemExit(f"fake_uart: unknown step {step}")
    except OSError:
        pass
    finally:
        conn.close()


def main():
    port_file, steps, want = sys.argv[1], sys.argv[2:], 0
    if steps[:1] == ["--listen"]:
        want, steps = int(steps[1]), steps[2:]
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", want))
    srv.listen(5)
    with open(port_file, "w") as f:
        f.write(str(srv.getsockname()[1]))
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=serve, args=(conn, steps), daemon=True).start()


if __name__ == "__main__":
    main()
