# 31 — The notes editor: what to build, and what not to build again

- **Status:** Built. Step 1 landed as the stored format; steps 2–6 are recorded in
  `33-notes-workspace-record.md`.
- **Date:** 2026-08-01

## Why this document exists

A notes module was built and then lost — the working tree it lived in was deleted, its commits were
never pushed, and the objects went with the directory. This is not a record of that work. It is the
spec for building it once, written while what was learned from building it the first time is still
known, and specifically while the reasons the first attempt fought its own architecture are still
recoverable.

The most valuable part of this document is not the design. It is
[Traps already paid for](#traps-already-paid-for): six defects that were found, diagnosed to root
cause, and fixed. Four of them were consequences of a design decision this spec reverses, and cannot
recur. Two are general and will recur unless something pins them down.

## What already exists on `main`

Little. Being precise about this matters, because the first build assumed more.

- `ItemKind.note` — notes are already a kind of `Item`, with containment rules already decided
  (`ItemKind.swift:155`, `:222`).
- `Item.body: String` — a plain-text body, today the whole of a note's content.
- `NotesField` — a plain-text editor component used by five surfaces (task detail, note detail,
  project brief, bookmark description, person body). It stays. It is not the notes workspace and
  should not grow into it.
- **ADR 0006** — the storage format is already decided and does not need revisiting. Rich text is a
  versioned, `Codable` run-list with an allow-listed attribute set; `Item.body` remains the derived
  plain-text projection that feeds FTS, Markdown export and wiki-link reconciliation.

Nothing implements ADR 0006 yet. There is no rich-text payload on `Item`, no document type, no
workspace.

## The decision this spec turns on

**A note is a continuous document that can contain objects, not a stack of blocks.**

The first build modelled a note the way Craft and Notion do: a tree of blocks, each paragraph its own
block, each block its own `NSTextView`, each with a gutter handle, a drag affordance, and its own
focus. It was rejected on use — it reads as a page being assembled rather than written.

That is the stated reason and it is sufficient on its own. What makes the decision easy is that the
same architecture was also the direct cause of most of what went wrong. One text view per paragraph
means every one of these is a problem you have to solve, and none of them is a problem a writer
should ever have heard of:

- The caret has to be handed from one text view to another on every press of Return, across a gap in
  which the receiving view does not exist yet.
- Every paragraph has to report its own height to SwiftUI, and get it right before it has been laid
  out.
- Selection cannot span a paragraph boundary without being synthesised.
- Hover has to be tracked per row, through an `NSViewRepresentable` that is not obliged to report it.

A single text view gets all four from AppKit for free, because they are the things a text view is.

### What this does *not* mean

The block *model* stays. ADR 0006's run list is unaffected, and a note is still a sequence of
semantic pieces when stored — that is what makes the outline, export, search and links work. What
changes is that consecutive prose is **edited as one text view**, with the piece boundaries carried
as paragraph styles rather than as view boundaries.

Decided with the user, 2026-08-01:

- **Editing surface only.** The stored document keeps its structure. Search, export, the outline,
  wiki links and migrations are unaffected by this change.
- **Media stays, furniture goes.** Images, files, tables and item references remain as objects the
  prose flows around. Toggle, card and columns are cut. They are the assembled-page furniture, and
  they are the reason the first attempt needed a block tree with children rather than a list.

## What a note is made of

A note is an ordered list of **pieces**. There are exactly two sorts.

**Prose pieces** carry text and a paragraph kind:

| Kind | Notes |
|---|---|
| `paragraph` | The default. |
| `heading1` `heading2` `heading3` | Appear in the outline. |
| `quote` | |
| `code` | Has a language. Monospaced, no spell checking, no smart substitution. |
| `callout` | Has a tone. Tinted. |
| `bulleted` `numbered` `checklist` | Have an indent level. `checklist` carries a ticked state. |

**Object pieces** are not text: `image`, `file`, `table`, `reference` (a linked task, person, project
or event), `page` (a nested note), `divider`.

A prose piece has no children. Nesting is an **indent level on a list item**, which is an integer,
not a tree. This is the single biggest simplification available and it should be taken: the first
build's block tree existed to hold toggles and cards, and those are gone.

## The editing surface

The page is a vertical sequence of **segments**. A run of consecutive prose pieces becomes one
segment and one `NSTextView`. Each object piece is its own segment and its own view. A note of
twenty paragraphs, one image, and ten more paragraphs is three segments, not thirty-one.

Inside a prose segment:

- One paragraph of the text view is one prose piece. Return inserts a newline; it does not hand focus
  anywhere, because there is nowhere to hand it to.
- The paragraph kind is carried as a **custom attribute on the paragraph**, and rendered by deriving
  an `NSParagraphStyle`, font and colour from it. It is the attribute that is authoritative, never
  the appearance — the same rule ADR 0006 gives for the stored format, for the same reason.
- Selection, `⌘B`, arrow keys, word movement, kill-line, dictation, the emoji picker and Find all
  work across paragraphs without any code, because they are one text view's problem and AppKit has
  already solved them.
- Tab and Shift-Tab change a list item's indent level. On a non-list paragraph they should do
  nothing rather than insert a tab.

The conversion between the stored pieces and the `NSAttributedString` is the only genuinely new
thing here, and it is the thing to test hardest. It must round-trip exactly: pieces → attributed
string → pieces is the identity, for every kind, every indent level, every inline mark, and an empty
document.

## Inserting things

Three routes, deliberately. They are not redundant; they are for three different people.

1. **Markdown shortcuts while typing** — `# `, `## `, `- `, `1. `, `- [ ] `, `> `, ` ``` `. Only at
   the start of a paragraph, so "1. " inside a sentence about version numbers stays prose. This is
   how someone who already knows what they want gets it without lifting their hands.
2. **A `/` menu** — searchable, keyboard-navigable, for when you know the thing exists but not what
   it is called. It should match on what a piece *does* as well as what it is called: typing "tick"
   should find the checklist and "collapse" should find nothing, now that toggles are gone.
3. **The Format menu** — applies a kind to whatever is selected, with the standard shortcuts. This is
   the route that has to work on an existing paragraph, and the one the other two do not cover:
   turning three written paragraphs into a quote is a selection operation, not an insertion.

Inserting an object piece splits the prose segment it was inserted into. That split is the only
place segment boundaries move, and it is worth having a test that says so.

## Traps already paid for

Each of these was a real defect, diagnosed to root cause. Four are listed as *gone* — they were
consequences of one-view-per-block and the design above cannot express them. They are recorded
anyway, because "we should go back to blocks" will sound reasonable in six months and this is the
bill for it.

### Still live — these will recur

**Exported drag types must be declared in `Info.plist`.** `UTType(exportedAs:)` asserts that this
application is the authority on an identifier, and the system checks the claim against the bundle.
When the declaration is missing nothing throws: the type gets a dynamically assigned identifier, so
the drag source writes one type and the drop target asks for another, no drop is ever offered, and
the dragged thing springs back with no diagnostic anywhere. This shipped **twice** —
`com.elephruit.task-drag`, then both note types. It presents as "drag and drop does nothing", which
is indistinguishable from a gesture that never started.

*Pin it:* a test that scans the source for every `UTType(exportedAs:)` and fails, naming the file and
the identifier, if it is not in `UTExportedTypeDeclarations`. This existed and worked; write it
again. It is cheap and it is the only thing that catches this before a user does.

**`.id()` inside a `ForEach` outranks the identity `ForEach` derives from the element.** The `/`
menu's rows carried `.id(index)` so a `ScrollViewReader` could reach them. When the search results
changed, the row count updated correctly while position zero kept rendering the block it used to
show — searching for "code" returned exactly one result reading "Text · Ordinary prose". The
matching logic was never wrong, which is what made it hard to see.

*Pin it:* identify rows by the thing they represent, never by position, and scroll to that same
identity. Keep the matching logic as a pure function with its own tests, separate from the view, so
"does searching for `code` find the code block" has an answer that does not require a window.

### Gone with the block architecture — do not reintroduce the cause

**Block heights went stale and paragraphs drew on top of each other.** Height came from
`intrinsicContentSize`, which is a cache, and the only thing invalidating it was a change of *width*.
Typing does not change the width, so a paragraph that wrapped onto a second line went on reporting
one line and the next block was laid out over it. If any `NSViewRepresentable` here ever sizes
itself, answer with `sizeThatFits`, which SwiftUI asks afresh every layout pass and hands the width
to wrap against — never with a cache nothing invalidates.

**The caret did not follow Return.** Pressing Return created a paragraph in a text view that did not
exist yet, so the focus claim had to survive until that view reached a window. It was retried only
from `viewDidMoveToWindow`, whose timing is SwiftUI's to decide; an animated `scrollTo` in the same
transaction delayed it further; and a refusal from `makeFirstResponder` was discarded rather than
retried. The first letters of a new sentence landed at the end of the old one. **A single text view
has no handover.** This is the defect that most justifies the redesign.

**Keeping the caret visible is not the same as centring it.** `scrollTo(id, anchor: .center)` moved
the page on every press of Return to solve a problem that did not exist. Use no anchor: it scrolls
the least it can and does nothing when the target is already visible. Do not wrap it in
`withAnimation` when it fires in the same turn as a structural change.

**Hover reported through an `NSViewRepresentable` is unreliable.** A gutter handle revealed on row
hover could not be reached, because crossing from the text into the gutter posted the row's exit
before the gutter's enter. Two hover states were tracked and only one was read. More usefully: most
of a note row is an `NSTextView`, and whether SwiftUI hears about a hover over it is at the mercy of
that view's tracking areas. Do not build an affordance that only appears on hover over text.

**`dropDestination` cannot say where a drop would land.** It reports only *whether* a drag is over a
view, so an indicator can say "near this" and not "above this". If block reordering by drag ever
returns, it needs a `DropDelegate`, which is told the pointer's position on every move — and the
"may it land here" and "on which side" questions must be answered by one function, or the indicator
will promise a move the drop then refuses.

## Order of work

1. **The stored format.** Implement ADR 0006: the versioned run-list payload, the `Item.body`
   projection regenerated on write, the migration turning today's `body` into a single unstyled run.
   The migration gate is exact character equality of the regenerated projection against the original
   string. Nothing above this line is visible, and everything above it depends on it.
2. **The pieces.** The piece list, the kinds, the indent level, and the editing operations over them
   as pure functions — split, join, change kind, indent, outdent, move. No views. This is where the
   tests are cheap and where correctness is decided.
3. **The prose segment.** One `NSTextView`, the attributed-string conversion both ways, paragraph
   kinds as attributes, Return, Tab, Backspace at a paragraph start, markdown shortcuts.
4. **The page.** Segments, object pieces between them, the split when an object is inserted.
5. **Insertion.** The `/` menu, the Format menu.
6. **The rest.** The outline from headings, the inspector, export, the search projection.

## Notes for whoever picks this up

- `AppServices.inMemory(populated:)` builds a whole service graph against a temporary store; feature
  tests use it and it makes model-level tests cheap. There is no need to hand-build a persistence
  stack.
- Run the app against a throwaway library with
  `-ElephruitDevelopmentMode -ElephruitUseTemporaryStore`; the README has the full incantation.
- The house rule that no view names a literal colour is enforced by
  `SourceHygieneTests.coloursComeFromTheDesignSystem`. A text editor that derives appearance from
  paragraph kind must resolve every colour through the design system, including the code block's
  background and the callout's tint, or it will be unreadable in dark mode. ADR 0006's consequence 4
  is the same rule arriving from the other direction: pasted content carries hard-coded colours and
  must be sanitised on the way in.
- **Commit and push as you go.** This document exists because five commits lived only in a working
  tree that was deleted. Nothing was recoverable — not from `git fsck`, not from the trash, not from
  `origin`. A branch that has never been pushed is not saved.
