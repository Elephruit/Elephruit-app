# 41 — Life projects and the notes module

- **Status:** Plan.
- **Date:** 2026-08-06
- **Branch:** `claude/trip-planning-reminders-notes-0b4b1d`

## The question

> "Projects? Folders? Work? I'm not sure what the right thing would be — we're planning a trip to
> Chicago and I want reminders for it (book a hotel, buy tickets for the Pokémon exhibit at the Field
> Museum), tracked together, and archivable when the trip is over. Still searchable, but archived."

## The answer: it is a project, and the model already agrees

`AppModule.projects` describes itself as **"Work with an outcome and an end"**
([AppModule.swift:113](Packages/ElephruitKit/Sources/ElephruitFeaturesCore/AppModule.swift:113)).
An area is **"Standing responsibilities, which never finish"**. A trip to Chicago has an outcome and
an end; *travel* is the standing responsibility that outlives it. So:

```
Area "Travel"  ▸  Project "Chicago, October"  ▸  reminders, notes, bookmarks
```

No new kind, no migration, no third concept. And archiving is already built:
`ItemRepository.setArchived` cascades through everything the project contains
([ItemRepository.swift:397](Packages/ElephruitKit/Sources/ElephruitPersistence/ItemRepository.swift:397)),
`ItemQuery.archive()` reads it back, and `archivedAt` has been in the schema since v1.

### Why not a new "folder" or "collection" kind

`Collection` already exists for manual ordering, `.list` already exists for a flat list that maps
onto an Apple Reminders list, and `.area` already exists for the never-ending container. A fourth
container would have to explain to the user why it is not one of those three, and to
`ItemKind.canContain` why it needs a new row. The reason it *feels* like the wrong word is not the
model — it is the presentation, which is the actual subject of this plan.

## What is actually missing

Seven gaps, each verified in this worktree. This is the whole of the work; everything else already
exists and must not be rebuilt.

1. **A project cannot contain a note.**
   `ItemKind.project.canContain(_:)` allows headings, work items, milestones and releases, and
   nothing else ([ItemKind.swift:323](Packages/ElephruitKit/Sources/ElephruitCore/ItemKind.swift:323)).
   The trip's confirmation numbers, its restaurant shortlist and its packing notes have no home
   inside the trip. `ProjectDetailView` compensates by gathering notes **by link**
   ([ProjectDetailView.swift:306](Packages/ElephruitKit/Sources/ElephruitFeatures/ProjectDetailView.swift:306)),
   which is a real mechanism and worth keeping — but a linked note is not archived when the trip is,
   because the cascade follows containment.

2. **The project workspace has nowhere to put a note.** `ProjectViewKind` has seven cases — overview,
   board, list, table, bugs, calendar, timeline
   ([ProjectWorkspace.swift:127](Packages/ElephruitKit/Sources/ElephruitCore/ProjectWorkspace.swift:127))
   — and none of them is prose. The link-based section above exists only in the older detail view,
   not in the workspace you open a project into.

3. **Every project is issued a reference key.** `createProject` falls through
   `suggestedKey(forProjectNamed:)` → `template.suggestedKey` → `"PRJ"`, and always calls
   `setProjectKey` ([ProjectTemplateService.swift:47](Packages/ElephruitKit/Sources/ElephruitPersistence/ProjectTemplateService.swift:47)).
   The Chicago trip gets `CHI-1 Book a hotel`, `CHI-2 Buy Pokémon tickets`. That is an issue tracker
   introducing itself at the wrong party.

4. **Every project ships a Bugs tab.** Recorded as deliberate — a view holds no work, so an unused
   tab costs a word of width ([32-projects-workspace-reconstruction.md §6](32-projects-workspace-reconstruction.md)).
   That reasoning was arrived at while building a software tracker and does not survive contact with
   a holiday. It is reversed below, narrowly.

5. **Archive is a flat bin.** `ItemQuery.archive()` returns every archived row sorted by
   `updatedAt`, with containers mixed in among their contents
   ([ItemQuery.swift:456](Packages/ElephruitKit/Sources/ElephruitPersistence/ItemQuery.swift:456)).
   Archiving a trip with fourteen reminders and five notes produces twenty rows. The trip stops
   being a thing you can reopen and read, which is the entire point of archiving rather than
   deleting.

6. **Archived content is invisible to search unless you know a token.** `SearchService` excludes
   anything with an `archivedAt` unless the query carries `is:archived`
   ([SearchService.swift:216](Packages/ElephruitKit/Sources/ElephruitSearch/SearchService.swift:216)).
   The grammar supports it; nothing in the interface says so. "Still searchable" is, today, false by
   default.

