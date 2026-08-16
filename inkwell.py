#!/usr/bin/env python3
"""
Inkwell (Terminal edition) — a forward-only writing tool.

The idea:
  - You always type inside a live bracket:  [like this]
  - Type a sentence-ender (. ? or !) followed by TWO SPACES and the brackets
    dissolve: the words freeze into the page (ink), keeping the ender and the
    two spaces, and a fresh [ ] opens on the same line so your prose flows into
    a paragraph.  An ellipsis works too (it ends in a period).
  - Press ENTER on an EMPTY bracket to start a new, indented paragraph.
    (ENTER does nothing inside a non-empty bracket.)
  - Committed (frozen) text cannot be touched.  Inside the live bracket you can
    edit freely; once committed, it's ink.

Tags (#like this#):
  - Wrap text in hashes to make a tag.  Tags are visible while you write but are
    stripped from anything that leaves the app (saved files and the clipboard).
  - Type '#', then either type a new tag name and close it with another '#',
    or press UP to open a chooser of tags you've used before (Up/Down scrolls,
    typing filters, '#' accepts, Esc cancels).
  - On save, every tag is written to its own file in the Tags folder, alongside
    the passage it references (see the scope rules in the design spec).

Keys:
  F1 ... Save (asks for a name; defaults to the Inkwell folder)
  F2 ... Open one of your Inkwell files
  F3 ... Copy the clean prose to the clipboard
  F4 ... Exit (warns once if you have unsaved work)
  F5 ... Help (and switch colour theme)

Run it with:   python3 inkwell.py
Self-test:     python3 inkwell.py --selftest
"""

import curses
import datetime
import os
import re
import subprocess
import sys
import time

# ---------------------------------------------------------------------------
# Where things live
# ---------------------------------------------------------------------------
# Your writing goes in ~/Documents/Inkwell unless you say otherwise:
#     export INKWELL_DIR="~/Dropbox/Writing"
WRITING_DIR = os.path.expanduser(os.environ.get("INKWELL_DIR", "~/Documents/Inkwell"))
TAGS_DIR = os.path.join(WRITING_DIR, "Tags")
RECOVERY_FILE = os.path.join(WRITING_DIR, ".inkwell-recovery.md")

# Inkwell refuses to save anywhere outside these roots.  By default that is
# just your writing folder; add more with INKWELL_ALLOWED_ROOTS, separated the
# way PATH is (colons on macOS/Linux):
#     export INKWELL_ALLOWED_ROOTS="~/Documents/Notes:~/Desktop"
ALLOWED_ROOTS = [WRITING_DIR] + [
    os.path.expanduser(p)
    for p in os.environ.get("INKWELL_ALLOWED_ROOTS", "").split(os.pathsep)
    if p.strip()
]

INDENT = 4              # first-line paragraph indent (spaces)
MAX_MEASURE = 72        # cap text column width; wider windows wrap here (narrow panes unaffected)
TOP_PAD = 2             # blank rows above the text, only when the measure cap is active
ENDERS = ".?!"          # sentence-enders that arm a commit
AUTOSAVE_SECONDS = 15   # how often to auto-save / write the recovery file

# style categories
ATTR_COMMITTED = 0
ATTR_BRACKET = 1
ATTR_LIVE = 2
ATTR_TAG = 3
ATTR_STATUS = 4
ATTR_PICK = 5

TAG_RE = re.compile(r"#([^#\n]*)#")


# ===========================================================================
# Pure text logic  (no curses here, so it can be unit-tested via --selftest)
# ===========================================================================

def has_words(text):
    """True if the text contains an actual letter or digit (not just spaces/punctuation)."""
    return bool(re.search(r"[A-Za-z0-9]", text))


def clean(text):
    """Strip tags, squeeze runs of spaces, drop spaces before punctuation."""
    text = TAG_RE.sub("", text)
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\s+([.,?!;:])", r"\1", text)
    return text.strip()


