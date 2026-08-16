# Inkwell — design spec & development record

> Working name: **Inkwell** (rename freely — the name has no effect on behavior).
> This document is the author's design. The **Core Mechanic** below is the fixed part;
> implementation details and feature additions are open.
>
> **Status (updated to match the shipping code):** the terminal version
> (`inkwell.py`) now implements the full Core Mechanic *and* the tag / cross-file
> filing system that earlier drafts of this spec listed as "deferred." Sections
> below have been brought in line with what the code actually does.

---

## The idea

A forward-only writing tool. The point is to **commit words to print like paint to
canvas** — to separate drafting from editing so the act of writing isn't strangled by
the urge to correct. You draft freely inside a small editable zone, then deliberately
*commit* a chunk, and once committed it's ink: frozen, permanent, no reaching back.

This is **not** the blunt "disable backspace entirely" approach (which traps you with a
typo forever). It's a more precise model: full freedom inside the live zone, irreversibility
only at a boundary you cross on purpose.

---

## Two modes

A document is either **Ink** or **Free-write**. The mode is chosen when the document is
created and is fixed for that document's life — it is deliberately not a switch you can
flip mid-draft, because a discipline you can switch off mid-sentence isn't one.

- **Ink** — the forward-only mechanic specified below. This is the reason Inkwell exists.
- **Free-write** — plain typing. No brackets, edit anywhere, ordinary editor behavior.

Both write the same file format to the same folder and share the tag system, so a draft
started in one mode is just a file to the other.

Only the Mac app offers the choice; the terminal version is Ink-only, and everything in
the Core Mechanic below describes Ink mode. That asymmetry is deliberate: in a terminal
the user is already surrounded by editors, and since Inkwell writes plain Markdown to a
folder of their choosing, any of them already serves as Free-write. The Mac app has no
such escape hatch, so the mode had to exist there. Do not "restore parity" by porting
Free-write to the terminal — it would duplicate the shell and widen the drift between
the two hand-maintained copies of the text logic.

---

## Core mechanic (the fixed rules)

These rules are settled and define the product. Do not change them without the author's say-so.

1. **The pen is a bracket.** The app opens with an empty, indented live bracket `[ ]`
   with the cursor inside it. You always type inside the bracket.

2. **Inside the bracket is a normal editor.** Backspace, retype, rearrange, move the
   cursor — full editing, with no restrictions, as long as the text is still inside the
   live bracket.

3. **Committed text is stone.** Anything that has been committed (frozen into the document)
   is immutable. The cursor cannot reach back into it. The frozen/live boundary only ever
   moves forward.

4. **A sentence-ender followed by a double space commits.** The commit gesture is typing a
   sentence-ender — `.`, `?`, or `!` — and then **two spaces**. An ellipsis (`...`) works
   too, since it ends in a period; a run of enders is treated as one. At that moment the
   bracket:
   - removes its brackets (they are scaffolding, not content),
   - freezes the text into the document, **including** the ender and the two trailing
     spaces (those two spaces *are* the typewriter sentence spacing),
   - opens a fresh `[ ]` **on the same line**, so sentences flow horizontally into a
     running prose paragraph.

   A single space after an ender does **not** commit (so "Mr. Smith" types normally). The
   commit fires only on the second consecutive space, only when the bracket text *ends*
   with the gesture, and **not** while the cursor is inside an open `#tag#`.

5. **Enter on an empty bracket starts a new paragraph.** Enter is **not** the commit
   gesture. Its only job is: when the live bracket is empty, pressing Enter drops to a new,
   **indented** paragraph with a fresh live bracket. (State-based: an empty live bracket +
   Enter = paragraph.) Enter inside a non-empty bracket does nothing.

6. **Indentation.** The first line is indented like a paragraph, and every new paragraph is
   indented the same way. Standard first-line prose indentation.

### The underlying model (for reference)

The bracket rule above is the automated, friendly surface of a deeper model the author
defined:

- Plain text outside any delimiter is **committed** (frozen, prints).
- `[ ]` brackets mark an **editable region**; the brackets are scaffolding. "Breaking"
  both brackets (removing them) is what commits the text inside. **An ender + double space
  automates the breaking.**
- `#...#` hashes mark text that is **editable but non-committing** — these are the
  **tags** (built; see Tags below).

---

## Tags `#...#`  (built)

Wrap text in hashes to make a **tag**: `#like this#`. Tags are editable, never commit, are
**visible while you write**, and are **stripped from everything that leaves the app**
(saved prose files and the clipboard). They do two jobs at once — a marker in the draft and
a cross-file filing instruction.

**Entering a tag.** Type `#`, then either type a new tag name and close it with another `#`,
or press **Up** to open a chooser of tags you've used before (Up/Down scrolls, typing
filters the list, `#` accepts the highlighted tag, Esc cancels). The chooser draws its list
from tags already in the document *and* from existing files in the `Tags/` folder.

**Filing on save.** On every save, each tag is written to its own file —
`<your writing folder>/Tags/<tagname>.md` — alongside the passage it references. Re-saving the
same source file is idempotent (it replaces that file's previous entries rather than
duplicating them), and each entry is stamped with the source filename and a timestamp via an
HTML comment (`<!-- src:FILE -->`).

**Scope ladder — how much text a tag captures** (in `extract_tag_records`):

1. **Mid-sentence tag** → the text *before* it in that sentence.
2. **End-of-sentence tag** → that sentence plus every earlier sentence in the paragraph.
3. **Tag-only sentence** → every earlier sentence in the paragraph.
4. **Tag-only paragraph** → all text in every earlier paragraph.