7. **Notes have no hierarchy, and their nesting is a fiction.** The notes module is four kind rows —
   All Notes, Ideas, Reference, Daily
   ([SidebarModel.swift:154](Packages/ElephruitKit/Sources/ElephruitFeaturesCore/SidebarModel.swift:154))
   — organised by tag and saved search. The editor offers a nested page, but the comment on it is
   candid: *"A nested page is a real note, created now, linked from here. Not a child in the store —
   notes do not contain items"*
   ([NotePageView.swift:347](Packages/ElephruitKit/Sources/ElephruitFeatures/NotePageView.swift:347)).
   It is filed as a **sibling**. Archive the parent and the page stays behind; trash the parent and
   the page is orphaned. `ItemKind.note.supportedFields` is `[.body, .tags]` — no `.children`
   ([ItemKind.swift:194](Packages/ElephruitKit/Sources/ElephruitCore/ItemKind.swift:194)).

### And one that is not in scope but must be said

**iOS flattens rich notes on edit.** `ItemScreen.saveText` re-imports the plain text through
`NoteBodyImport.document(from:)` whenever a note document exists
([ItemScreen.swift:578](ElephruitiOS/Screens/ItemScreen.swift:578)). The intent is stated and good —
one document rather than two diverging copies — but the consequence is that a note carrying a table,
an image or a web clip, opened and touched on the phone, comes back as the Markdown projection of
itself. Anything the projection cannot carry is gone. See phase 7.

## Decisions

### A project contains prose, and the containment is what archives

Add `.note` and `.bookmark` to `ItemKind.project.canContain`. This is safe because the project's
arithmetic already asks `isWorkItem`, not "is a child" — `descendantWork`, `taskProgress` and every
count were swept onto that predicate when bugs and features were added, which is precisely the
insurance this change needs. A note under a project counts toward nothing and archives with
everything.

Linked notes stay linked and stay listed. The difference is stated in the interface: contained notes
belong to the trip, linked notes are referenced by it, and only the first cascade.

### Templates decide which views exist, not just their order

Reversing part of §6 of the reconstruction record, and only that part. `ProjectTemplate.featuredViews`
becomes the set that is **created**; the remaining kinds stay reachable through "Add View". The
original argument — a missing tab costs finding the add menu — holds for a team choosing between a
board and a table. It does not hold for a defect tracker on a holiday, which is not a tab the user
failed to find but a claim about what this project is.

Software keeps all seven. Trip, personal and general get list, calendar, notes and board.

### A key is opt-in

`createProject` stops defaulting to `"PRJ"`. A key is set when the caller passes one or the template
suggests one (software does; nothing else will). `WorkItemReference` is unchanged — a project with no
key shows titles, and `WorkItemService.createWorkItem` skips the reference when `projectKey == nil`.
Reference numbers still only go up for projects that have keys.

### Notes contain notes

Add `.children` and `.appearance` to `ItemKind.note.supportedFields`, and
`ItemKind.note.canContain(.note)`. A notebook is a note that happens to hold other notes.

**Why not a `.notebook` kind.** It costs a kind, a row in `canContain`, a module mapping, an icon, an
empty state and a migration path for anybody who wants to convert one to the other — to buy a
container that is strictly less capable than a note, because it cannot hold a paragraph explaining
what is in it. The app's founding decision is one node type; this is that decision applied where it
has not been yet.

**What it costs, honestly.** Clicking a notebook opens a document rather than a list. Apple Notes
users expect a folder to be a folder. The mitigation is that a note with children draws as a page
*with its children listed beneath the prose*, which is what Notion does and what makes the model
legible. If it turns out to read badly, the reversal is additive — a `.notebook` kind can be
introduced later without touching anything built here.

Then `NotePageView.createPage` sets `parentID: item.id` rather than `item.parent?.id`, and nesting
becomes true: archive, trash, restore and export all follow the page without new machinery. Existing
"nested" pages are siblings with a `.page` object pointing at them; a one-shot migration reparents
any note referenced by exactly one `.page` piece whose current parent is that piece's owner's parent.
A page referenced from two notes is left alone and reported.

### Archive is a place

Two changes, and the second is the one the request turns on:

- **Archive groups by container.** An archived project draws as a section header with its contents
  beneath it, collapsed; items archived on their own fall into a trailing ungrouped section.
  Opening an archived project opens the ordinary workspace with an "Archived" banner carrying
  **Unarchive**, so a trip stays readable as a trip.
- **Search finds archived things without being asked.** Archived results are no longer excluded;
  they are collected into a separate, collapsed **Archived** group below the live results, each row
  carrying an archive glyph. `is:archived` continues to mean "only archived", which is now a
  narrowing rather than a permission.

The blast radius here is the part to be careful about: `SearchService` also feeds the command palette
and the inline results. The exclusion moves out of `matchesStructuralFilters` and into an explicit
`SearchQuery.archivePolicy` (`.exclude` / `.separate` / `.only`), so each caller states what it
wants and no surface changes by accident. Capture completion reads `titleSuggestions` off the index
directly and is untouched.