def split_sentences(paragraph):
    """Split a committed paragraph into sentence units.

    A unit ends at a run of sentence-enders followed by two spaces (the commit
    gesture).  Each returned unit keeps its ender and trailing spaces.
    """
    units = []
    n = len(paragraph)
    start = i = 0
    while i < n:
        if paragraph[i] in ENDERS:
            j = i
            while j < n and paragraph[j] in ENDERS:   # consume e.g. "..."
                j += 1
            if paragraph[j:j + 2] == "  ":
                units.append(paragraph[start:j + 2])
                start = i = j + 2
                continue
            i = j
        else:
            i += 1
    if start < n:
        units.append(paragraph[start:])
    return units


def paragraph_is_tag_only(units):
    """True if no sentence in the paragraph carries any actual words."""
    return len(units) > 0 and all(not has_words(clean(u)) for u in units)


def extract_tag_records(paragraphs):
    """Walk committed paragraphs and return [(tag_name, referenced_text), ...].

    Scope ladder (the author's rules):
      1. mid-sentence tag      -> the text before it in that sentence
      2. end-of-sentence tag   -> that + every earlier sentence in the paragraph
      3. tag-only sentence     -> every earlier sentence in the paragraph
      4. tag-only paragraph    -> all text in every earlier paragraph
    """
    records = []
    for p_idx, para in enumerate(paragraphs):
        units = split_sentences(para)
        tag_only_para = paragraph_is_tag_only(units)
        for s_idx, unit in enumerate(units):
            for m in TAG_RE.finditer(unit):
                name = m.group(1).strip()
                if not name:
                    continue
                before = unit[:m.start()]
                after = unit[m.end():]
                earlier = " ".join(units[:s_idx])
                if has_words(after):                      # 1: mid-sentence
                    scope = clean(before)
                elif has_words(before):                   # 2: end of sentence
                    scope = clean(earlier + " " + before)
                elif tag_only_para:                       # 4: tag-only paragraph
                    scope = clean(" ".join(paragraphs[:p_idx]))
                else:                                     # 3: tag-only sentence
                    scope = clean(earlier)
                records.append((name.lower(), scope))
    return records


def render_export(paragraphs, live=""):
    """The clean, printable document: tags stripped, tag-only bits removed."""
    out = []
    for para in paragraphs:
        kept = []
        for unit in split_sentences(para):
            c = clean(unit)
            if has_words(c):
                kept.append(c)
        if kept:
            out.append("\t" + "  ".join(kept))
    if live.strip():
        c = clean(live)
        if has_words(c):
            if out:
                out[-1] = out[-1] + "  " + c
            else:
                out.append("\t" + c)
    return "\n\n".join(out) + ("\n" if out else "")


def collect_tag_names(paragraphs, live):
    """Tag names present in the current document (lowercased)."""
    names = set()
    for chunk in list(paragraphs) + [live]:
        for m in TAG_RE.finditer(chunk):
            n = m.group(1).strip().lower()
            if n:
                names.add(n)
    return names


# ===========================================================================
# Self-test  (run: python3 inkwell.py --selftest)
# ===========================================================================

def selftest():
    ok = True

    def check(label, got, want):
        nonlocal ok
        if got != want:
            ok = False
            print(f"FAIL {label}\n  got : {got!r}\n  want: {want!r}")
        else:
            print(f"ok   {label}")

    # split_sentences keeps enders + spacing, handles ellipsis
    check("split basic",
          split_sentences("One.  Two?  "),
          ["One.  ", "Two?  "])
    check("split ellipsis",
          split_sentences("Wait...  Now.  "),
          ["Wait...  ", "Now.  "])

    # 1 mid-sentence
    recs = extract_tag_records(["The dog#dog# ran fast.  "])
    check("scope mid-sentence", recs, [("dog", "The dog")])

    # 2 end of sentence (uses earlier sentences too)
    recs = extract_tag_records(["The dog ran fast.  I saw it #dog#.  "])
    check("scope end-of-sentence", recs,
          [("dog", "The dog ran fast. I saw it")])

    # 3 tag-only sentence -> earlier sentences in this paragraph
    recs = extract_tag_records(["Hello there.  #cat#.  "])
    check("scope tag-only sentence", recs, [("cat", "Hello there.")])

    # 4 tag-only paragraph -> all earlier paragraphs
    recs = extract_tag_records(["First para.  ", "#summary#.  "])
    check("scope tag-only paragraph", recs, [("summary", "First para.")])

    # export strips tags, drops tag-only sentences, fixes spacing
    check("export inline tag",
          render_export(["The dog#dog# ran fast.  "]),
          "\tThe dog ran fast.\n")
    check("export drops tag-only sentence",
          render_export(["Hello there.  #cat#.  "]),
          "\tHello there.\n")
    check("export drops tag-only paragraph",
          render_export(["First para.  ", "#summary#.  "]),
          "\tFirst para.\n")
    check("export space before tag removed",
          render_export(["I saw it #dog#.  "]),
          "\tI saw it.\n")

    print("\nALL PASSED" if ok else "\nSOME TESTS FAILED")
    return 0 if ok else 1


