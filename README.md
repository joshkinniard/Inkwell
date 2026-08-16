# Inkwell

**A forward-only writing tool. Words go down like paint on canvas — once they're committed, they're ink.**

Inkwell separates drafting from editing, so the act of writing isn't strangled by the urge to correct. You type inside a small live bracket where you can edit freely. When you finish a sentence, you *commit* it on purpose, and it freezes into the page. The cursor can't reach back.

```
    The morning came in grey and stayed that way.  Nobody minded much.  [she was still asleep when]
    └─────────────────── ink: frozen, permanent ──────────────────────┘  └──── the live bracket ────┘
```

This is deliberately **not** the blunt "we disabled your backspace" approach, which traps you with a typo forever. You get full freedom inside the bracket. Irreversibility only happens at a line you cross on purpose.

**And when you don't want that, don't use it.** The Mac app gives every document one of two modes, chosen when you create it and fixed for that document:

- **Ink** — forward-only, as described above.
- **Free-write** — plain typing, no brackets, edit anywhere.

Both modes save to the same folder in the same format and share the same tag system, so a draft written under one is just a file to the other. The two exist because the discipline is the point of Ink mode, and a discipline you can switch off mid-sentence isn't one.

---

## The one gesture you need to learn

**Type a sentence-ender — `.` `?` or `!` — then press the spacebar twice.**

That's the commit. The brackets dissolve, the sentence freezes into the page keeping its two trailing spaces (that's typewriter sentence spacing), and a fresh bracket opens on the same line so your prose runs on into a paragraph.

A *single* space after a period does nothing, so "Mr. Smith" and "U.S. Navy" type normally. The double space is reserved as the deliberate stroke.

**Press Enter on an empty bracket to start a new paragraph.** Enter is not the commit key — that's its only job. Inside a bracket with text in it, Enter does nothing.

---

## Tags: `#like this#`

Wrap anything in hashes to make a tag. Tags are visible while you write, never commit, and are **stripped from everything that leaves the app** — saved files and the clipboard both come out clean.

They do two jobs at once: a marker to yourself in the draft, and a filing instruction. On every save, each tag gets its own file in `Tags/`, holding the passage it refers to. How much text a tag captures depends on where you put it:

| Where the tag sits | What it files |
|---|---|
| Mid-sentence | the text before it in that sentence |
| End of a sentence | that sentence, plus earlier sentences in the paragraph |
| Alone as a sentence | every earlier sentence in the paragraph |
| Alone as a paragraph | everything in every earlier paragraph |

Re-saving the same document replaces its old entries rather than piling up duplicates. Press **Up** while inside a tag to pick from tags you've used before.

---

## Two versions

### Terminal (Python) — start here

Ink mode only — the pure forward-only tool, and the reference implementation of how committing and tags behave. No installation, no dependencies: Python 3 and its standard library, nothing else.

```bash
git clone https://github.com/YOURNAME/inkwell.git
cd inkwell
python3 inkwell.py
```

Check the text logic is behaving:

```bash
python3 inkwell.py --selftest
```

**Keys** (on a Mac laptop these are `fn` + the function key):

| Key | Does |
|---|---|
| `F1` | Save — asks for a name, defaults to your writing folder |
| `F2` | Open one of your files; it loads as frozen ink to write on from the end |
| `F3` | Copy clean prose to the clipboard, tags stripped |
| `F4` | Quit — warns once if there's unsaved work |
| `F5` | Help, and switch between the amber, green, and paper themes |
| `Enter` | New paragraph, when the bracket is empty |
| `Up` | Inside a `#tag#`, open the tag chooser |

It reflows to your window, caps the text column at 72 characters in wide terminals so the measure stays readable, autosaves every 15 seconds, and leaves a recovery file it offers to restore if a session dies.

### Mac app (Swift)

A real native AppKit app, and the version that has both modes. New documents ask whether they're Ink or Free-write. It also adds tabs (⌘N opens a new document as a tab; drag one out to split it into its own window), a Format menu for font and colors, and per-tab crash recovery.

