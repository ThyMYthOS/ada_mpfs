# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""How the serial text of the Icicle Kit is shown: shared by run_image.py and monitor.py.

A view gets the bytes of every port as they arrive (feed), is told about a port that ended (note) and
redraws (tick) while ocd.Serial.pump reads; close ends it. Three views:

  live         one window of 8 lines per port, in which the text scrolls (plain ANSI escape sequences)
  interleaved  complete lines in the order they arrive, each behind "MMUART<n>: "
  blocks       what each port printed, as a block, at the end: a header with the byte count, every line
               behind a "|" gutter

Whatever the view, the text is decoded as UTF-8 (a character that arrives in two pieces is whole), a byte
that is not valid UTF-8 shows as \\xNN, CR LF and a lone CR end a line, and a tab stays. The target's
colours (SGR sequences, ESC [ ... m) pass through when colours are on and are removed when they are off, and
they end with the line, so no colour reaches the next line or window. Every other escape sequence of the
target (cursor movement, clear screen, OSC, ...) is removed and every other control character shows as \\xNN,
so the target cannot disturb the layout. What --expect matches is raw_text, which depends on neither.
"""
import argparse
import codecs
import os
import re
import shutil
import sys
import time
import unicodedata
from collections import deque

RESET = "\x1b[0m"
_SGR = re.compile(r"(\x1b\[[0-9;:]*m)")
MAX_LINE = 4096            # a line that gets longer is broken here (shown only; the raw text is not touched)
MIN_REDRAW = 0.03          # s between two redraws of the live view
PALETTE = ("36", "33", "35", "32", "34", "91")   # SGR colour of MMUART <n>: PALETTE[n % 6]


def add_arguments(ap: argparse.ArgumentParser) -> None:
    ap.add_argument("--view", choices=("auto", "live", "interleaved", "blocks"), default="auto",
                    help="how the serial text is shown: live (a window of 8 lines per port; auto on a terminal), "
                         "interleaved (lines in the order they arrive, behind MMUART<n>:; auto otherwise) or blocks "
                         "(one block per port at the end)")
    ap.add_argument("--color", choices=("auto", "always", "never"), default="auto",
                    help="colours: auto = on a terminal, unless NO_COLOR is set (FORCE_COLOR turns them on)")


def raw_text(data: bytes) -> str:
    """The text of a port that --expect is matched against: UTF-8 (invalid bytes as \\xNN), CR removed, the escape
    sequences of the target left in. It is the same in every view and with or without colour."""
    return data.decode("utf-8", "backslashreplace").replace("\r", "")


# --- characters and widths ------------------------------------------------------------------------

_BIDI = frozenset(range(0x202A, 0x202F)) | frozenset(range(0x2066, 0x206A))


def escape(c: str) -> str:
    """The \\xNN, \\uNNNN or \\UNNNNNNNN form of a character."""
    o = ord(c)
    return "\\x%02x" % o if o < 0x100 else "\\u%04x" % o if o < 0x10000 else "\\U%08x" % o


def show_char(c: str, enc: str | None = None) -> str:
    """c, or its escaped form if it is a control character, a line or paragraph separator, a bidi override, or (with
    <enc>, the encoding of an output that is not UTF-8) a character that the encoding lacks."""
    if c != "\t" and (unicodedata.category(c) in ("Cc", "Zl", "Zp") or ord(c) in _BIDI):
        return escape(c)
    if enc:
        try:
            c.encode(enc)
        except UnicodeEncodeError:
            return escape(c)
    return c


def char_width(c: str) -> int:
    """Columns of a character on a terminal: 0 for combining marks and format characters, 2 for East Asian wide ones."""
    if unicodedata.combining(c) or unicodedata.category(c) in ("Mn", "Me", "Cf"):
        return 0
    return 2 if unicodedata.east_asian_width(c) in ("W", "F") else 1


def visible_width(s: str) -> int:
    return sum(char_width(c) for c in _SGR.sub("", s))


def expand_tabs(s: str, tab: int = 8) -> str:
    out, col = [], 0
    for i, part in enumerate(_SGR.split(s)):
        if i % 2:
            out.append(part)
            continue
        for c in part:
            if c == "\t":
                pad = tab - col % tab
                out.append(" " * pad)
                col += pad
            else:
                out.append(c)
                col += char_width(c)
    return "".join(out)


def fit(s: str, width: int, marker: str) -> str:
    """s cut to <width> visible columns; if it was longer, the last column is <marker>. The SGR sequences stay (they
    have no width) and a cut string ends with a reset."""
    if width <= 0:
        return ""
    if visible_width(s) <= width:
        return s
    out, used, cut = [], 0, False
    for i, part in enumerate(_SGR.split(s)):
        if i % 2:
            out.append(part)
            continue
        for c in part:
            w = char_width(c)
            if used + w > width - 1:
                cut = True
                break
            out.append(c)
            used += w
        if cut:
            break
    return "".join(out) + marker + (RESET if "\x1b" in "".join(out) else "")


# --- the text of one port --------------------------------------------------------------------------

_TEXT, _ESC, _CSI, _STR, _STR_ESC = range(5)


class PortText:
    """The serial text of one port, from bytes to lines: incremental UTF-8, line ends, tabs, colours and the removal of
    what must not reach a terminal. feed returns the lines that the new bytes completed (without line end); what is
    after the last line end is the partial line (partial)."""

    def __init__(self, color: bool, enc: str | None = None):
        self.color = color
        self.enc = enc
        self.dec = codecs.getincrementaldecoder("utf-8")(errors="backslashreplace")
        self.state = _TEXT
        self.seq = ""
        self.cur: list[str] = []   # the pieces of the line so far: characters and SGR sequences
        self.n = 0                 # characters of the line so far
        self.sgr = False           # an SGR sequence of the line is not reset yet
        self.cr = False            # the last character ended a line with CR (a LF behind it is part of it)

    def feed(self, data: bytes, final: bool = False) -> list[str]:
        lines: list[str] = []
        for c in self.dec.decode(data, final):
            self._char(c, lines)
        if final:
            self.state = _TEXT   # an escape sequence that did not end is dropped
        return lines

    def partial(self) -> str:
        """The line so far, "" if it has no character yet."""
        if not self.n:
            return ""
        return "".join(self.cur) + (RESET if self.sgr else "")

    def take_partial(self) -> str | None:
        """The line so far, and start a new one; None if it has no character."""
        line = self.partial()
        self._clear()
        return line or None

    def _clear(self) -> None:
        self.cur, self.n, self.sgr = [], 0, False

    def _end_line(self, lines: list[str]) -> None:
        lines.append("".join(self.cur) + (RESET if self.sgr else ""))
        self._clear()

    def _put(self, piece: str, lines: list[str]) -> None:
        self.cur.append(piece)
        self.n += 1
        if self.n >= MAX_LINE:
            self._end_line(lines)

    def _char(self, c: str, lines: list[str]) -> None:
        st = self.state
        if st == _TEXT:
            if c == "\x1b":
                self.state, self.seq = _ESC, ""
            elif c == "\r":
                self._end_line(lines)
                self.cr = True
            elif c == "\n":
                if not self.cr:
                    self._end_line(lines)
                self.cr = False
            else:
                self.cr = False
                self._put(show_char(c, self.enc), lines)
        elif st == _ESC:
            if c == "[":
                self.state = _CSI
            elif c in "]PX^_":      # OSC, DCS, SOS, PM, APC: a string up to BEL or ST
                self.state = _STR
            elif "\x20" <= c <= "\x2f":   # an intermediate byte (ESC ( B, ...): the final byte follows
                pass
            elif "\x30" <= c <= "\x7e":
                self.state = _TEXT
            else:
                self.state = _TEXT
                self._char(c, lines)
        elif st == _CSI:
            if "\x20" <= c <= "\x3f" and len(self.seq) < 64:
                self.seq += c
            elif "\x40" <= c <= "\x7e":
                if c == "m" and re.fullmatch(r"[0-9;:]*", self.seq) and self.color:
                    self.cur.append(f"\x1b[{self.seq}m")
                    self.sgr = self.seq not in ("", "0")   # False after a reset: the line needs no other
                self.state = _TEXT
            else:    # not part of a sequence (or too long): the sequence ends, the character is text
                self.state = _TEXT
                self._char(c, lines)
        elif st == _STR:
            if c in "\x07\x9c":
                self.state = _TEXT
            elif c == "\x1b":
                self.state = _STR_ESC
            elif c in "\r\n" or len(self.seq) >= 256:
                self.state = _TEXT
                self._char(c, lines)
            else:
                self.seq += c
        else:   # _STR_ESC
            self.state = _TEXT
            if c == "\\":
                return
            self.state = _ESC
            self._char(c, lines)


# --- terminal and options --------------------------------------------------------------------------

def terminal_size(out) -> tuple[int, int]:
    """(columns, rows) of the terminal of <out>, 80 x 24 when it is not one."""
    try:
        size = os.get_terminal_size(out.fileno())
        if size.columns > 0 and size.lines > 0:
            return size.columns, size.lines
    except (OSError, ValueError, AttributeError):
        pass
    size = shutil.get_terminal_size((80, 24))
    return size.columns, size.lines


def is_utf8(out) -> bool:
    try:
        return codecs.lookup(getattr(out, "encoding", None) or "ascii").name == "utf-8"
    except LookupError:
        return False


def use_color(mode: str, out, env) -> bool:
    """--color: always and never as said; auto is off with NO_COLOR, on with FORCE_COLOR, otherwise on for a terminal."""
    if mode in ("always", "never"):
        return mode == "always"
    if env.get("NO_COLOR"):
        return False
    if env.get("FORCE_COLOR") not in (None, "", "0"):
        return True
    return bool(out.isatty()) and env.get("TERM") != "dumb"


def note_line(prog: str, port: int, text: str) -> None:
    print(f"{prog}: MMUART{port}: {text}", file=sys.stderr, flush=True)


class _View:
    def __init__(self, ports, labels, out, color, utf8, prog):
        self.ports = sorted(ports)
        self.labels = labels
        self.out = out
        self.color = color
        self.utf8 = utf8
        self.enc = None if utf8 else getattr(out, "encoding", None) or "ascii"   # what a character must be encodable in
        self.prog = prog
        self.closed = False

    def __enter__(self):
        self.start()
        return self

    def __exit__(self, *exc):
        self.close()

    def start(self) -> None:
        pass

    def tick(self) -> None:
        pass

    def note(self, port: int, text: str) -> None:
        """A port ended or broke: said at once on stderr, below what the view has shown."""
        self.out.flush()
        note_line(self.prog, port, text)

    def close(self) -> None:
        if not self.closed:
            self.closed = True
            self.finish()
            self.out.flush()

    def finish(self) -> None:
        pass


def format_block(port: int, data: bytes, color: bool = False, enc: str | None = None) -> str:
    """What MMUART <port> printed as a block: a header with the byte count, then every line behind a gutter; a last
    line without a line end is marked."""
    pt = PortText(color, enc)
    lines = pt.feed(data, final=True)
    last = pt.take_partial()
    out = [f"MMUART{port} ({len(data)} bytes):"]
    out += ["  | " + line for line in lines]
    if last is not None:
        out.append("  | " + last + "   [no line end]")
    return "\n".join(out)


class BlocksView(_View):
    def __init__(self, *args):
        super().__init__(*args)
        self.data = {p: bytearray() for p in self.ports}

    def feed(self, port: int, chunk: bytes) -> None:
        self.data[port] += chunk

    def finish(self) -> None:
        for p in self.ports:
            if self.data[p]:
                print(format_block(p, bytes(self.data[p]), self.color, self.enc), file=self.out)


class InterleavedView(_View):
    def __init__(self, *args):
        super().__init__(*args)
        self.text = {p: PortText(self.color, self.enc) for p in self.ports}

    def _prefix(self, port: int) -> str:
        if self.color:
            return f"\x1b[{PALETTE[port % len(PALETTE)]}mMMUART{port}:{RESET} "
        return f"MMUART{port}: "

    def feed(self, port: int, chunk: bytes) -> None:
        for line in self.text[port].feed(chunk):
            self.out.write(self._prefix(port) + line + "\n")

    def tick(self) -> None:
        self.out.flush()

    def finish(self) -> None:
        for p in self.ports:
            for line in self.text[p].feed(b"", final=True):
                self.out.write(self._prefix(p) + line + "\n")
            last = self.text[p].take_partial()
            if last is not None:
                self.out.write(self._prefix(p) + last + "\n")


class LiveView(_View):
    """A window per port, HEIGHT lines of text under a header line, on the lines below the cursor. The frame is
    drawn once and then only the rows that changed are rewritten (cursor movement, text, erase to the end of the
    line, all in one write), so nothing flickers. The cursor is hidden meanwhile and shown again by close, which
    also runs on Ctrl+C and on an exception, and leaves it below the last frame."""

    HEIGHT = 8

    def __init__(self, *args):
        super().__init__(*args)
        self.text = {p: PortText(self.color, self.enc) for p in self.ports}
        self.lines = {p: deque(maxlen=self.HEIGHT) for p in self.ports}
        self.count = {p: 0 for p in self.ports}
        self.ended: set[int] = set()
        self.deferred: list[tuple[int, str]] = []
        self.dirty = True
        self.last = 0.0
        self.size = terminal_size(self.out)
        self.h = 0         # content lines per window now
        self.shown: list[str] = []   # the rows on the screen; empty when no frame is there
        self.hidden = False

    @staticmethod
    def height_for(rows: int, nports: int) -> int:
        """Content lines per window on a terminal of <rows> rows: HEIGHT, or fewer so that the frame and the line
        below it fit; below 1 the live view is not possible."""
        return min(LiveView.HEIGHT, (rows - 1) // max(nports, 1) - 1)

    def start(self) -> None:
        self.out.write("\x1b[?25l")
        self.hidden = True
        self._frame(clear=0)

    def note(self, port: int, text: str) -> None:
        self.ended.add(port)
        self.deferred.append((port, text))
        self.dirty = True

    def feed(self, port: int, chunk: bytes) -> None:
        self.count[port] += len(chunk)
        self.lines[port].extend(self.text[port].feed(chunk))
        self.dirty = True

    def tick(self) -> None:
        self._sync(force=False)
        self.out.flush()

    def _sync(self, force: bool) -> None:
        size = terminal_size(self.out)
        if size != self.size:
            self.size = size
            self._frame(clear=len(self.shown))
        elif self.dirty and (force or time.monotonic() - self.last >= MIN_REDRAW):
            self._update()

    def finish(self) -> None:
        for p in self.ports:
            self.lines[p].extend(self.text[p].feed(b"", final=True))
            last = self.text[p].take_partial()
            if last is not None:
                self.lines[p].append(last)
        self.dirty = True
        try:
            self._sync(force=True)
        finally:
            if self.hidden:
                self.out.write("\x1b[?25h")
                self.hidden = False
            self.out.flush()
            for port, text in self.deferred:
                note_line(self.prog, port, text)

    # -- drawing

    def _gutter(self, p: int, empty: bool) -> str:
        g = "│" if self.utf8 else "|"
        if not self.color:
            return g + " "
        return f"\x1b[{'2' if empty else PALETTE[p % len(PALETTE)]}m{g}{RESET} "

    def _header(self, p: int, cols: int) -> str:
        bar = "─" if self.utf8 else "-"
        state = "  [ended]" if p in self.ended else ""
        title = f"{bar}{bar} MMUART{p}  {self.labels[p]}  {self.count[p]} B{state} "
        shown = fit(title, cols, "…" if self.utf8 else ">")
        row = shown + bar * max(cols - visible_width(shown), 0)
        if self.color:
            return f"\x1b[{'2' if not self.count[p] else '1;' + PALETTE[p % len(PALETTE)]}m{row}{RESET}"
        return row

    def _rows(self, cols: int) -> list[str]:
        marker = "…" if self.utf8 else ">"
        rows = []
        for p in self.ports:
            rows.append(self._header(p, cols))
            content = list(self.lines[p])
            part = self.text[p].partial()
            if part:
                content.append(part)
            content = content[-self.h:]
            for line in content:
                rows.append(self._gutter(p, False) + fit(expand_tabs(line), cols - 2, marker))
            rows += [self._gutter(p, True).rstrip()] * (self.h - len(content))
        return rows

    def _frame(self, clear: int) -> None:
        """Draw the whole frame below the cursor, after removing <clear> rows above it (a resize, or nothing)."""
        cols, rows = self.size
        out = f"\x1b[{clear}A\r\x1b[J" if clear else ""
        self.h = self.height_for(rows, len(self.ports))
        if self.h < 1:   # the terminal became too small: nothing is drawn until it is big enough again
            self.shown = []
        else:
            self.shown = self._rows(cols - 1)
            out += "".join(row + "\x1b[K\n" for row in self.shown)
        self.out.write(out)
        self.dirty = False
        self.last = time.monotonic()

    def _update(self) -> None:
        if not self.shown:
            if self.h < 1 and self.dirty:
                self._frame(clear=0)
            return
        rows = self._rows(self.size[0] - 1)
        changed = [i for i, row in enumerate(rows) if row != self.shown[i]]
        self.dirty = False
        self.last = time.monotonic()
        if not changed:
            return
        out, at = [f"\x1b[{len(rows)}A"], 0
        for i in changed:
            if i > at:
                out.append(f"\x1b[{i - at}B")
                at = i
            out.append("\r" + rows[i] + "\x1b[K")
        out.append(f"\x1b[{len(rows) - at}B\r")
        self.out.write("".join(out))
        self.shown = rows


def make_view(mode: str, color: str, labels: dict[int, str], out=None, env=None):
    """The view for --view <mode> and --color <color>, for the ports of <labels> (number -> what to call it).
    auto is live on a terminal and interleaved otherwise; live falls back to interleaved, with a line on stderr,
    when the terminal has too few rows for a window of at least one line per port."""
    out = out or sys.stdout
    env = os.environ if env is None else env
    if hasattr(out, "reconfigure"):
        out.reconfigure(errors="backslashreplace")   # a character that the output encoding lacks must not raise
    args = (list(labels), labels, out, use_color(color, out, env), is_utf8(out), os.path.basename(sys.argv[0]))
    if mode == "auto":
        mode = "live" if out.isatty() and env.get("TERM", "") not in ("", "dumb") else "interleaved"
    if mode == "live":
        rows = terminal_size(out)[1]
        if LiveView.height_for(rows, len(labels)) < 1:
            print(f"{args[5]}: a terminal of {rows} rows is too small for {len(labels)} windows; "
                  "showing the interleaved view", file=sys.stderr)
            mode = "interleaved"
    return {"live": LiveView, "interleaved": InterleavedView, "blocks": BlocksView}[mode](*args)
