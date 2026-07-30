# Everything — Product Definition

## One-line

**Everything** is a private, local-first macOS app that holds one person's entire
working memory — notes, tasks, projects, people, and reference material — in a
single linked graph, with the speed and calm of a native Mac tool.

## The problem

A single person's thinking is currently split across five or six apps. Notes live
apart from the tasks they generated. A commitment made to a person in a meeting
lives in neither the person's record nor the project's plan. Search is per-app, so
recall requires remembering *where* you put something before you can find *what* you
put there. Every app's export is a hostage negotiation.

## The bet

The unit of value is not the note or the task — it is the **link between them**.
If one store holds notes, tasks, projects, and people, and every one of them can
link to every other, then a single search surface and a single daily view become
possible. That is the product.

## Design principles

1. **Local-first, always.** Every feature works with the network off. Sync is a
   convenience layer, never a dependency. The store on disk is the truth.
2. **One home per fact.** No fact is duplicated across stores. Each kind of data is
   assigned exactly one authoritative home (see `03-storage-matrix.md`).
3. **Plain text survives.** Note bodies are Markdown-compatible text, stored as
   text. Any future rich-text layer is additive and lossless, never a replacement.
4. **Keyboard first, mouse welcome.** Every primitive action is reachable without
   the trackpad, via a command palette and real menu commands with real shortcuts.
5. **Calm density.** Show a lot without shouting. No badges competing for attention,
   no gamification, no streaks, no nudges.
6. **Escapable.** Full-fidelity export in durable formats is a first-class feature
   shipped in v1, not a checkbox added under pressure.
7. **Nothing leaves the device** unless the user turns on a specific, named
   integration. No analytics. No telemetry. No crash reporting SDK.

## Explicit non-goals (v1)

| Not doing | Why |
|---|---|
| Collaboration / sharing / multiplayer | Single-user product. Changes the data model and the security model fundamentally. |
| Web or Windows client | The value proposition is *native*. |
| LLM features in the core loop | Determinism and privacy. Enrichment stays on-device and optional. |
| WYSIWYG rich text | Markdown text first; see principle 3. |
| Databases / formulas / Notion-style blocks | A typed domain model beats a generic block soup for a single user's own data. |
| Public API / plugins | Premature. Export is the extension point in v1. |
| Time tracking, invoicing, habits-with-streaks | Scope discipline. |

## Target user

One person — the author — who reads and writes a lot, runs several projects at
once, and keeps track of many people. Comfortable with Markdown and keyboard
shortcuts. Sceptical of subscriptions and cloud lock-in. Uses one or two Macs and
an iPhone.

## What "good" looks like (v1 quality bar)

- Cold launch to usable window: **< 700 ms** on Apple silicon.
- Keystroke-to-glyph latency in the editor: imperceptible at 10 000-word notes.
- Search results begin appearing within **100 ms** of the second character, over a
  corpus of 20 000 items.
- Zero data loss on force-quit mid-edit.
- Zero warnings in the build. No force unwraps. No `fatalError` on a recoverable path.

---

## Primary user journeys

These nine journeys are the acceptance surface for v1. Each is written as the
sequence a user actually performs, with the keyboard path noted.

### J1 — Capture without breaking flow
Anywhere in the app, `⌘⇧N` opens Quick Capture over the current window. The user
types a line, optionally types `#tag`, `@person`, or `>project` inline, presses
`⌘↩`, and the panel closes. The item lands in **Inbox**. Total interaction: under
four seconds, no mouse, no decision about *where* it goes.

### J2 — Triage the Inbox
`⌘1` → Inbox. The list is a queue. For each item the user can, from the keyboard:
convert note↔task (`⌘⌥T`), assign a project (`⌘⇧P` → fuzzy picker), add tags
(`⌘⇧T`), set a due date (`⌘⇧D` → natural-ish date field), or archive/delete.
Inbox empty state is a genuine reward, not a stock illustration.

### J3 — Write and link
`⌘2` → Notes, `⌘N` for a new note. Title on line one, Markdown body below. Typing
`[[` opens an inline completion over existing item titles; accepting inserts a
wiki-link. If the target does not exist, the link renders as *unresolved* and can
be created in place. The Inspector shows **Backlinks** — every item pointing here —
computed, never hand-maintained.

### J4 — Run the day
`⌘0` → Today. Three bands: **Due & overdue**, **Scheduled today**, **Recently
touched**. Completing a task is `Space`. A recurring task completed today
re-schedules itself rather than duplicating. This view answers exactly one
question — *what now* — and refuses to answer any other.

### J5 — Drive a project
`⌘3` → Projects. A project shows its tasks (open first), its notes, its people,
and its own free-text brief in one scroll. Progress is a quiet ratio, not a
celebration. Completing the last task offers to complete the project.

### J6 — Remember a person *(Phase 3)*
`⌘4` → People. A person shows every interaction, every note that mentions them,
every open task assigned to or owed by them, and the projects they touch — all
derived from links, none of it re-entered.

### J7 — Find anything
`⌘⇧F` (or `⌘K` for the palette in navigate mode) opens unified search. Free text
is matched against titles and bodies; a token grammar narrows it
(`type:task tag:urgent project:"Q3 Launch" is:open due:<7d`). Results are grouped
by type with matched terms highlighted. Any query can be saved as a smart view
that then lives in the sidebar.

### J8 — Get everything back out
`⌘⇧E` → Export. Choose **JSON archive** (complete, versioned, round-trippable,
identifiers preserved) or **Markdown bundle** (one `.md` per note with YAML
front-matter, attachments in a predictable tree). Import accepts both, validates
before writing, detects duplicates by stable ID then by content hash, and reports
exactly what it did.

### J9 — Undo a mistake
Deleting moves to **Trash** with a restore path that reattaches original
relationships. `⌘Z` undoes edits and structural changes within a window's
undo stack. Nothing is destroyed without an explicit, separate "Delete
Permanently".

---

## Command surface (v1)

| Shortcut | Action |
|---|---|
| `⌘K` | Command palette |
| `⌘⇧N` | Quick Capture |
| `⌘N` | New item in current context |
| `⌘⇧F` | Unified search |
| `⌘0`…`⌘5` | Today / Inbox / Notes / Tasks / Projects / Tags |
| `⌘⌥I` | Toggle Inspector |
| `⌘⌃S` | Toggle Sidebar |
| `Space` | Toggle task completion in list |
| `⌘⇧D` / `⌘⇧P` / `⌘⇧T` | Set due date / project / tags |
| `⌘⌫` | Move to Trash |
| `⌘Z` / `⌘⇧Z` | Undo / Redo |
