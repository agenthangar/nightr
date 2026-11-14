"""Inline terminal components extracted from AgentHangar t (MIT).
See docs/provenance.md for upstream paths and revision.
"""
import os
import re
import shutil
import sys
import unicodedata

def display_width(text):
    return sum(0 if unicodedata.category(char) in ('Mn', 'Me', 'Cf') else
               2 if unicodedata.east_asian_width(char) in ('W', 'F') else 1
               for char in text)


def clip_columns(text, width):
    if width <= 0:
        return ''
    if display_width(text) <= width:
        return text
    out, used = '', 0
    for char in text:
        size = display_width(char)
        if used + size > width - 1:
            break
        out += char
        used += size
    return out + '…'


def wrap_columns(text, width, continuation=''):
    lines, line, used = [], '', 0
    for char in text:
        size = display_width(char)
        if used + size > width and line:
            lines.append(line.rstrip())
            line, used = continuation, display_width(continuation)
        line += char
        used += size
    if line:
        lines.append(line.rstrip())
    return lines


def key_labels(text, platform=None, compact=False):
    mac = (platform or sys.platform) == 'darwin'
    text = re.sub(r'Ctrl-([A-Za-z/])', lambda m: ('⌃' if mac else '^' if compact else 'Ctrl-') + m[1].upper(), text, flags=re.IGNORECASE)
    text = re.sub(r'Alt-([A-Za-z])', lambda m: ('⌥' if mac else 'M-' if compact else 'Alt-') + m[1].upper(), text, flags=re.IGNORECASE)
    if mac:
        for pattern, label in ((r'\b[Ee]nter\b', '↩' if compact else '↩ Return'),
                               (r'\b[Ee]sc\b', '⎋' if compact else '⎋ Esc'),
                               (r'\b[Tt]ab\b', '⇥' if compact else '⇥ Tab')):
            text = re.sub(pattern, label, text)
    return text


class Style:
    def __init__(self, tty=None):
        """tty=False forces plain text — for a label a picker measures and truncates
        by len(), where an escape sequence would count as width."""
        tty = sys.stdout.isatty() if tty is None else tty
        tty = tty and "NO_COLOR" not in os.environ and os.environ.get("TERM") != "dumb"
        self.g = "\033[32m" if tty else ""
        self.c = "\033[36m" if tty else ""
        self.y = "\033[2m" if tty else ""
        self.b = "\033[1m" if tty else ""
        self.w = "\033[33m" if tty else ""
        self.focus = "\033[48;5;23m\033[97m" if tty else ""
        self.rev = "\033[7m" if tty else ""
        self.r = "\033[0m" if tty else ""


_ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")

def _vis_len(s):
    """Columns a styled line takes on screen: its length with the SGR escapes out."""
    return display_width(_ANSI_RE.sub("", s))


