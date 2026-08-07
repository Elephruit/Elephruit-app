# 41 — Containers and notes, on the web

- **Status:** Phases 1–3 and 7 built (`containers`, the container page, archive, search). Phases
  4–6 — the notes module — outstanding.
- **Date:** 2026-08-06
- **Branch:** `claude/trip-planning-reminders-notes-0b4b1d`
- **Target:** `web/` only. Nothing here touches Swift, the Xcode targets, or the native apps.

## The question

> "Projects? Folders? Work? I'm not sure what the right thing would be — we're planning a trip to
> Chicago and I want reminders for it (book a hotel, buy tickets for the Pokémon exhibit at the Field
> Museum), tracked together, and archived when the trip is over. Still searchable, but archived. To
> go with it we need a robust notes module, think Evernote / Apple Notes."

## The answer: a container, and the uncertainty was correct

A project and a folder are **the same shape**. Both are a named thing that other things live in. The
only difference that earns its keep is whether it *ends*:

- a **project** has dates, a sense of done, and an archive waiting for it — a trip, a house move, a
  conference;
- a **folder** does not — Travel, Recipes, Work.

So one `containers` collection with `kind: 'project' | 'folder'`, folders nesting inside folders, and
projects living inside them. Chicago is:

```
folder "Travel"  ▸  project "Chicago, October"  ▸  reminders + notes
```

Being unsure which word applied was the right instinct: the answer is that the distinction is one
field, and inventing two collections to carry it would mean writing every query, every rule test and
every archive path twice to express one boolean.

### Why not tags

A tag has no dates, no end, and nothing to archive. "Archive the Chicago tag" has no meaning — either
it hides the label, in which case the reminders leak back into Overdue, or it hides the reminders, in
which case the tag is a container wearing a smaller word. The trip needs an owner, not a label.

### Why not generalize `people` into `subjects`

Tempting, and the wrong size. The spike's own D1 says Firestore's unit of query is the collection,
and its single composite index — interactions by `participantIDs` and date — *is* the person
timeline. Making a trip a kind of subject means re-keying `participantIDs`, `personIDs` and that
index for a container that will never hold an interaction. Containers get their own collection and
their own foreign key, and people are left exactly as they are.

## What `web/` actually is today

Stated precisely, because the native apps share none of it and the last version of this plan was
written against them by mistake.

- React 19 + TypeScript + Vite, Firebase (Auth, Firestore, Functions), emulator-first.
- Seven collections, all under `users/{uid}/`: `people`, `interactions`, `relationships`,
  `observations`, `reminders`, `sources`, `memories`
  ([writePlan.ts:6](../web/src/domain/writePlan.ts)).
- **One write path.** Every surface builds a `WritePlan` in the pure-TypeScript domain layer and
  `applyPlan()` commits it as one atomic batch. A hygiene test fails if `src/domain/` imports
  Firebase or the Anthropic SDK.
- Four destinations: Feed, People, Follow-ups, Settings.
- **Reminders already exist and are good** — `startAt` / `dueAt` / `isSomeday`, five buckets, the
  load-bearing rule that only a deadline can make something late
  ([reminders.ts](../web/src/domain/reminders.ts)). They carry `personIDs` and a source interaction.
- Interactions are **append-only** — no edit, no delete — because the `lastContactAt` cache's honesty
  depends on it (D3).

And what it does not have, all four of which this plan is about:

- **No container of any kind.** Everything hangs off a person. A trip is the first subject in this
  app that is not a person.
- **No notes.** Not rich, not plain. `observations` are dated facts about people;
  `interaction.discussion` is a plain-text account of one conversation. Neither is a note.
- **No archive.** The word appears nowhere in the domain.
- **No search.** The command palette matches people's names and destination labels and says so in its
  own header comment — *"Deliberately not full-text search"*
  ([CommandPalette.tsx:3](../web/src/ui/components/CommandPalette.tsx)).

That last one matters for how the request is read. "Still searchable, but archived" is not a flag to
flip here. On the web app, search does not exist yet, so archiving something today makes it *less*
findable than the nothing it is now.

## Four things the web app makes true that the native plan did not have to face

These are the decisions that are expensive to retrofit, so they are made here rather than discovered
in phase 5.

### 1. A note's content must not live in the note's document

Firestore's web SDK has no field projection — `select()` is Admin-only. A notes list that subscribes
to `notes` downloads every note's full rich content to draw a list of titles. So:

- `notes/{id}` — metadata plus **`bodyText`**, the plain-text projection, capped (say 2 KB) for rows,
  excerpts and search.
- `notes/{id}/content/document` — the rich run-list, read only when a note opens, written on save.

The projection is not an optimization, it is the same idea ADR 0006 already settled for the Mac:
`Item.body` is the derived plain text that feeds search and export while the rich payload sits beside
it. Here it also decides how much the list costs to draw.

