# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""How the serial text of the Icicle Kit is shown: shared by run_image.py and monitor.py.

A view gets the bytes of every port as they arrive (feed), is told about a port that ended (note) and
redraws (tick) while ocd.Serial.pump reads; close ends it. Two views:

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
import sys
import unicodedata

RESET = "\x1b[0m"
_SGR = re.compile(r"(\x1b\[[0-9;:]*m)")
MAX_LINE = 4096            # a line that gets longer is broken here (shown only; the raw text is not touched)
PALETTE = ("36", "33", "35", "32", "34", "91")   # SGR colour of MMUART <n>: PALETTE[n % 6]


def add_arguments(ap: argparse.ArgumentParser) -> None:
    ap.add_argument("--view", choices=("auto", "interleaved", "blocks"), default="auto",
                    help="how the serial text is shown: interleaved (lines in the order they arrive, behind MMUART<n>:; "
                         "auto) or blocks (one block per port at the end)")
    ap.add_argument("--color", choices=("auto", "always", "never"), default="auto",
                    help="colours: auto = on a terminal, unless NO_COLOR is set (FORCE_COLOR turns them on)")


def raw_text(data: bytes) -> str:
    """The text of a port that --expect is matched against: UTF-8 (invalid bytes as \\xNN), CR removed, the escape
    sequences of the target left in. It is the same in every view and with or without colour."""
    return data.decode("utf-8", "backslashreplace").replace("\r", "")


# --- characters and widths ------------------------------------------------------------------------

_BIDI = frozenset(range(0x202A, 0x202F)) | frozenset(range(0x2066, 0x206A))


def show_char(c: str) -> str:
    """c, or its \\xNN (\\uNNNN) form if it is a control character, a line or paragraph separator or a bidi override."""
    if c != "\t" and (unicodedata.category(c) in ("Cc", "Zl", "Zp") or ord(c) in _BIDI):
        return "\\x%02x" % ord(c) if ord(c) < 0x100 else "\\u%04x" % ord(c)
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

    def __init__(self, color: bool):
        self.color = color
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
                self._put(show_char(c), lines)
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


def format_block(port: int, data: bytes, color: bool = False) -> str:
    """What MMUART <port> printed as a block: a header with the byte count, then every line behind a gutter; a last
    line without a line end is marked."""
    pt = PortText(color)
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
                print(format_block(p, bytes(self.data[p]), self.color), file=self.out)


class InterleavedView(_View):
    def __init__(self, *args):
        super().__init__(*args)
        self.text = {p: PortText(self.color) for p in self.ports}

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


def make_view(mode: str, color: str, labels: dict[int, str], out=None, env=None):
    """The view for --view <mode> and --color <color>, for the ports of <labels> (number -> what to call it).
    auto is interleaved."""
    out = out or sys.stdout
    env = os.environ if env is None else env
    if hasattr(out, "reconfigure"):
        out.reconfigure(errors="backslashreplace")   # a character that the output encoding lacks must not raise
    args = (list(labels), labels, out, use_color(color, out, env), is_utf8(out), os.path.basename(sys.argv[0]))
    if mode == "auto":
        mode = "interleaved"
    return {"interleaved": InterleavedView, "blocks": BlocksView}[mode](*args)