def _term_rows(line, cols):
    """Screen rows a printed line occupies — a line wider than the terminal WRAPS,
    and the in-place repaint moves the cursor up by rows, not by lines. Counting
    lines was exactly right on a wide terminal and off by one per wrapped line on
    a phone (Termius: ~44 columns), where every keypress left a stale row behind
    and the block crept down the screen."""
    return max(1, -(-_vis_len(line) // max(1, cols)))


def _page_window(heights, top, avail):
    """Which lines of a block fit on screen: heights = rows per line, top = the first
    line wanted, avail = rows the block may take INCLUDING its markers. → (lo, hi):
    show lines[lo:hi], with an "… N above" row when lo > 0 and an "… N below" row
    when hi < len. top is clamped so the block never scrolls past its own end, and
    at least one line is always shown even when it alone overflows."""
    n = len(heights)
    if n == 0 or sum(heights) <= avail:
        return 0, n

    def extent(lo):
        room = avail - (1 if lo else 0)
        used, hi = 0, lo
        while hi < n:
            need = heights[hi] + (0 if hi + 1 == n else 1)
            if used + need > room and hi > lo:
                break
            used += heights[hi]
            hi += 1
            if used > room:
                break
        return hi

    last_top = next((lo for lo in range(n) if extent(lo) == n), n - 1)
    lo = max(0, min(top, last_top))
    return lo, extent(lo)


class _RailUI:
    """The shared design for `t config`, `t setup`, `t install`, and `t new`: raw single-key
    reads, an input line with a readline-PREFILLED suggestion, and in-place repaint of
    a block of rail lines via ANSI cursor-up — a step redraws itself while the finished
    steps above it stay in normal scrollback (the clack / `npm create` aesthetic).
    Constructing it off a tty (no line discipline to save) raises, which is the signal
    the callers use to fall back to plain prompts. stdlib only — deliberately neither
    fzf nor curses: fzf is not on every host, and both take over the screen while
    the wizard's transcript stays in normal scrollback."""

    def __init__(self):
        import termios
        self.st, self.out = Style(), sys.stdout
        self.fd = sys.stdin.fileno()
        self.old_attrs = termios.tcgetattr(self.fd)
        self.rail = "  "
        self.painted = [0]   # screen ROWS of the block currently on screen (0 = nothing to erase)

    def cols(self):
        # re-read per paint: a phone rotates, a window resizes, mid-wizard
        return max(20, shutil.get_terminal_size((100, 24)).columns)

    def lines(self):
        return max(8, shutil.get_terminal_size((100, 24)).lines)

    def intro(self, title, note):
        st = self.st
        self.out.write(f"\n  {st.b}{st.c}{self.clip(title, self.cols() - 4)}{st.r}\n")
        for line in wrap_columns(note, max(4, self.cols() - 4)):
            self.out.write(f"  {st.y}{line}{st.r}\n")
        self.out.write("\n")

    def clip(self, text, width):
        return clip_columns(str(text), max(1, width))

    def labels(self, text):
        return key_labels(text, compact=self.lines() <= 14 or self.cols() <= 40)


    def head(self, label, hint="", marker=None):
        st = self.st
        mark = marker or ""
        lines = [f"  {mark}{st.b}{st.c}{self.clip(label, self.cols() - 4)}{st.r}"]
        if hint:
            lines.extend(f"  {st.y}{line}{st.r}" for line in wrap_columns(hint, self.cols() - 4))
        return lines

    def chrome(self, label, keys, primary=None, flash=""):
        """Shared title, spacing, key hints and prominent action for every wizard."""
        st, width = self.st, self.cols()
        head = self.head(label) + [self.rail]
        hints, current = [], ""
        for part in self.labels(keys).split(" · "):
            candidate = f"{current} · {part}" if current else part
            if display_width(candidate) > width - 4 and current:
                hints.extend(wrap_columns(current, width - 4))
                current = part
            else:
                current = candidate
        if current:
            hints.extend(wrap_columns(current, width - 4))
        footer = [self.rail] + [f"  {st.y}{hint}{st.r}" for hint in hints]
        if self.lines() <= 14:
            head = head[:1]
            footer = [f"  {st.y}{hint}{st.r}" for hint in hints]
        if self.lines() <= 10:
            brief = self.labels("↑↓/jk · space ✓ · enter · q/esc · Ctrl-C")
            footer = [f"  {st.y}{line}{st.r}" for line in wrap_columns(brief, width - 4)]
        if primary:
            key, action, detail = primary
            text = self.clip(self.labels(f"{key}  {action}"), width - 4)
            if self.lines() <= 14:
                footer += [f"  {st.g}{st.b}{text}{st.r}"]
            else:
                footer += [f"  {st.g}{st.b}{text}{st.r}" +
                           (f"  {st.g}{detail}{st.r}" if detail and display_width(text + detail) + 8 <= width else "")]
        if flash:
            footer.append(f"      {st.w}{self.clip(flash, width - 6)}{st.r}")
        return head, footer

    def section(self, label):
        st = self.st
        title, separator, detail = label.partition(" · ")
        text = title.upper() + separator + detail
        return f"{self.rail}   {st.b}{st.c}{self.clip(text, self.cols() - 6)}{st.r}"

    def row(self, label, value=None, *, selected=False, mark=None, label_width=0, accent=""):
        """Style only after clipping plain text: ANSI codes never count as columns."""
        st, width = self.st, self.cols()
        pre = f"{st.c}▸{st.r}" if selected else " "
        mark = "✓" if mark in ("◼", "✓") else " " if mark in ("◻", "☐") else mark
        box = f"{st.g if mark == '✓' else st.c}{mark}{st.r} " if mark else ""
        avail = max(4, width - 8 - (2 if mark else 0))
        color = getattr(st, accent, "")
        def styled(text, base):
            inherited = re.search(r"\bInherit (?:global|default) · ", text)
            if inherited:
                end = inherited.end()
                return f"{base}{text[:end]}{st.r}{st.focus if selected else ''}{st.y}{text[end:]}{st.r}"
            return f"{base}{text}{st.r}"
        value = str(value) if value is not None else None
        stacked = value is not None and width < 60
        if value is not None and not stacked:
            left_width = min(label_width or display_width(label), max(1, avail - 3 - max(12, avail // 3)))
            left = self.clip(label, left_width)
            left += " " * max(0, left_width - display_width(left))
            right = self.clip(value, max(1, avail - left_width - 3))
            plain = f"{left}   {right}"
            body = styled(left, color) + "   " + styled(right, st.c)
        else:
            plain = self.clip(label, avail)
            body = styled(plain, color)
        if selected:
            body = styled(plain + ' ' * max(0, avail - display_width(plain)), st.focus)
        lines = [f"{self.rail}  {pre} {box}{body}"]
        if stacked:
            detail = self.clip(value, width - 10)
            style = st.focus if selected else st.c
            lines.append(f"{self.rail}      " + styled(detail, style))
        return lines

    def frame(self, label, display, current, keys, primary=None, flash=""):
        """Window a [(styled line, item key)] body; headings have no item key.
        Used by simple pickers and editable setup/install lists alike."""
        st = self.st
        head, footer = self.chrome(label, keys, primary, flash)
        heights = [_term_rows(line, self.cols()) for line, _ in display]
        budget = max(2, self.lines() - sum(_term_rows(x, self.cols()) for x in head + footer) - 1)
        focused = [i for i, (_, key) in enumerate(display) if key == current and key is not None] or [0]
        lo = max(0, focused[0] - budget // 2)
        lo, hi = _page_window(heights, lo, budget)
        while focused[-1] >= hi and lo < focused[0]:
            lo += 1
            lo, hi = _page_window(heights, lo, budget)
        lines = list(head)
        if lo:
            lines.append(f"{self.rail}   {st.y}↑ more above{st.r}")
        lines += [line for line, _ in display[lo:hi]]
        if hi < len(display):
            lines.append(f"{self.rail}   {st.y}↓ more below{st.r}")
        self.repaint(lines + footer)

    def raw(self):
        import tty
        tty.setcbreak(self.fd)
        self.out.write("\x1b[?25l")
        self.out.flush()

    def restore(self):
        import termios
        termios.tcsetattr(self.fd, termios.TCSADRAIN, self.old_attrs)
        self.out.write("\x1b[?25h")
        self.out.flush()

    def read_key(self):
        import select
        try:
            ch = os.read(self.fd, 1).decode(errors="replace")
        except KeyboardInterrupt:
            return "abort"
        if ch == "\x1b":
            r, _, _ = select.select([self.fd], [], [], 0.05)
            if r:
                seq = os.read(self.fd, 2).decode(errors="replace")
                return {"[A": "up", "OA": "up", "[B": "down", "OB": "down"}.get(seq, "esc")
            return "esc"
        return {"\r": "enter", "\n": "enter", " ": "space", "\x03": "abort",
                "\x04": "abort", "": "abort"}.get(ch, ch)

    def cooked_input(self, prompt, default="", prefill=None):
        # Temporarily restore the line discipline so input() gives real editing.
        # `prefill` puts the suggestion IN the input line, editable in place —
        # the clearest "you can change this" signal there is (readline startup
        # hook; on the rare build without readline it degrades to a [suggestion]
        # prompt). Prompts here stay ANSI-free: once readline is loaded it does
        # the cursor math for every input(), and escape codes break it.
        import termios
        import tty
        prompt = "      " + prompt.removeprefix("│").lstrip()
        termios.tcsetattr(self.fd, termios.TCSADRAIN, self.old_attrs)
        self.out.write("\x1b[?25h")
        self.out.flush()
        hooked = False
        if prefill:
            try:
                import readline
                readline.set_startup_hook(lambda: readline.insert_text(prefill))
                hooked = True
            except ImportError:
                prompt = f"{prompt}[{prefill}] "
        try:
            s = input(prompt).strip()
        except KeyboardInterrupt:
            if getattr(self, "_config_interrupts", False):
                raise
            s = ""
        except EOFError:
            s = ""
        finally:
            if hooked:
                import readline
                readline.set_startup_hook()
            tty.setcbreak(self.fd)
            self.out.write("\x1b[?25l")
            self.out.flush()
        # reclaim the input line for the repaint — every row it wrapped onto
        self.out.write(f"\x1b[{_term_rows(prompt + s, self.cols())}A\r\x1b[J")
        return s or default

    def repaint(self, lines):
        """Erase the block painted last time and draw this one in its place. The
        erase is cursor-up by the ROWS the old block occupied (_term_rows — a line
        wider than the terminal wraps), never by its line count."""
        if self.painted[0]:
            self.out.write(f"\x1b[{self.painted[0]}A\r\x1b[J")
        self.out.write("\n".join(lines) + "\n")
        cols = self.cols()
        self.painted[0] = sum(_term_rows(ln, cols) for ln in lines)
        self.out.flush()

    def commit(self, lines):
        """Repaint, then forget the block: the next repaint starts BELOW it, so these
        lines are now permanent scrollback (a finished step's ◇ summary)."""
        self.repaint(lines)
        self.painted[0] = 0

    def done(self, label, value):
        st = self.st
        color = st.w if label in ("invalid", "unavailable", "pending") else st.g
        self.commit([f"  {color}◇  {label}{st.r}", f"      {value}", ""])

    def pick(self, label, rows, multi=False, default=0, marked=None,
             values=None, sections=None, accents=None, primary=None, shortcuts=None,
             on_back=None, back_label=None, empty_choice=None, disabled=None, exclusive_choices=(), context=()):
        """Single/multiple selection on the shared row/frame template.
        Sections and unset-choice spacing are not selectable. An optional
        empty_choice makes that checklist row an exclusive reset selection.
        Optional shortcuts return an action key."""
        values, sections, accents = values or {}, sections or {}, accents or {}
        disabled = disabled or {}
        cur = max(0, min(default or 0, len(rows) - 1))
        marks = set(marked or ())
        empty_index = next((i for i, (key, _) in enumerate(rows) if key == empty_choice), None) if multi and empty_choice is not None else None
        exclusive = {i for i, (key, _) in enumerate(rows) if key in exclusive_choices}
        if empty_index is not None:
            exclusive.add(empty_index)
            marks.discard(empty_index)
            if not marks:
                marks.add(empty_index)
        keys = "↑↓/jk move" + (" · space mark" if multi else "") + " · enter select"
        keys += (f" · q/esc {back_label} · ctrl-c cancel" if back_label else " · q back")
        flash = ""
        while True:
            display = [(f"{self.rail}   {part}", None) for text in context
                       for part in wrap_columns(text, max(1, self.cols() - 6))]
            label_width = max((display_width(text) for key, text in rows if key in values), default=0)
            for n, (key, text) in enumerate(rows):
                if n == 1 and rows[0][0] == '' and key not in sections:
                    display.append((self.rail, None))
                if key in sections:
                    if display:
                        display.append((self.rail, None))
                    display.append((self.section(sections[key]), None))
                mark = ("◼" if n in marks else "◻") if multi else None
                display += [(line, n) for line in self.row(text, values.get(key), selected=n == cur,
                            mark=mark, label_width=label_width, accent="y" if key in disabled else accents.get(key, ""))]
            self.frame(label, display, cur, keys, primary, flash)
            flash = ""
            k = self.read_key()
            if k in (shortcuts or {}):
                return shortcuts[k]
            if k in ("up", "k"):
                cur = (cur - 1) % len(rows)
            elif k in ("down", "j"):
                cur = (cur + 1) % len(rows)
            elif k in ("space", "enter") and rows[cur][0] in disabled:
                flash = disabled[rows[cur][0]]
            elif k == "space" and multi:
                if cur in exclusive:
                    marks = {cur}
                else:
                    marks.symmetric_difference_update({cur})
                    marks.difference_update(exclusive)
                    if empty_index is not None and not marks:
                        marks.add(empty_index)
                cur = min(cur + 1, len(rows) - 1)
            elif k == "enter":
                return [rows[i][0] for i in sorted(marks)] if multi else rows[cur][0]
            elif k == "abort":
                raise KeyboardInterrupt
            elif k in ("q", "esc"):
                if on_back is not None:
                    on_back([rows[i][0] for i in sorted(marks)] if multi else rows[cur][0])
                return None
            else:
                flash = "No binding for that key"

    def page(self, label, body, accept, keys="", primary=None):
        """A read-only block under a ◆ step (the review screens), windowed to the
        terminal and scrolled in place with ↑↓/jk (space = a screenful) when taller
        than it; a key in `accept` returns it. Rows are counted through _term_rows,
        so a review whose command lines wrap on a phone keeps its head — and the
        y/n/q hint — on screen instead of pushing them off the top with no way back."""
        st, rail = self.st, self.rail
        scroll_hint = f"↑↓/jk scroll · {keys}" if keys else "↑↓/jk scroll"
        top, flash = 0, ""
        while True:
            cols, lines = self.cols(), self.lines()
            heights = [_term_rows(ln, cols) for ln in body]

            def window(hint):
                head, footer = self.chrome(label, hint, primary)
                avail = max(2, lines - 1 - sum(_term_rows(h, cols) for h in head + footer))
                return head, footer, _page_window(heights, top, avail)

            head, footer, (lo, hi) = window(flash or keys)
            scrolls = (lo, hi) != (0, len(body))
            if scrolls and not flash:
                head, footer, (lo, hi) = window(scroll_hint)
            flash, top = "", lo
            out = list(head)
            if lo:
                out.append(f"{rail}   {st.y}… {lo} above{st.r}")
            out.extend(body[lo:hi])
            if hi < len(body):
                out.append(f"{rail}   {st.y}… {len(body) - hi} below{st.r}")
            self.repaint(out + footer)
            k = self.read_key()
            if k in accept:
                return k
            if k in ("up", "k"):
                top = max(0, top - 1)
            elif k in ("down", "j"):
                top += 1
            elif k == "space":
                top += max(1, hi - lo - 1)
            else:
                flash = f"⚠ no binding for that key — {scroll_hint if scrolls else keys}"