Building needs the Xcode Command Line Tools (`xcode-select --install`) but not Xcode itself:

```bash
cd mac
./build.sh
```

The finished `Inkwell.app` lands in `mac/build/` — drag it wherever you keep apps. To have the script install it too:

```bash
INKWELL_INSTALL=1 ./build.sh          # into /Applications
INKWELL_INSTALL=~/Applications ./build.sh
```

The app is signed ad-hoc, not with a paid Apple Developer certificate, so the first launch will get you a Gatekeeper warning. Right-click the app and choose **Open** to get past it.

**Tabs.** `⌘N` opens a new document as a tab in the same window, the way a terminal does — each tab is its own document with its own mode, not a view of the same text. Drag a tab out to split it into a separate window. Right-click a tab to rename its file, or use **File ▸ Rename…**. The Window menu carries the standard macOS tab commands (Show Tab Bar, Show All Tabs, Merge All Windows).

**Menus and shortcuts:**

| | |
|---|---|
| `⌘N` | New document — asks Ink or Free-write, opens as a tab |
| `⌘O` | Open |
| `⌘S` / `⇧⌘S` | Save / Save As… |
| `⌘P` | Print |
| `⌥⌘C` | **Copy Clean Prose** — the whole document, tags stripped |
| `⌘C` | ordinary copy, of the selection as you see it |
| `⌘T` | Font |
| `⌃⌘F` | Full screen |
| `⌘?` | **Inkwell Help** — the mechanic and the keys, inside the app |
| File ▸ | Rename…, Export… |
| Format ▸ | Text / Background / Tag Color, and Appearances |

Two of those are easy to walk past. **`⌥⌘C` is the one you want when moving finished prose somewhere else** — plain `⌘C` copies exactly what's on screen, hashes and all. And **Format ▸ Appearances** saves a font-and-color combination by name so you can keep several and switch between them; **Save as Default Appearance** makes the current one apply to new documents.

---

## Where your writing goes

By default, `~/Documents/Inkwell`, with tag files in `~/Documents/Inkwell/Tags`. Point it elsewhere:

```bash
export INKWELL_DIR="~/Dropbox/Writing"
```

Inkwell **refuses to save outside that folder** — a deliberate guard against a stray path sending a draft somewhere you'll never find it. If you want it to reach other folders too:

```bash
export INKWELL_ALLOWED_ROOTS="~/Documents/Notes:~/Desktop"
```

Saved files are plain Markdown. Sentences run together separated by two spaces; paragraphs are separated by a blank line and indented. Tag-only sentences and paragraphs, which carry no real words, are dropped from the exported prose.

**Auto-save and recovery use that same folder.** Nothing is written anywhere else on your disk — no `~/Library` state, no hidden application-support directory. A named document is re-saved in place every 15 seconds. An unnamed draft goes to a hidden recovery file in the writing folder instead, and the next launch offers to restore it; the Mac app keeps one per tab so open documents never overwrite each other's rescue copy. Give a draft a real name and its recovery file is retired.

The practical consequence: **point `INKWELL_DIR` at a synced folder and your drafts sync; point it at a local one and they never leave the machine.** That's the whole of it — there's no setting anywhere else to get wrong.

---

## Privacy

Inkwell runs entirely on your machine. There is no account, no sync, no telemetry, no network code of any kind. Your text never leaves the computer you typed it on. That's a design commitment, not an oversight — see [docs/DESIGN.md](docs/DESIGN.md).

## Requirements

- **Terminal version:** Python 3. The clipboard key (`F3`) uses macOS's `pbcopy`, so on Linux everything works except that one key.
- **Mac app:** macOS 14 or later, and the Command Line Tools to build it.

## Design notes

[docs/DESIGN.md](docs/DESIGN.md) is the real specification — the fixed core mechanic, the tag scope ladder, the resolved design questions, and what's still open. Read it before changing behavior. The pure text logic (`split_sentences`, `clean`, `extract_tag_records`, `render_export`) is deliberately kept free of any UI code so it can be tested on its own; please keep it that way.

## License

MIT — see [LICENSE](LICENSE). Do what you like with it.
