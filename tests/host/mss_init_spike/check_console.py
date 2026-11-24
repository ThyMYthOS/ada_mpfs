#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Manuel Stahl <thymythos@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
"""The console of mss_init_spike: complete, in order, the verdict last.

  check_console.py CONSOLE IMAGE full|stopped|dropped
  check_console.py STATUS ticks N [fabric TICK ID:COUNT,ID:COUNT...]
  check_console.py STATUS silent

CONSOLE is what the image sent to MMUART0 (a file of QEMU's -serial). The image sends its log, then
`<image>: log: N bytes through the ring, D dropped, I sink interrupt(s)`, then the verdict. This checks that

  - the bytes that arrived before the line "log:" are exactly the N bytes that went through the ring (nothing lost
    or duplicated on the way from the ring to the port), and the line says the dropped bytes it counted;
  - the verdict (MSS INIT ...) is the last line;
  - full: the lines are all there, in the order of the run: the header, a phase line and a snapshot for each of the
    five phases, the proofs, the state of MMUART0, the entries run, the log line, the verdict; the sink sent by
    interrupt (I > 0); no byte is dropped;
  - stopped: the sequence ended at a poll: a TIMEOUT line, the phases before it with their snapshots, none after,
    the log is sent and the last line is MSS INIT FAILED;
  - dropped: the ring was too small: D > 0, the line "N bytes dropped" says the same number, the verdict is the last
    line and the rest of the log, the part that fitted, is in order.

STATUS is what the image sent to MMUART0: after the verdict on the console, one line per period, "tick K: mtime
0x........ PLL_CTRL 0x........ LOCK b fabric: ...", with K = 1 .. N in order and mtime growing (ticks N), or nothing
(silent: the sequence stopped, so there is no loop). The fabric part is "none" or the sources that have fired, in
ascending order, "F2M_<n>(<id>) x<count> @0x<mtime of the first occurrence> masked", two to a line, more on continuation
lines "tick K: fabric: ..." of the same tick; with `fabric TICK ID:COUNT,...` the ticks before TICK say none and every
tick from TICK on lists exactly those sources, with the same counts and first-occurrence mtime (every source that has
occurred appears in every following line), F2M_<n> being ID 118 + n. The console is MMUART2 (115200 baud): the divisor of the port is in the line
"MMUART2 LCR ... DLR 0x00000016 DMR 0x00000000" (the QEMU model ignores the divisor, so it is checked as register
contents here and in compare_trace.py).

Exit status: 0 holds, 1 does not (the message says what), 2 usage.
"""
import re
import sys


def fail(message):
    print(message)
    return 1


def in_order(text, patterns):
    position = 0
    for pattern in patterns:
        found = re.compile(pattern, re.M).search(text, position)
        if not found:
            return f"no /{pattern}/ after offset {position} (the line is missing or out of order)"
        position = found.end()
    return None


SOURCE = r"F2M_(\d+)\((\d+)\) x(\d+) @0x([0-9a-f]{8}) masked"


def status(path, mode, count, spec=None):
    text = open(path, "rb").read().decode("ascii", errors="replace")
    if mode == "silent":
        return fail(f"{len(text)} bytes on MMUART0, wanted none") if text else ok("nothing on MMUART0: no loop after a stop")
    lines = text.split("\r\n")
    if lines.pop() != "":
        return fail("the last status line does not end with CR LF")
    ticks, times, fabric = {}, {}, {}
    for line in lines:
        m = re.fullmatch(r"tick (\d+): mtime 0x([0-9a-f]{8}) PLL_CTRL 0x([0-9a-f]{8}) LOCK ([01]) fabric:(.*)", line)
        c = re.fullmatch(r"tick (\d+): fabric:(.*)", line)
        if m:
            number, rest = int(m.group(1)), m.group(5)
            if number != len(ticks) + 1:
                return fail(f"status line {line!r} is not tick {len(ticks) + 1}")
            ticks[number] = line
            times[number] = int(m.group(2), 16)
            fabric[number] = []
        elif c and int(c.group(1)) == len(ticks):
            number, rest = int(c.group(1)), c.group(2)
        else:
            return fail(f"status line {line!r}")
        if rest.strip() == "none":
            if fabric[number]:
                return fail(f"tick {number}: none after sources")
            continue
        for item in rest.split(", "):
            found = re.fullmatch(r" ?" + SOURCE, item)
            if not found or int(found.group(2)) != 118 + int(found.group(1)):
                return fail(f"tick {number}: {item!r} is not a fabric source of the form F2M_<n>(<118 + n>) x<count> @0x<mtime> masked")
            fabric[number].append((int(found.group(2)), int(found.group(3)), int(found.group(4), 16)))
    if len(ticks) != int(count):
        return fail(f"{len(ticks)} status lines, wanted {count}")
    order = [times[k] for k in sorted(times)]
    if order != sorted(set(order)):
        return fail(f"mtime does not grow: {order}")
    note = "fabric: none in every tick"
    if spec:
        first = int(spec[0])
        want = [(int(i), int(n)) for i, n in (x.split(":") for x in spec[1].split(","))]
        seen = None
        for k in sorted(fabric):
            sources = fabric[k]
            if k < first:
                if sources:
                    return fail(f"tick {k}: sources before the tick {first} of the injection: {sources}")
                continue
            if [(i, n) for i, n, _ in sources] != sorted(want) or [i for i, _, _ in sources] != sorted(i for i, _ in want):
                return fail(f"tick {k}: fabric sources {sources}, wanted {sorted(want)} (id, count)")
            if seen is not None and sources != seen:
                return fail(f"tick {k}: the sources changed from {seen} to {sources}: a source must keep its count and first mtime")
            seen = sources
        if seen is None:
            return fail(f"no tick from {first} on")
        note = f"from tick {first} on every line lists {want} (counts, first-occurrence mtime and masked as injected, ascending, repeated)"
    elif any(fabric.values()):
        return fail("fabric sources listed, none expected")
    return ok(f"{len(ticks)} status lines on MMUART0, K = 1 .. {len(ticks)}, mtime growing ({order[0]:#x} .. {order[-1]:#x}); {note}")