## Phases

Each is one commit and ends green — `swift build`, `swift test`, and `Scripts/xctest.sh build` for
both apps. Phases 1–4 deliver the trip; 5–6 deliver the notes module; 7 is iOS.

1. **Containment and keys.** `project.canContain(.note, .bookmark)`; `ItemValidator` cases;
   `createProject` stops inventing keys; `WorkItemService` skips references for keyless projects.
   Verify `descendantWork`, `taskProgress` and every count still ignore prose. *Smallest useful
   stopping point: after this, a note can live in the trip and archives with it.*
2. **The Notes view.** `ProjectViewKind.notes`, its configuration, and `ProjectNotesView` — contained
   notes with a snippet and date, linked notes beneath, "New Note" filing into the project.
3. **Templates choose views; the Trip template.** `featuredViews` becomes the created set; "Add View"
   offers the rest. `ProjectTemplate.trip`: stages **Ideas** (backlog) ▸ **To book** (active) ▸
   **Booked** (done); views list, calendar, notes, board. Seeded nothing — a template that guesses
   your itinerary is a template you delete.
4. **Archive as a place.** Grouped archive list, the archived-project banner and Unarchive,
   `SearchQuery.archivePolicy` with the three callers named explicitly, and the Archived group in
   results.
5. **Notes contain notes.** `supportedFields`, `canContain`, `createPage` reparenting, the
   sibling→child migration with its two-referrer refusal, and the children list on a page.
6. **The notes sidebar tree.** Top-level notes with children draw as an expandable tree above the
   kind rows, with New Note / New Page inside, drag to reparent, and the count of what is inside.
   Kind rows stay — they are a lens over the tree, not a competitor to it.
7. **iOS.** 7a: stop the flattening — a note whose document contains objects the projection cannot
   carry opens read-only with a "Rich note — edit on Mac" affordance, rather than silently losing
   them. 7b (separate, larger, not costed here): a `UITextView` sibling of `NoteProseTextView` so
   the phone edits prose properly. **7a is not optional** — it is a data-loss fix and should land
   with phase 1 if 7b slips.

## Tests

- **Core** — `canContain` totality for the new pairs; a note under a project counts as neither work
  nor progress; template `featuredViews` produce exactly those views; `archivePolicy` round-trips
  through a saved search's query string.
- **Persistence** — archiving a project archives contained notes and leaves linked ones alone;
  restoring restores the cascade; a keyless project creates work with no reference and does not
  advance `nextReferenceNumber`; the nested-page migration reparents a single-referrer page and
  refuses a two-referrer one.
- **Features** — the trip journey end to end: create from the Trip template, add three reminders and
  two notes, complete them, archive, find one of the notes by a word in its body **without typing a
  token**, open the archived project, unarchive it.
- **Search** — the three policies against one fixture, and one test per caller pinning which policy
  it passes, so a future surface cannot inherit the wrong default silently.

The journey test is the one that matters: every gap in this document is a step in it, and a passing
run is the request satisfied.

## Deliberately not in this plan

- **Per-project sharing, collaborators, or assignees on a trip.** The machinery exists; a trip for
  one person needs none of it.
- **Travel-specific fields** — flight numbers, confirmation codes, itinerary import. `userMetadata`
  has held custom fields since v1 and `CustomFieldDefinition` names them per project. If a trip
  wants a "Confirmation" field it can have one without a schema change, and until somebody has
  planned three trips we do not know which fields recur.
- **A grid or gallery note browser.** Snippets and dates first; whether anybody wants thumbnails is
  a question to answer after the tree exists.
- **Note locking, note sharing, and hand-off to Apple Notes.**
- **Reordering pages by drag.** Still needs a `DropDelegate`, still recorded as a trap in
  [31-notes-editor-spec.md](31-notes-editor-spec.md), still true.

## Risks

- **The search change is the one with reach.** Three surfaces read `SearchService` and one reads the
  index directly. The policy enum makes each choice explicit, but the review should confirm the call
  sites by grep rather than by memory.
- **`ItemValidator.conform(_:to:)` must report the loss** when a note is converted to a kind that
  cannot hold children, or a converted notebook orphans its pages silently. Same rule the bug→task
  conversion already follows.
- **The iPad reuses phone views.** Before removing or renaming anything in `ElephruitiOS/`, check
  `ElephruitiOS/Pad/` in up-to-date `main` — `git grep <name> origin/main`. This has broken the
  build twice.
- **Nothing here has been reviewed on screen.** The projects workspace shipped without a single
  visual review, and it shows in the record. Phases 2, 4 and 6 each change what a screen looks like
  and each should be looked at before the next one starts.