# ===========================================================================
# Curses helpers
# ===========================================================================

THEMES = ["amber", "green", "paper"]


def apply_theme(name, pairs):
    """(Re)define colour pairs for the chosen theme; fill `pairs` in place."""
    if not curses.has_colors():
        pairs.update({ATTR_COMMITTED: 0, ATTR_BRACKET: curses.A_BOLD,
                      ATTR_LIVE: 0, ATTR_TAG: curses.A_UNDERLINE,
                      ATTR_STATUS: curses.A_REVERSE, ATTR_PICK: curses.A_REVERSE})
        return None

    try:
        curses.use_default_colors()
        default_bg = -1
    except curses.error:
        default_bg = curses.COLOR_BLACK

    if name == "green":
        ink, live_c, brack_c, tag_c, page_bg = (
            curses.COLOR_WHITE, curses.COLOR_GREEN, curses.COLOR_GREEN,
            curses.COLOR_MAGENTA, default_bg)
    elif name == "paper":
        ink, live_c, brack_c, tag_c, page_bg = (
            curses.COLOR_BLACK, curses.COLOR_BLUE, curses.COLOR_BLUE,
            curses.COLOR_MAGENTA, curses.COLOR_WHITE)
    else:  # default: live text matches the white committed ink; no coloured pen
        ink, live_c, brack_c, tag_c, page_bg = (
            curses.COLOR_WHITE, curses.COLOR_WHITE, curses.COLOR_WHITE,
            curses.COLOR_CYAN, default_bg)

    curses.init_pair(1, ink, page_bg)       # committed
    curses.init_pair(2, brack_c, page_bg)   # bracket
    curses.init_pair(3, live_c, page_bg)    # live
    curses.init_pair(4, tag_c, page_bg)     # tag
    curses.init_pair(5, ink, page_bg)       # status (we add A_REVERSE)
    curses.init_pair(6, page_bg, ink)       # picker highlight

    pairs[ATTR_COMMITTED] = curses.color_pair(1)
    pairs[ATTR_BRACKET] = curses.color_pair(2) | curses.A_BOLD
    pairs[ATTR_LIVE] = curses.color_pair(3)   # same weight as committed ink
    pairs[ATTR_TAG] = curses.color_pair(4) | curses.A_BOLD
    pairs[ATTR_STATUS] = curses.color_pair(5) | curses.A_REVERSE
    pairs[ATTR_PICK] = curses.color_pair(6)
    return page_bg


def styled_cells(text, base_style):
    """Turn a string into (char, style) cells, colouring #tag# spans."""
    cells = []
    i = 0
    while i < len(text):
        if text[i] == "#":
            j = text.find("#", i + 1)
            if j != -1:
                for k in range(i, j + 1):
                    cells.append((text[k], ATTR_TAG))
                i = j + 1
                continue
        cells.append((text[i], base_style))
        i += 1
    return cells


def fit_status(text, width):
    """Trim a status-bar string to `width`, breaking at a word boundary.

    Avoids ugly mid-word chops in narrow windows: cuts back to the last space
    (when that space isn't too far back) and marks the cut with an ellipsis.
    """
    if width <= 0:
        return ""
    if len(text) <= width:
        return text
    cut = text[:width - 1]
    sp = cut.rfind(" ")
    if sp >= width // 2:
        cut = cut[:sp]
    return cut.rstrip() + "…"