def main(argv):
    if len(argv) in (4, 7) and argv[2] == "ticks" or len(argv) == 3 and argv[2] == "silent":
        return status(argv[1], argv[2], argv[3] if len(argv) >= 4 else "0", argv[5:7] if len(argv) == 7 else None)
    if len(argv) != 4 or argv[3] not in ("full", "stopped", "dropped"):
        print(__doc__, file=sys.stderr)
        return 2
    path, image, mode = argv[1:]
    try:
        data = open(path, "rb").read()
    except OSError as err:
        print(f"check_console: {err}", file=sys.stderr)
        return 2
    text = data.decode("ascii", errors="replace")
    name = re.escape(image)
    log = re.search(rf"^{name}: log: (\d+) bytes through the ring, (\d+) dropped, (\d+) sink interrupt", text, re.M)
    if not log:
        return fail("no line 'log: N bytes through the ring, ...'")
    through, dropped, interrupts = (int(x) for x in log.groups())
    before = len(text[:log.start()].encode("ascii", errors="replace"))
    if before != through:
        return fail(f"{before} bytes arrived before the line 'log:', {through} went through the ring")
    lines = [line for line in text.splitlines() if line.strip()]
    if not re.search(rf"^{name}: MSS INIT (OK|DONE WITH TIMEOUTS|FAILED)$", lines[-1]):
        return fail(f"the last line is not the verdict: {lines[-1]!r}")
    if text.count("\r\n") != text.count("\n"):
        return fail("a line does not end with CR LF")
    p = f"^{name}: "
    if mode == "dropped":
        said = re.search(rf"{p}(\d+) bytes dropped \(the log did not fit in the ring of (\d+) bytes\)\r?$", text, re.M)
        if not said or int(said.group(1)) != dropped or dropped == 0:
            return fail(f"the line 'N bytes dropped' is missing or does not say the {dropped} bytes that the log line counts")
        problem = in_order(text, [p + "MSS init from ", p + "design ", p + "xml sha256 [0-9a-f]{64}"])
        if problem:
            return fail(problem)
        return ok(f"ring too small: {dropped} bytes dropped and said so, {through} bytes through the ring all arrived, "
                  f"the verdict is last")
    if dropped:
        return fail(f"{dropped} bytes dropped, wanted none")
    phases = []
    for number, key in enumerate(("refclk", "io", "mssio", "sgmii", "pll"), 1):
        phases += [rf"{p}phase {number} {key}: entries \d+-\d+, \d+ run, \d+ poll timeout", rf"{p}snapshot {number} CLOCK_CONFIG_CR 0x[0-9a-f]{{8}} MSSIO_CONTROL_CR 0x[0-9a-f]{{8}} SUBBLK_CLOCK_CR 0x[0-9a-f]{{8}} SOFT_RESET_CR 0x[0-9a-f]{{8}}, "]
        if mode == "stopped" and number == 4:
            break
    if mode == "stopped":
        # the stop is in phase 4 (QEMU's SGMII PLL does not lock): the timeout line comes with the phase it is in
        phases.insert(-1, p + r"TIMEOUT entry \d+: ")
        if re.search(rf"{p}phase 5 ", text, re.M):
            return fail("a phase after the poll that timed out")
    tail = [p + r"mtime 0x[0-9a-f]{8} then 0x[0-9a-f]{8} after 100 us by mcycle: ", p + r"MSS PLL: PLL_CTRL 0x[0-9a-f]{8}, LOCK [01]",
            p + r"MMUART2 LCR 0x00000003 MCR 0x[0-9a-f]{8} DLR 0x00000016 DMR 0x00000000", p + r"\d+ of \d+ entries run, ",
            p + "log: ", p + r"fabric interrupts before the loop: (none|\d+ x\d+(, \d+ x\d+)*)", p + (r"status line on MMUART0 \(230400 baud\) every \d+ ms" if mode == "full"
                              else "no status lines on MMUART0: the sequence stopped"), p + "MSS INIT "]
    problem = in_order(text, [p + "MSS init from ", p + "design ", p + "xml sha256 [0-9a-f]{64}",
                              p + r"\d+ table entries in 5 phases, "] + phases + tail)
    if problem:
        return fail(problem)
    if mode == "full" and interrupts == 0:
        return fail("the sink sent without an interrupt (0 sink interrupts)")
    return ok(f"{len(lines)} lines in order, {through} bytes through the ring all arrived before the log line, "
              f"{interrupts} sink interrupt(s), the verdict is last")


def ok(message):
    print(message)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