### 2. Documents are capped at 1 MiB, so a note has a ceiling

Enforced at the domain layer with a real error rather than discovered as a failed write. A long note
is fine; a note with a pasted table of a thousand rows is not, and refusing loudly beats a save that
silently did not happen.

### 3. Images in notes are a new posture, not a feature

The app stores **no file bytes anywhere**. Dossier import extracts text and discards the file, and
`SourceDocument.rawFileRetained` is a literal `false` — *"a schema-level promise, not a setting"*
([sources.ts](../web/src/domain/sources.ts)). Firebase Storage is not configured, not in the rules,
and not in the runbook.

So notes ship **without embedded images**, and that is a stated boundary rather than an oversight. If
images are wanted later they need Storage, a rules block, a quota story, and an amendment to the
retention promise — which is a decision about what this app is, not a phase of this plan.

### 4. New collections need no rules change, and that is a reason to write a rules test

The owner-only wildcard on `users/{uid}/{collectionName}/{docID}` already covers `containers` and
`notes` the moment they exist. That is convenient and slightly dangerous: nothing will tell you if a
collection lands in the wrong place. `tests/rules` gets a case per new collection, and both go into
`COLLECTIONS` so the write plan's type system knows them.

## The data

```ts
// containers
{
  id, kind: 'project' | 'folder',
  title, summary: string | null,
  icon: string | null, color: string | null,
  parentID: string | null,          // folders nest; a project sits in a folder
  startAt: Date | null,             // projects only
  dueAt: Date | null,               // projects only
  status: 'active' | 'completed',   // projects only; folders are always active
  archivedAt: Date | null,
  createdAt, updatedAt,
}

// notes
{
  id, title,
  bodyText: string,                 // plain projection, capped, feeds lists + search
  containerID: string | null,
  personIDs: string[],              // a note about Maya shows on Maya's page
  pinnedAt: Date | null,
  archivedAt: Date | null,
  createdAt, updatedAt,
}
// notes/{id}/content/document — { version: 1, pieces: [...] }, ADR 0006's shape in TypeScript

// reminders — one added field, nullable, existing rows unaffected
+ containerID: string | null
```

`reminders.personIDs` stays and stays optional-in-practice: "book a hotel" is owed to nobody, which
the array already permits. A reminder may have both — "ask Dana for the museum code" belongs to the
trip *and* to Dana.

### The rich-text format is the Mac's

`notes/{id}/content/document` implements **ADR 0006** — a versioned run-list, allow-listed attributes,
plain text as the derived projection — in TypeScript rather than inventing a second format. The spike
already kept client-generated UUIDs compatible with the Mac's `ArchiveFormat` so an importer stays a
step rather than a re-keying project; the note format is the same bet for the same price, which is
approximately zero if it is made now and considerable if it is made after a few hundred notes exist.

### The editor: Lexical

React 19, MIT, and its editor state is already a serializable node tree, which is what a custom
persisted format needs. ProseMirror's schema is arguably the better model and its React binding is
the heavier one; hand-rolled `contenteditable` is how people find out what a text editor costs.

**This is a recommendation with a gate, not an assertion.** Phase 4 opens with a one-day bake-off
whose pass condition is concrete: round-trip a document containing every ADR 0006 piece kind through
the editor and back, and assert equality — including the empty document and a trailing empty
paragraph, which is where the Mac's conversion tests found their bugs. If Lexical cannot, TipTap gets
the same day.

## Archive, and the rule that is not obvious

`archivedAt` on containers and notes. Archiving a container archives what it holds, in the same write
plan, and unarchiving restores it — the batch is what makes that safe, and it is the reason the one
write path is worth the discipline.

The non-obvious part is what happens to a reminder that is still open when the trip ends. It must not
sit in Overdue forever, and it must not be quietly marked done — nobody bought those tickets.

**An archived container's reminders leave the buckets without changing status.** `bucketFor` is
unchanged (it is pure and correct); the *bucketing pass* takes the set of archived container IDs and
drops their reminders before grouping. The container page still lists them, under **Left open** —
which is the truth, and occasionally the interesting part of a finished trip.

## Search

Built here because "still searchable" has no meaning until it exists.

Firestore has no full-text search, and the honest options are a third-party index or doing it on the
client. At this app's scale the answer is the client: `reminders` and `observations` already subscribe
whole-collection and the scope document names that posture as a known ceiling. `notes` joins them —
metadata only, which is what the content split in decision 1 buys.

- The command palette grows from names-and-destinations into search over people, containers, notes
  (`title` + `bodyText`), reminders, and interaction summaries.
- **Archived results appear by default**, in a separate group below the live ones, each row carrying
  an archive glyph. That is the request, read literally: archiving moves something out of the way of
  today without moving it out of reach.
- Interactions are the one collection the feed limits to 100, so search subscribes to its own
  unlimited query or accepts a stated ceiling. Say which in the code.