def wrap_cells(cells, width, indent):
    """Word-wrap (char, style) cells to `width`.  First line is indented.

    Returns (lines, positions, end_pos) where positions[i] = (row, col).
    """
    width = max(1, width)
    positions = [None] * len(cells)
    lines = []
    cur = [(" ", ATTR_COMMITTED, None) for _ in range(indent)]

    for i, (ch, style) in enumerate(cells):
        if len(cur) >= width:
            brk = None
            for k in range(len(cur) - 1, -1, -1):
                if cur[k][0] == " ":
                    brk = k
                    break
            if brk is not None and any(c[2] is not None for c in cur[:brk]):
                head, tail = cur[:brk], cur[brk + 1:]
                lines.append(head)
                cur = tail
                r = len(lines)
                for col2, c2 in enumerate(cur):
                    if c2[2] is not None:
                        positions[c2[2]] = (r, col2)
            else:
                lines.append(cur)
                cur = []
        r = len(lines)
        positions[i] = (r, len(cur))
        cur.append((ch, style, i))

    lines.append(cur)
    return lines, positions, (len(lines) - 1, len(cur))


def build_active_cells(committed, live):
    cells = styled_cells(committed, ATTR_COMMITTED)
    cells.append(("[", ATTR_BRACKET))
    cells += styled_cells(live, ATTR_LIVE)
    cells.append(("]", ATTR_BRACKET))
    return cells


def within_allowed(path):
    ap = os.path.abspath(path)
    for root in ALLOWED_ROOTS:
        if ap == root or ap.startswith(root + os.sep):
            return True
    return False


def text_prompt(stdscr, pairs, label, default=""):
    """Read a line of text on the status row.  Enter accepts, Esc cancels."""
    height, width = stdscr.getmaxyx()
    buf = list(default)
    while True:
        shown = (label + "".join(buf))[:max(0, width - 1)]
        try:
            stdscr.addstr(height - 1, 0, shown.ljust(max(0, width - 1)), pairs[ATTR_STATUS])
            stdscr.move(height - 1, min(len(label) + len(buf), width - 1))
        except curses.error:
            pass
        stdscr.refresh()
        try:
            k = stdscr.get_wch()
        except curses.error:
            continue
        if k in ("\n", "\r", curses.KEY_ENTER, 10, 13):
            return "".join(buf).strip()
        if k == "\x1b":                              # Esc
            return None
        if k in ("\x7f", "\b", curses.KEY_BACKSPACE, 127, 8, 263):
            if buf:
                buf.pop()
            continue
        if isinstance(k, str) and len(k) == 1 and k.isprintable():
            buf.append(k)