This is the cross-file filing/routing idea from earlier drafts, now realized: `#tag#` *is*
the routing marker, the destination is the per-tag file, and the scope ladder defines how
much each tag pulls in.

---

## Output / save format

- **Markdown (`.md`) is the baseline save format.** Save (F1) defaults to a name like
  `inkwell-YYYYMMDD-HHMM.md` in the Inkwell folder; you may type your own name, and `.md` or
  `.txt` are accepted (anything else gets `.md` appended).
- Prose flows horizontally: committed sentences run together, separated by two spaces.
- Paragraphs are separated by a blank line and begin with a first-line indent (a tab on export).
- Exported prose is **clean**: tags are stripped, spacing is normalized, and tag-only
  sentences / paragraphs (which carry no real words) are dropped from the printed document.

---

## Current implementation — `inkwell.py` (terminal)

The terminal version is the one that has been carried forward, and it implements the full
Core Mechanic plus the tag system.

- **Python 3, standard-library `curses` only** — no pip installs, no dependencies.
  Run: `python3 inkwell.py`.  Self-test the pure text logic: `python3 inkwell.py --selftest`.
- **Window-aware layout.** Text reflows to the window. Narrow panes use their full width;
  wide windows cap the text column at **72** characters (`MAX_MEASURE`) and add a little top
  padding, so prose stays a comfortable measure instead of stretching across a huge terminal.
  It rewraps live on resize.
- **Three themes** (`F5` help screen, then `a`/`b`/`c`): **amber** (default typewriter),
  **green** (phosphor), **paper** (painted white page, dark ink).
- **Saves to disk natively** as `.md`, into your writing folder. Saving is hard-limited to
  the writer's allowed folders (`within_allowed` / `ALLOWED_ROOTS`); it refuses to write
  outside them.
- **Auto-save & crash recovery.** Every ~15s it auto-saves a named file, or — for an
  unnamed draft — writes a hidden recovery file (`.inkwell-recovery.md`). On the next launch
  it offers to restore any unsaved draft left behind, and retires the recovery file once you
  give the work a real name.
- **Status bar** shows live word count, a session timer (`mm:ss`), an "unsaved" flag, and
  status messages.
- **Keys** (these are `fn`+function keys on a Mac laptop):
  - `F1` — Save (asks for a name; defaults to the Inkwell folder)
  - `F2` — Open one of your Inkwell files (`.md`/`.txt`); the file loads as frozen ink to
    write on from the end
  - `F3` — Copy clean prose to the clipboard (tags stripped, via `pbcopy`)
  - `F4` — Exit (warns once if there's unsaved work; press again to quit)
  - `F5` — Help screen / theme switcher
  - `Enter` — new paragraph when the bracket is empty
  - `Backspace` / `Delete` — edit within the live bracket only
  - `Left` / `Right` / `Home` / `End` — move the cursor within the live bracket
  - `Up` — inside a `#tag#`, open / scroll the tag chooser

> **Note on the browser version.** Earlier drafts described a sibling `inkwell.html`
> (single self-contained file; warm "ink on paper" serif aesthetic; runs by double-click but
> has no disk access). It remains the intended home for the *visual* craft, but it has **not**
> been kept in sync with the terminal version's tag/filing system or the current commit
> gesture, and its state here is unverified. Treat the terminal version as the reference
> implementation of behavior.

---

## Resolved design questions (were open; the code now decides them)

- **Enders.** Commit fires on `.`, `?`, or `!` (plus ellipsis), each followed by a double
  space — not period-only.
- **Tags print or strip?** Tags are **stripped** from exports and the clipboard; tag-only
  passages don't appear in the printed prose at all.
- **Bookmarks / cross-file filing.** Both are realized by the single `#...#` tag mechanic
  (visible marker + per-tag file with a defined scope ladder).
- **Enter inside a non-empty bracket.** Does nothing (ignored). Enter is purely the
  empty-bracket new-paragraph gesture.
- **Abbreviations.** Handled by discipline, as the author preferred: single-space after
  "Dr.", "U.S.", "etc.", and reserve the deliberate double space as the commit stroke. There
  is no abbreviation exception list.

---

## Still open / possible next steps

- **A navigable tag/bookmark view inside the app** (a sidebar or outline that jumps to where
  each tag was used) — the files exist on disk, but there's no in-app browser of them yet.
- **Electron / GUI version.** If the browser version is ever wrapped as a real Mac app
  (the same tech behind VS Code, Slack, Notion), the goal is real "Save As…" to chosen
  folders, auto-save, and reopening prior sessions — and to bring its tag/filing behavior up
  to parity with the terminal version. Build/run happens on the author's own Mac.
- **Richer file format** that preserves live/committed state (vs. the current clean `.md`
  export), if reopening mid-draft ever needs to restore the exact pen position.

---

## Notes for whoever picks this up

- The **logic is the valuable part** and it's the author's. Treat the Core Mechanic and the
  tag scope ladder as the spec; UI features are scaffolding around them.
- The pure text logic (`split_sentences`, `clean`, `extract_tag_records`, `render_export`)
  is deliberately free of `curses` so it can be unit-tested — see `--selftest`. Keep it that
  way when extending.
- Privacy is a feature, not an afterthought: the app runs **entirely locally** — text never
  leaves the machine, and saving is fenced to the writer's own folders. Preserve that. Do not
  add cloud sync or remote storage without an explicit, opt-in decision from the author.
- **Saving is fenced on purpose.** `within_allowed` / `allowedRoots` stop the app writing
  outside your writing folder. That is a deliberate guard, not a leftover — keep it, and
  widen it through `INKWELL_ALLOWED_ROOTS` rather than by deleting the check.
