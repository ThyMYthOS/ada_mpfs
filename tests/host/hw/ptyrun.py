# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""Run a command on a pseudo-terminal and print the screen it left, for the tests of the live view in hw/.

    ptyrun.py [--rows R] [--cols C] [--int-after SECS] [--resize SECS:ROWSxCOLS] [--attrs] [--raw FILE]
              [--first-seen TEXT] [--env NAME=VALUE]... -- COMMAND...

The command runs as the leader of a session with the pseudo-terminal as its terminal (like a shell job), at a size
of R rows and C columns (default 24 x 80), TERM=xterm and UTF-8 output unless --env says otherwise. --int-after
types Ctrl+C after SECS seconds (the terminal sends SIGINT to the command), --resize changes the size of the terminal
at SECS (the command gets SIGWINCH). Everything the command wrote is fed into a small screen emulator, which knows
what a live view may use: printable characters (East Asian wide ones take two cells), CR, LF with scrolling, cursor
up/down/forward/back, erase in line and in display, cursor position, SGR colours and the cursor visibility
(ESC[?25h/l). Any other escape sequence is not ignored but listed: the emulator is strict on purpose.

Prints:
    rc=<exit status of the command, 128+n after a signal n>
    cursor_visible=<1 or 0>
    cursor=<row>,<column>              (0 based)
    first_seen_ms=<when TEXT first showed in the output, -1 if never>      (only with --first-seen)
    unknown=<the sequences it does not know, or "none">
    screen:
    <the rows of the screen up to the last one that is not empty, without trailing blanks>

With --attrs a run of cells that has SGR attributes is shown as <ATTR;ATTR>text</>, so a test sees colours and
whether one leaks. --raw writes the bytes the command wrote to FILE.
"""
import codecs
import fcntl
import os
import pty
import select
import signal
import struct
import sys
import termios
import time
import unicodedata


def width(c):
    if unicodedata.combining(c) or unicodedata.category(c) in ("Mn", "Me", "Cf"):
        return 0
    return 2 if unicodedata.east_asian_width(c) in ("W", "F") else 1


class Screen:
    def __init__(self, rows, cols):
        self.rows, self.cols = rows, cols
        self.grid = [[(" ", ())] * cols for _ in range(rows)]
        self.r = self.c = 0
        self.wrap = False
        self.attr = ()
        self.visible = True
        self.unknown = []
        self.state, self.seq = "text", ""

    def resize(self, rows, cols):
        grid = [[(" ", ())] * cols for _ in range(rows)]
        for r in range(min(rows, self.rows)):
            for c in range(min(cols, self.cols)):
                grid[r][c] = self.grid[r][c]
        self.grid, self.rows, self.cols = grid, rows, cols
        self.r, self.c, self.wrap = min(self.r, rows - 1), min(self.c, cols - 1), False

    def feed(self, text):
        for ch in text:
            self.char(ch)

    def scroll(self):
        self.grid.pop(0)
        self.grid.append([(" ", ())] * self.cols)

    def put(self, ch):
        w = width(ch)
        if w == 0:
            return   # a combining mark: no cell of its own
        if self.wrap or self.c + w > self.cols:
            self.c, self.wrap = 0, False
            if self.r == self.rows - 1:
                self.scroll()
            else:
                self.r += 1
        self.grid[self.r][self.c] = (ch, self.attr)
        if w == 2:
            self.grid[self.r][self.c + 1] = ("", self.attr)
        self.c += w
        if self.c >= self.cols:
            self.c, self.wrap = self.cols - 1, True

    def char(self, ch):
        if self.state == "text":
            if ch == "\x1b":
                self.state = "esc"
            elif ch == "\r":
                self.c, self.wrap = 0, False
            elif ch == "\n":
                self.wrap = False
                if self.r == self.rows - 1:
                    self.scroll()
                else:
                    self.r += 1
            elif ch < " " or ch == "\x7f":
                self.unknown.append(repr(ch))
            else:
                self.put(ch)
        elif self.state == "esc":
            if ch == "[":
                self.state, self.seq = "csi", ""
            else:
                self.unknown.append("ESC " + repr(ch))
                self.state = "text"
        else:
            if "\x30" <= ch <= "\x3f" or "\x20" <= ch <= "\x2f":
                self.seq += ch
                return
            self.state = "text"
            self.csi(self.seq, ch)

    def csi(self, seq, final):
        nums = [int(x) if x.isdigit() else 0 for x in seq.lstrip("?").split(";")] if seq else []
        n = nums[0] if nums and nums[0] else 1
        self.wrap = False
        if final == "A":
            self.r = max(self.r - n, 0)
        elif final == "B":
            self.r = min(self.r + n, self.rows - 1)
        elif final == "C":
            self.c = min(self.c + n, self.cols - 1)
        elif final == "D":
            self.c = max(self.c - n, 0)
        elif final == "K" and seq in ("", "0"):
            for c in range(self.c, self.cols):
                self.grid[self.r][c] = (" ", ())
        elif final == "J" and seq in ("", "0"):
            for c in range(self.c, self.cols):
                self.grid[self.r][c] = (" ", ())
            for r in range(self.r + 1, self.rows):
                self.grid[r] = [(" ", ())] * self.cols
        elif final == "H":
            self.r = min((nums[0] or 1) - 1 if nums else 0, self.rows - 1)
            self.c = min((nums[1] or 1) - 1 if len(nums) > 1 else 0, self.cols - 1)
        elif final == "m":
            if seq in ("", "0"):
                self.attr = ()
            else:
                self.attr = self.attr + (seq,)
        elif final in "hl" and seq == "?25":
            self.visible = final == "h"
        else:
            self.unknown.append(f"ESC [ {seq}{final}")

    def dump(self, attrs):
        lines = []
        for row in self.grid:
            out, cur = [], ()
            for ch, a in row:
                if attrs and a != cur:
                    out.append("</>" if cur else "")
                    out.append("<" + ";".join(a) + ">" if a else "")
                    cur = a
                out.append(ch)
            if attrs and cur:
                out.append("</>")
            lines.append("".join(out).rstrip())
        while lines and not lines[-1]:
            lines.pop()
        return lines


def main():
    args = sys.argv[1:]
    rows, cols, int_after, resize, attrs, raw, seen_text, seen = 24, 80, None, None, False, None, None, None
    env = dict(os.environ, TERM="xterm", PYTHONIOENCODING="utf-8")
    for k in ("NO_COLOR", "FORCE_COLOR", "COLUMNS", "LINES"):
        env.pop(k, None)
    while args and args[0] != "--":
        opt = args.pop(0)
        if opt == "--rows":
            rows = int(args.pop(0))
        elif opt == "--cols":
            cols = int(args.pop(0))
        elif opt == "--int-after":
            int_after = float(args.pop(0))
        elif opt == "--resize":
            at, _, size = args.pop(0).partition(":")
            r, _, c = size.partition("x")
            resize = (float(at), int(r), int(c))
        elif opt == "--attrs":
            attrs = True
        elif opt == "--raw":
            raw = args.pop(0)
        elif opt == "--first-seen":
            seen_text = args.pop(0)
        elif opt == "--env":
            k, _, v = args.pop(0).partition("=")
            env[k] = v
        else:
            raise SystemExit(f"ptyrun: unknown option {opt}")
    cmd = args[1:]
    pid, master = pty.fork()
    if pid == 0:
        fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        os.execvpe(cmd[0], cmd, env)
    screen = Screen(rows, cols)
    dec = codecs.getincrementaldecoder("utf-8")(errors="replace")
    start = time.monotonic()
    data, text = b"", ""
    while True:
        now = time.monotonic() - start
        if int_after is not None and now >= int_after:
            os.write(master, b"\x03")
            int_after = None
        if resize is not None and now >= resize[0]:
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", resize[1], resize[2], 0, 0))
            screen.resize(resize[1], resize[2])
            resize = None
        if now > 60:
            os.kill(pid, signal.SIGKILL)
        ready, _, _ = select.select([master], [], [], 0.05)
        if ready:
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break
            if not chunk:
                break
            data += chunk
            piece = dec.decode(chunk)
            screen.feed(piece)
            text += piece
            if seen_text and seen is None and seen_text in text:
                seen = int((time.monotonic() - start) * 1000)
    _, status = os.waitpid(pid, 0)
    rc = os.waitstatus_to_exitcode(status)
    if raw:
        with open(raw, "wb") as f:
            f.write(data)
    print(f"rc={rc if rc >= 0 else 128 - rc}")
    print(f"cursor_visible={int(screen.visible)}")
    print(f"cursor={screen.r},{screen.c}")
    if seen_text:
        print(f"first_seen_ms={-1 if seen is None else seen}")
    print("unknown=" + (" ".join(screen.unknown) or "none"))
    print("screen:")
    print("\n".join(screen.dump(attrs)))


if __name__ == "__main__":
    main()