- The ceiling is written down next to the code, alongside the existing reminders note, so the first
  person to hit it finds a sentence instead of a mystery.

## Phases

Each is one commit, and each ends with `npm test`, `npm run lint`, `npm run build` green plus a
browser walk against seeded emulators. Phases 1–3 deliver the trip; 4–6 the notes module; 7 search.

1. **Containers.** ✅ Built. The collection, `container.ts` with its write planners, the
   `COLLECTIONS` entry, the rules test, and `reminders.containerID`.
2. **The container page.** ✅ Built, and merged into phase 1's commit — a Projects list whose rows
   navigate to a route that does not exist yet is not a coherent stopping point, so the phase
   boundary was wrong. Reminders in the five buckets, dates, `2 of 4 done`, and a filing control on
   the reminder editor. Follow-ups rows gained a tinted chip naming the container instead of the
   planned group-by, which turned out to answer the same question in one line.
3. **Archive.** ✅ Built. `archivedAt`, the cascade in one plan, the bucket exclusion,
   **Left open**, an Active/Archived toggle, and Unarchive. *The trip request is complete here.*
   Phase 7 landed with it rather than the planned stopgap, because a real search was cheaper than a
   narrow title match plus its later replacement.
4. **Notes: format and storage.** The bake-off and its round-trip test; ADR 0006 in TypeScript; the
   metadata/content split; the 1 MiB guard; the plain-text projection; a working editor with headings,
   lists, checklists, code, quote, links, and inline marks. Notes live in containers and stand alone.
5. **Notes: the module.** The list with excerpt, date and pin; sort; a notes tree in the rail with
   folders; move; duplicate; delete to a recoverable state; keyboard-first new-note.
6. **Notes meet people.** `personIDs` on a note, notes on the person page, and the timeline filter
   fix: **`notes` currently means `observation`**
   ([timeline.ts:199](../web/src/domain/timeline.ts)) — that chip becomes **Facts**, and **Notes**
   becomes notes. Doing this in the same commit as real notes is what stops a week of the word meaning
   two things.
7. **Search.** ✅ Built, out of order — see phase 3. `domain/search.ts`, archived results in their
   own group, and `useLiveReminders` after building it found the Feed counting an archived trip's
   work.

## Verification

Per the house workflow for this app: seed fresh emulators, drive the browser by script rather than by
click, and stub `fetch` for anything AI-shaped.

- **Domain tests** (vitest, pure): container nesting rejects cycles; a project cannot contain a
  folder; archiving plans exactly one batch and restoring is its inverse; archived containers' reminders
  leave every bucket while keeping `status: 'open'`; the note document round-trips every piece kind,
  the empty document, and the trailing empty paragraph; the 1 MiB guard refuses before writing;
  `bodyText` is always the current projection.
- **Rules tests**: `containers` and `notes` are owner-only, and a second account is refused both —
  the wildcard already implies it, which is exactly why it needs pinning.
- **Browser walk, scripted**: create Travel, create Chicago inside it, add four reminders and two
  notes, complete two, archive the trip, confirm Follow-ups is clean, search "Pokémon" and find the
  ticket reminder under Archived, open the archived trip, unarchive, confirm the buckets come back.
  That walk is the request, start to finish.
- `web/docs/visual-qa.md`'s four viewports at every phase that changes a screen.

## Not in this plan

- **Embedded images and file attachments in notes.** Decision 3 — a new retention posture, not a
  phase.
- **Sharing, collaboration, or multi-user containers.**
- **Sync with the Mac app's store.** The format compatibility above is so an importer stays cheap; the
  importer itself is its own piece of work.
- **Editing or deleting interactions.** Still load-bearing for `lastContactAt` (D3), still out.
- **Server-side search.** Revisit when the client ceiling is actually reached, with a number.
- **Recurring reminders, templates for trips, itinerary import.** Not until a second trip has been
  planned and the repeated parts are known rather than guessed.

## Risks

- **`notes` is the first collection with a subcollection.** Deleting a note must delete
  `content/document` explicitly — Firestore does not cascade, and an orphaned subcollection is
  invisible in the console until it is not.
- **Whole-collection subscriptions now include notes.** Metadata only, but `bodyText` is capped for
  this reason and the cap should be enforced on write, not trusted.
- **The timeline filter rename touches a shipped label.** It is a rename of what the user sees; do it
  once, in phase 6, with the tests, not gradually.
- **`firestore.indexes.json` must ship any new composite index from day one** — the emulator never
  complains about a missing index and production does. Notes by container and date is the likely one.
- **The write-plan batch caps at 500 operations.** Archiving a container with hundreds of children
  would exceed it. `assertPlanFits` will refuse loudly, which is correct and is also a bug report
  waiting to happen; chunking is the fix if a real trip ever gets that big.