def list_menu(stdscr, pairs, title, items):
    """Show a centred selectable list.  Returns chosen item or None."""
    if not items:
        return None
    sel = 0
    while True:
        height, width = stdscr.getmaxyx()
        stdscr.erase()
        top = max(0, (height - len(items)) // 2 - 2)
        try:
            stdscr.addstr(top, 2, title[:width - 4], pairs[ATTR_BRACKET])
        except curses.error:
            pass
        for n, item in enumerate(items):
            style = pairs[ATTR_PICK] if n == sel else pairs[ATTR_COMMITTED]
            row = top + 2 + n
            if row >= height - 1:
                break
            try:
                stdscr.addstr(row, 4, ("  " + item)[:width - 6].ljust(min(40, width - 6)), style)
            except curses.error:
                pass
        hint = "Up/Down move · Enter open · Esc cancel"
        try:
            stdscr.addstr(height - 1, 0, hint.ljust(width - 1), pairs[ATTR_STATUS])
        except curses.error:
            pass
        stdscr.refresh()
        try:
            k = stdscr.get_wch()
        except curses.error:
            continue
        if k in (curses.KEY_UP, 259):
            sel = (sel - 1) % len(items)
        elif k in (curses.KEY_DOWN, 258):
            sel = (sel + 1) % len(items)
        elif k in ("\n", "\r", curses.KEY_ENTER, 10, 13):
            return items[sel]
        elif k == "\x1b":
            return None


def help_screen(stdscr, pairs, theme):
    """Show the key list and let the user switch theme.  Returns new theme."""
    lines = [
        "INKWELL — forward-only writing",
        "",
        "Type inside the [ bracket ].  Edit freely there.",
        "End a sentence with . ? or ! then TWO SPACES to commit it to ink.",
        "ENTER on an empty bracket starts a new paragraph.",
        "",
        "Tags:  type #name# .  Type '#', then UP to pick an existing tag",
        "       (Up/Down scroll, type to filter, '#' accepts, Esc cancels).",
        "       Tags show on screen but never print or copy.",
        "",
        "Hold fn:  F1 Save   F2 Open   F3 Copy   F4 Exit   F5 closes help",
        "",
        "Theme:  press  a = amber   b = green   c = paper",
    ]
    while True:
        height, width = stdscr.getmaxyx()
        stdscr.erase()
        top = max(0, (height - len(lines)) // 2)
        for n, ln in enumerate(lines):
            row = top + n
            if row >= height - 1:
                break
            style = pairs[ATTR_BRACKET] if n == 0 else pairs[ATTR_COMMITTED]
            try:
                stdscr.addstr(row, max(2, (width - len(ln)) // 2), ln[:width - 2], style)
            except curses.error:
                pass
        foot = f"current theme: {theme}   ·   Esc / F5 to return"
        try:
            stdscr.addstr(height - 1, 0, foot.ljust(width - 1), pairs[ATTR_STATUS])
        except curses.error:
            pass
        stdscr.refresh()
        try:
            k = stdscr.get_wch()
        except curses.error:
            continue
        if k in ("\x1b", curses.KEY_F0 + 5, 269):
            return theme
        if k == "a":
            theme = "amber"; apply_theme(theme, pairs); _set_bg(stdscr, theme, pairs)
        elif k == "b":
            theme = "green"; apply_theme(theme, pairs); _set_bg(stdscr, theme, pairs)
        elif k == "c":
            theme = "paper"; apply_theme(theme, pairs); _set_bg(stdscr, theme, pairs)


def confirm(stdscr, pairs, question):
    """Centred yes/no prompt. Returns True for y, False for n / Esc."""
    while True:
        height, width = stdscr.getmaxyx()
        stdscr.erase()
        msg = question + "    (y / n)"
        try:
            stdscr.addstr(height // 2, max(2, (width - len(msg)) // 2),
                          msg[:width - 2], pairs[ATTR_BRACKET])
        except curses.error:
            pass
        stdscr.refresh()
        try:
            k = stdscr.get_wch()
        except curses.error:
            continue
        if k in ("y", "Y"):
            return True
        if k in ("n", "N", "\x1b"):
            return False


def _set_bg(stdscr, theme, pairs):
    """Paper gets a painted white page; other themes use the terminal's own background."""
    if theme == "paper" and curses.has_colors():
        stdscr.bkgd(" ", pairs[ATTR_COMMITTED])
    else:
        stdscr.bkgd(" ", 0)


# ===========================================================================
# Main interactive program
# ===========================================================================

def main(stdscr):
    curses.curs_set(1)
    stdscr.keypad(True)
    stdscr.timeout(1000)            # wake up ~once a second for auto-save
    if curses.has_colors():
        curses.start_color()

    pairs = {}
    theme = "amber"
    apply_theme(theme, pairs)
    _set_bg(stdscr, theme, pairs)

    # document state
    paragraphs = [""]               # committed prose, one string per paragraph
    live = ""                       # the editable pen
    caret = 0                       # cursor index within `live`
    dirty = False
    quit_armed = False
    filepath = None
    started = time.monotonic()
    last_autosave = started
    message = "fn+F1 Save  fn+F2 Open  fn+F3 Copy  fn+F4 Exit  fn+F5 Help"

    # tag-chooser state
    picker_open = False
    picker_sel = 0

    def all_tag_names():
        names = set(collect_tag_names(paragraphs, live))
        if os.path.isdir(TAGS_DIR):
            for fn in os.listdir(TAGS_DIR):
                if fn.endswith(".md"):
                    names.add(fn[:-3].lower())
        return sorted(names)

    def picker_matches():
        # the partial query is whatever sits between the open '#' and the caret
        open_pos = live.rfind("#", 0, caret)
        query = live[open_pos + 1:caret].lower() if open_pos != -1 else ""
        return [n for n in all_tag_names() if query in n], open_pos

    def write_tag_files(source_name):
        recs = extract_tag_records(paragraphs)
        if not recs:
            return
        os.makedirs(TAGS_DIR, exist_ok=True)
        stamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
        by_name = {}
        for name, scope in recs:
            by_name.setdefault(name, []).append(scope)
        for name, scopes in by_name.items():
            path = os.path.join(TAGS_DIR, name + ".md")
            existing = ""
            if os.path.exists(path):
                with open(path, encoding="utf-8") as f:
                    existing = f.read()
            # drop any previous entries from this same source file (idempotent re-save)
            pat = re.compile(
                r"<!-- src:" + re.escape(source_name) + r" -->\n(?:.*\n)*?\n", re.M)
            existing = pat.sub("", existing)
            blocks = ["# " + name + "\n\n"] if not existing.strip() else [existing.rstrip() + "\n\n"]
            for scope in scopes:
                blocks.append("<!-- src:" + source_name + " -->\n**" + source_name +
                              "** · " + stamp + "\n\n" + scope + "\n\n")
            with open(path, "w", encoding="utf-8") as f:
                f.write("".join(blocks))

    def do_save(ask=True):
        nonlocal filepath, dirty, message
        os.makedirs(WRITING_DIR, exist_ok=True)
        default = os.path.basename(filepath) if filepath else \
            "inkwell-" + datetime.datetime.now().strftime("%Y%m%d-%H%M") + ".md"
        if ask:
            name = text_prompt(stdscr, pairs, "Save as: ", default)
            if name is None:
                message = "save cancelled"
                return
            if not name:
                name = default
        else:
            name = default
        if not name.lower().endswith((".md", ".txt")):
            name += ".md"
        target = name if os.path.isabs(name) else os.path.join(WRITING_DIR, name)
        if not within_allowed(target):
            message = "can't save there — outside your writing folders"
            return
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "w", encoding="utf-8") as f:
            f.write(render_export(paragraphs, live))
        filepath = target
        write_tag_files(os.path.basename(target))
        dirty = False
        message = "saved  ->  " + os.path.basename(target)
        if os.path.exists(RECOVERY_FILE):           # named now — retire the recovery file
            try:
                os.remove(RECOVERY_FILE)
            except OSError:
                pass

    def autosave():
        nonlocal last_autosave, dirty, message
        last_autosave = time.monotonic()
        if not dirty:
            return
        stamp = datetime.datetime.now().strftime("%H:%M")
        try:
            os.makedirs(WRITING_DIR, exist_ok=True)
            if filepath:
                with open(filepath, "w", encoding="utf-8") as f:
                    f.write(render_export(paragraphs, live))
                write_tag_files(os.path.basename(filepath))
                dirty = False
                message = "auto-saved " + stamp + "  ->  " + os.path.basename(filepath)
            else:
                with open(RECOVERY_FILE, "w", encoding="utf-8") as f:
                    f.write(render_export(paragraphs, live))
                message = "draft backed up " + stamp + "  (unsaved — fn+F1 to name it)"
        except OSError:
            pass

    def do_open():
        nonlocal paragraphs, live, caret, dirty, filepath, message
        if not os.path.isdir(WRITING_DIR):
            message = "no Inkwell folder yet"
            return
        files = sorted(fn for fn in os.listdir(WRITING_DIR)
                       if fn.lower().endswith((".md", ".txt")) and not fn.startswith("."))
        if not files:
            message = "no files in the Inkwell folder yet"
            return
        choice = list_menu(stdscr, pairs, "Open which file?", files)
        if not choice:
            message = "open cancelled"
            return
        path = os.path.join(WRITING_DIR, choice)
        with open(path, encoding="utf-8") as f:
            raw = f.read()
        loaded = []
        for block in raw.split("\n\n"):
            block = block.strip("\n").lstrip("\t").strip()
            if block:
                loaded.append(block + "  ")        # frozen ink, ready to append after
        paragraphs = loaded or [""]
        live, caret, dirty = "", 0, False
        filepath = path
        message = "opened  ->  " + choice + "  (frozen — write on from here)"

    # offer to restore unsaved work left behind by a previous crash
    if os.path.exists(RECOVERY_FILE):
        try:
            with open(RECOVERY_FILE, encoding="utf-8") as f:
                raw = f.read()
        except OSError:
            raw = ""
        if raw.strip():
            if confirm(stdscr, pairs, "Recover unsaved draft from a previous session?"):
                loaded = []
                for block in raw.split("\n\n"):
                    block = block.strip("\n").lstrip("\t").strip()
                    if block:
                        loaded.append(block + "  ")
                paragraphs = loaded or [""]
                live, caret, dirty = "", 0, True
                message = "recovered your unsaved draft — fn+F1 to name and save it"
            else:
                try:
                    os.remove(RECOVERY_FILE)
                except OSError:
                    pass

    while True:
        height, width = stdscr.getmaxyx()
        # cap the text column on wide windows; narrow panes use their full width
        text_width = min(width, MAX_MEASURE)
        top_pad = TOP_PAD if width > MAX_MEASURE else 0
        avail = max(1, height - 1 - top_pad)
        stdscr.erase()

        # lay out the document
        all_lines = []
        cursor_abs = (0, INDENT)
        for idx, p in enumerate(paragraphs):
            if idx < len(paragraphs) - 1:
                blines, _, _ = wrap_cells(styled_cells(p, ATTR_COMMITTED), text_width, INDENT)
                all_lines.extend(blines)
                all_lines.append([])
            else:
                cells = build_active_cells(p, live)
                target = len(p) + 1 + caret
                blines, positions, _ = wrap_cells(cells, text_width, INDENT)
                start_row = len(all_lines)
                all_lines.extend(blines)
                cr, cc = positions[target]
                cursor_abs = (start_row + cr, cc)

        top = max(0, len(all_lines) - avail)
        for screen_row, line in enumerate(all_lines[top:top + avail]):
            for col, (ch, style, _src) in enumerate(line):
                if col >= text_width:
                    break
                try:
                    stdscr.addstr(screen_row + top_pad, col, ch, pairs[style])
                except curses.error:
                    pass

        # tag chooser
        matches, open_pos = ([], -1)
        if picker_open:
            matches, open_pos = picker_matches()
            if not matches:
                picker_open = False
            else:
                picker_sel %= len(matches)
                box_h = min(6, len(matches))
                base = max(0, avail - box_h - 1)
                for n in range(box_h):
                    item = matches[n]
                    style = pairs[ATTR_PICK] if n == picker_sel else pairs[ATTR_TAG]
                    label = (" #" + item + " ")[:max(1, min(30, width - 2))]
                    try:
                        stdscr.addstr(base + n, 1, label.ljust(min(30, width - 2)), style)
                    except curses.error:
                        pass

        # status bar
        words = len(clean(" ".join(paragraphs) + " " + live).split())
        elapsed = int(time.monotonic() - started)
        clock = f"{elapsed // 60:02d}:{elapsed % 60:02d}"
        left = f" {words} words · {clock} "
        if dirty:
            left += "· unsaved "
        bar = fit_status(left + "  " + message, max(0, width - 1))
        try:
            stdscr.addstr(height - 1, 0, bar.ljust(max(0, width - 1)), pairs[ATTR_STATUS])
        except curses.error:
            pass

        cy = cursor_abs[0] - top
        cx = min(cursor_abs[1], text_width - 1)
        if 0 <= cy < avail:
            try:
                stdscr.move(cy + top_pad, cx)
            except curses.error:
                pass
        stdscr.refresh()

        # ---- input (with 1s timeout for auto-save) ----
        try:
            key = stdscr.get_wch()
        except curses.error:
            if time.monotonic() - last_autosave >= AUTOSAVE_SECONDS:
                autosave()
            continue

        if time.monotonic() - last_autosave >= AUTOSAVE_SECONDS:
            autosave()

        is_enter = key in ("\n", "\r", curses.KEY_ENTER, 10, 13)
        is_back = key in ("\x7f", "\b", curses.KEY_BACKSPACE, 127, 8, 263)

        # function keys
        if key in (curses.KEY_F0 + 1, 265):                 # F1 save
            do_save(); quit_armed = False; continue
        if key in (curses.KEY_F0 + 2, 266):                 # F2 open
            do_open(); quit_armed = False; continue
        if key in (curses.KEY_F0 + 3, 267):                 # F3 copy
            try:
                subprocess.run(["pbcopy"], input=render_export(paragraphs, live).encode(),
                               check=True)
                message = "copied to clipboard (tags stripped)"
            except Exception:
                message = "copy failed"
            quit_armed = False
            continue
        if key in (curses.KEY_F0 + 4, 268):                 # F4 exit
            if dirty and not quit_armed:
                quit_armed = True
                message = "unsaved changes — F1 to save, or F4 again to quit"
                continue
            break
        if key in (curses.KEY_F0 + 5, 269):                 # F5 help
            theme = help_screen(stdscr, pairs, theme)
            quit_armed = False
            continue

        quit_armed = False

        # ---- tag chooser navigation ----
        inside_tag = live[:caret].count("#") % 2 == 1
        if key in (curses.KEY_UP, 259):
            if inside_tag:
                if not picker_open:
                    picker_open, picker_sel = True, 0
                else:
                    picker_sel -= 1
            continue
        if key in (curses.KEY_DOWN, 258):
            if picker_open:
                picker_sel += 1
            continue
        if key == "\x1b":                                   # Esc closes chooser
            picker_open = False
            continue

        if is_enter:
            if picker_open:
                picker_open = False
                continue
            if live.strip():
                continue                                    # ENTER does nothing mid-bracket
            # empty bracket -> new paragraph
            if paragraphs[-1].strip():
                paragraphs[-1] = paragraphs[-1].rstrip() + "  "
                paragraphs.append("")
                live, caret, dirty = "", 0, True
            continue

        if is_back:
            if caret > 0:
                live = live[:caret - 1] + live[caret:]
                caret -= 1
                dirty = True
                if live[:caret].count("#") % 2 == 0:
                    picker_open = False
            continue

        if key in (curses.KEY_LEFT, 260):
            caret = max(0, caret - 1); picker_open = False; continue
        if key in (curses.KEY_RIGHT, 261):
            caret = min(len(live), caret + 1); picker_open = False; continue
        if key in (curses.KEY_HOME, 262):
            caret = 0; picker_open = False; continue
        if key in (curses.KEY_END, 360):
            caret = len(live); picker_open = False; continue
        if key in (curses.KEY_DC, 330):
            if caret < len(live):
                live = live[:caret] + live[caret + 1:]
                dirty = True
            continue
        if key == curses.KEY_RESIZE:
            continue

        # ---- printable character ----
        if isinstance(key, str) and len(key) == 1 and (key == " " or key.isprintable()):
            # accept a chosen tag with a closing '#'
            if key == "#" and picker_open and matches:
                open_pos = live.rfind("#", 0, caret)
                chosen = matches[picker_sel % len(matches)]
                live = live[:open_pos + 1] + chosen + "#" + live[caret:]
                caret = open_pos + 1 + len(chosen) + 1
                picker_open = False
                dirty = True
                continue

            armed_tag = inside_tag
            live = live[:caret] + key + live[caret:]
            caret += 1
            dirty = True

            # commit gesture: ender + two trailing spaces, at the end, not inside a tag
            if (key == " " and not armed_tag and caret == len(live)
                    and len(live) >= 3 and live[-1] == " " and live[-2] == " "
                    and live[-3] in ENDERS):
                if paragraphs[-1] and not paragraphs[-1].endswith(" "):
                    paragraphs[-1] += "  "
                paragraphs[-1] += live
                live, caret = "", 0
                picker_open = False

    # clean exit: drop the recovery file if a real save exists
    if filepath and os.path.exists(RECOVERY_FILE):
        try:
            os.remove(RECOVERY_FILE)
        except OSError:
            pass


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    curses.wrapper(main)
