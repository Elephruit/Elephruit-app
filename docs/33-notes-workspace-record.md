# 33 — The notes workspace: what was built

- **Status:** Record. Steps 2–6 of `31-notes-editor-spec.md`, built on the stored format that
  landed as step 1.
- **Date:** 2026-08-02
- **Branch:** `claude/desktop-notes-workspace-c10010`

## What exists now

A note opens as a page. Runs of consecutive prose share one `NSTextView`; objects — divider,
image, file, table, linked item, nested page — sit between the runs as their own views. The
paragraph kind travels as a custom attribute and every visible consequence is derived from it.
The document (`NoteDocument`) is saved through `Item.setNoteDocument`, debounced half a second,
flushed on navigation, quit, and app-switch, exactly as the plain editor's `PendingSave` was.

### Where things live

| Piece | File |
|---|---|
| Segments, pure editing operations | `ElephruitCore/NoteEditing.swift` |
| Markdown shortcuts, `/` catalogue and matching | `ElephruitCore/NoteInsertion.swift` |
| Pieces ↔ attributed string (the identity) | `ElephruitFeatures/NoteProseConversion.swift` |
| Kind → appearance (fonts, colours, styles) | `ElephruitFeatures/NoteProseStyle.swift` |
| The text view (keys, marks, markers, decorations) | `ElephruitFeatures/NoteProseTextView.swift` |
| The model (document, revisions, focus, outline) | `ElephruitFeatures/NoteEditorModel.swift` |
| One prose segment as a SwiftUI bridge | `ElephruitFeatures/NoteSegmentView.swift` |
| The page (rows, save, imports, links) | `ElephruitFeatures/NotePageView.swift` |
| Object faces (divider, image, file, table, cards) | `ElephruitFeatures/NoteObjectViews.swift` |
| `/` menu, outline rail, format and info panels, reference picker | `ElephruitFeatures/NoteWorkspacePanels.swift` |
| The workspace shell (rail + page + toolbar) | `ElephruitFeatures/KindDetailViews.swift` (`NoteDetailView`) |

### The line that keeps the caret alive

Typing syncs a segment's paragraphs back into the document **without re-rendering anything**;
only structural changes (an object inserted, a piece removed, a load, an undo) bump
`renderRevision`, which is the segments' signal to rebuild from the document. Prose segments are
identified by their ordinal among prose segments; objects by their piece position. Nothing is
identified by its index in the visible list — that is the `/` menu trap from the spec, and it
applies to the page for the same reason.

### Two conversion decisions worth knowing

- `\n` separates paragraphs and always belongs to the paragraph it ends, so an empty paragraph
  mid-document still owns one attributed character. The single shape the string cannot carry —
  an empty *final* paragraph's kind — is supplied by the text view's typing attributes.
- `U+2028` is a line break *inside* a paragraph, stored as `\n` inside the piece's text. Return
  inside a code block therefore keeps the block one piece, which is what the fenced Markdown
  projection expects.

### A shortcut that cannot be typed

`- [ ] ` converts to a bulleted item at `- `, two keys before the bracket arrives. The checklist
is reachable by hand as `[ ] ` (or `[] `), including on an already-bulleted item, which keeps its
indent. The dash spellings still match for text that arrives whole.

## How it is verified, with no window

- `NoteEditingTests`, `NoteInsertionTests` — the pure operations and matching (ElephruitCore).
- `NoteProseConversionTests` — the round trip is the identity: every kind, indent, mark, link,
  emoji, the empty document, and the trailing-empty hint.
- `NoteEditorFlowTests` — keystrokes into the real `NoteProseTextView`, assertions on the
  document the model then holds: Return semantics per kind, code-block entry and exit, Markdown
  shortcuts, Tab/Backspace, marks, links, the `/` menu lifecycle, outline entries.
- `NoteGalleryTests` — PNGs of the page's typography (both appearances, via `cacheDisplay`,
  which exercises the same `draw(_:)` that paints markers and tints in the app), the `/` menu
  rows, the outline, and the format panel. Gated on `ELEPHRUIT_GALLERY`, like the component
  gallery, and for the same reasons.

## Deliberately not built

- **Menu-bar Format menu.** The format panel covers the selection operation; wiring the menu bar
  to the focused note model is its own slice.
- **Wiki-link completion inside the rich editor.** Typed `[[Target]]` survives literally in the
  text, so the projection still carries it and link reconciliation still works; the styled-run
  form and the completion popover are follow-ups.
- **Drag reordering of pieces.** Move Up/Down lives on the object context menu. If drag returns
  it needs a `DropDelegate`, per the spec's trap list.
- **Table cells beyond plain text**, image resizing, and a language-aware code highlighter.

## Watch for

- The visual gallery cannot show composed windows (materials, toolbars, split views). The first
  manual run of the app should look at: the `/` menu's position near the viewport edges, the
  focus handoff across objects (↑/↓ at segment edges), and `scrollToVisible` from the outline
  inside SwiftUI's scroll view.
- `NSTextView` undo of attribute-only changes (kind rewrites, mark toggles) goes through
  `shouldChangeText(in:replacementString: nil)`; if a case turns up where ⌘Z skips one, the fix
  belongs in `rewriteParagraph`, not in ad-hoc undo registration at call sites.
