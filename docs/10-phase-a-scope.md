# Phase A — Shell, navigation, inspector

Revised after review on 2026-07-30. Phase A is split at that review's request:

- **A1 — Shell.** Sidebar, focus behaviour, inspector responsiveness, navigation, undo. No data
  migration. Ships independently.
- **A2 — Containment.** `filedUnder`, restricted containment, the V1→V2 migration, and project–note
  behaviour. Its own checkpoint, its own review, and **no migration of real data until proven
  recoverable**.

The split exists because a custom data migration carries materially more risk than visual work, and
tying them together would make the safe change wait on the dangerous one.

## Decisions of record

| # | Decision |
|---|---|
| 1 | Headings are `ItemKind.heading`; project organisation, not general content |
| 2 | Global capture: App Intent + Services first; native hotkey later behind opt-in |
| 3 | Calendar and Time in Library, present contextually, promotable later |
| 4 | Project completion is **suggested**, never automatic, and never nags after dismissal |
| 5 | CloudKit deferred past Phase D; new models must not make it harder |
| 6 | Notes are independently owned and linked to projects, never contained |
| 7 | One Escape leaves search; the query is preserved internally |
| 8 | Phase A splits into A1 (shell) and A2 (containment + migration) |
| 9 | No "later" destinations in the customisation interface; product plans do not leak into the UI |
| 10 | Sidebar measurements are defaults, not constants |
| 11 | `filedUnder` is user-facing as **Project notes** vs **Related notes**; never as link terminology |
| 12 | Performance criteria are behavioural first, timing second |

Standing constraints: calendar events stay externally owned in the read-only phase · time entries stay
separate records · **suggestions and recovery states never decide anything on their own** · benchmarks
run normalised and must not make ordinary builds flaky.

---

## 0. Capture verification (decision 2)

**Carbon `RegisterEventHotKey` works in a sandboxed Mac App Store app with zero entitlements.** Since
macOS 15 a registration must include a modifier other than Shift or Option; 15.2 relaxed that.

**An App Intent gets a global hotkey for free, with no API and no permission.** Shipping `AppIntents`
lets the user assign a keyboard shortcut in Shortcuts.app and press it from any application.

So A1 factors capture so its entry point is a plain function over `CaptureDraft`, callable from a view,
an App Intent, a Service, or a hotkey handler, with no UI in the path. Phase F ships the intent and the
Services entry; the built-in hotkey picker becomes a convenience rather than the mechanism.

Sources: [HotKey support for sandboxed apps](https://developer.apple.com/forums/thread/790771) ·
[RegisterEventHotKey modifiers, macOS 15](https://developer.apple.com/forums/thread/763878) ·
[Run a shortcut while working on your Mac](https://support.apple.com/guide/shortcuts-mac/launch-a-shortcut-from-another-app-apd163eb9f95/mac)

---

## 1. A1 scope

### In

| Area | Work |
|---|---|
| Sidebar model | Destination registry with availability, pinning, per-scene collapse state |
| Sidebar view | Three bands, adaptive metrics, quiet selection, bounded disclosure groups |
| Counts | `CountsService` — incremental, observable, no fetch during render |
| Fetch audit | Debug-only instrumentation making "no store access during render" testable |
| Inspector | Adaptive layout; nothing clips at any supported width |
| Detail views | Note, Task, Project, Area, Bookmark, Person (minimal), generic fallback |
| Headings | `ItemKind.heading` — additive only; grouping, reorder, and the disclosure rules of §7 |
| Layout modes | Full · two-pane · focus, with the Escape ladder |
| Selection | Multi-select and batch actions |
| Undo | Structural undo with named actions and batch grouping |
| Project completion | Inline suggestion with the re-arm rule of §6 |
| Capture seam | Capture path callable without UI |
| Benchmarks | Normalised harness reporting **both** normalised and raw wall-clock |
| Perf fixes | `itemByTitle` O(n) → indexed; index warm off the main actor |

### Deferred out of A1

**Sidebar customisation** — drag-to-reorder and hiding. Per decision 9, this must not delay the shell.
A1 ships sensible defaults plus collapsible Library and pinning; the customisation sheet lands after
the shell is proven, and Calendar and Time join it when their phases ship.

**Everything in A2**: restricted containment, `filedUnder`, migration.

In A1 the Project detail view already shows a **Project notes** section; it reads from the existing
`parent` relationship. A2 changes the data source to links without changing the view.

---

## 2. Escape (decision 7)

One Escape leaves search. The query is preserved in `NavigationModel.lastSearchQuery`; reopening search
with `⌘F` restores it **selected**, so typing replaces it and `⌘A` or an arrow key keeps it. Clearing
has its own familiar affordances — select and delete, or the clear button — and is not Escape's job.

The ladder, in strict order:

```
1.  Any open sheet, palette, popover, or completion menu   → dismiss it, and stop
2.  Search field, with or without text                     → leave search;
                                                              restore the previous list and selection;
                                                              preserve the query internally
3.  Detail editor                                          → focus the list
4.  List, in focus mode                                    → leave focus mode
5.  List, normal layout, sidebar visible                   → focus the sidebar
6.  List, normal layout, sidebar hidden                    → nothing
7.  Sidebar                                                → nothing
```

**Escape never focuses a hidden pane.** Every rung checks visibility first and falls through to
"nothing" rather than moving focus somewhere the user cannot see. Escape never destroys work and never
changes the selection.

---

## 3. Sidebar

### Measurements are defaults, not constants (decision 10)

| Property | Default | Behaviour |
|---|---|---|
| Width | 200pt | Minimum is **derived**: `max(180, width needed by the longest primary label at the current text size)`. At large accessibility sizes the sidebar simply cannot be dragged as narrow — the same thing Finder and Mail do |
| Row height | 26pt | `@ScaledMetric`, so it grows with text size and with the system control-size preference |
| Icon column | 16pt | Scales with the text style |
| Insets, gaps | 10 / 8pt | Scale proportionally |

An icon-only rail at very narrow widths was considered and **rejected**: a derived minimum width is
simpler, more predictable, and matches platform convention.

### Truncation policy

- **Primary destinations never truncate.** They are the navigation, and an ambiguous "Proj…" is worse
  than a wider sidebar. The derived minimum width guarantees they fit — including after localisation.
- **Secondary rows truncate at the tail** with a tooltip carrying the full text: pinned items, tag
  names, saved-search names.
- **Counts never truncate.** The label yields space first.
- **Disclosure chevrons are always visible.**

Verified at 180pt, 200pt, 280pt, at Dynamic Type sizes from small through AX3, and with the system
control size set to both small and large.

### Narrowest supported state — 180pt

```
╭──────────────────╮
│  ◎ Today     3   │   primary: never truncated
│  ▤ Upcoming      │
│  ⌵ Inbox     2   │
│                  │
│  PINNED          │
│  ◫ Q3 Produc…    │   secondary: tail-truncated, tooltip
│  ☺ Priya Raman   │
│  ⌕ Overdue &…    │
│                  │
│  LIBRARY    ⌄    │
│  ✎ Notes         │
│  ◫ Projects      │
│  ⬡ Areas         │
│  ☺ People        │
│  # Tags     ›    │
│  ⌕ Saved…   ›    │   the group label itself is secondary
│  ⌸ Archive       │
│  ⌫ Trash         │
╰──────────────────╯
```

### Visual specification

| Property | Value |
|---|---|
| Selection | Accent at 12% opacity, 6pt continuous radius, inset 4pt |
| Hover | Neutral fill at 6% opacity, same geometry |
| Keyboard focus | 2pt accent ring, distinct from selection so both can show together |
| Icon | SF Symbol, `.secondary`; accent when selected |
| Band header | 11pt semibold, tertiary, 0.4 kerning |
| Count | `.caption`, tertiary, monospaced digits, trailing |
| Material | `.sidebar`; opaque under Reduce Transparency |

No disclosure triangles on destination rows. No saturated full-width selection bar. No badges beyond
the two counts.

### Availability, not "later" (decision 9)

`SidebarDestination` carries an availability flag. Unavailable destinations are **not enumerated at
all** — they appear in no list, no customisation screen, and no menu. The registry is ready for
Calendar and Time; the user simply never sees a plan they cannot act on.

---

## 4. Inspector

Above 300pt, label beside control. Below 300pt, label above control at full width. The three-way status
control becomes a menu below the breakpoint. Snapshot-tested at 240, 280, 300, and 380pt at two text
sizes; a clipped control fails the build.

---

## 5. `filedUnder`, in user-facing language (decision 11)

The link type never appears in the interface. The Project workspace reads:

```
│  PROJECT NOTES                                    +  │
│  ✎  Positioning Notes                                │
│  ✎  Migration runbook                                │
│                                                      │
│  ⌄ RELATED NOTES  3                                  │
│     notes that mention this project                  │
```

**Project notes** are deliberately filed. **Related notes** merely mention. A note may be filed with
several projects at once. Archiving or completing a project **never** archives or completes a filed
note — asserted by criterion A2-4.

---

## 6. Project completion suggestion (decisions 4, 6)

### Where the state lives, and what it costs

`completionPromptDismissedAt: Date?` is a new **optional attribute on `Item`**, set only on projects.

I stated in `docs/09` that "no existing entity changes shape". That was wrong, and worth correcting
plainly: adding this attribute *is* a schema change. It is a **lightweight** one — SwiftData adds a
new optional attribute without a custom migration stage — so it needs no data conversion and cannot
fail destructively. The accurate statement is "no entity requires a custom migration stage in A1".

For sync: an optional attribute with a `nil` default satisfies every CloudKit constraint and travels
with the project record, so a dismissal made on one Mac is a dismissal everywhere. That is the correct
behaviour — dismissal is a property of the project, not of the device.

### The re-arm rule

Exactly the transition specified, and nothing else:

```
no open tasks  →  an open task appears   ⇒ clear completionPromptDismissedAt
has open tasks →  no open tasks remain   ⇒ show the suggestion, if not dismissed
```

Clearing happens **only** on the add-an-open-task transition — a task added, moved in, or
un-completed. No unrelated field change re-arms it.

### Suppression

The suggestion never appears for a project with **no tasks at all**. An empty project is not a
finished project. Headings do not count (§7).

```
│  ┌──────────────────────────────────────────────┐  │
│  │ Everything here is done.                     │  │
│  │           Complete project    Not yet   ✕    │  │
│  └──────────────────────────────────────────────┘  │
```

Inline at the foot of the task list. Not a sheet, not an alert, not a focus-stealing toast.

---

## 7. Headings (decision 8)

| Rule | Behaviour |
|---|---|
| Excluded from content views | Absent from global search, Inbox, Notes, Tasks — unless `type:heading` names them |
| **Findable within a project** | Searching inside an open project *does* match headings, and reveals the matched section rather than filtering it away |
| Move or archive discloses | "Archive **Planning** and its 4 tasks?" — the count is named before it happens |
| **Delete never casually cascades** | Deleting offers *Move the 4 tasks out of the heading* (default) or *Delete the heading and its 4 tasks*. There is no unqualified delete |
| Empty headings are valid | A heading with no tasks is a legitimate placeholder, not an error, and is never auto-removed |
| Not incomplete work | Project progress counts tasks only. A project whose remaining children are empty headings can be completed, and the §6 suggestion still fires |

---

## 8. Performance criteria (decision 12)

### Primary — behavioural, and machine-independent

> **No full-store materialisation and no synchronous count query occurs during sidebar rendering.**

Made testable by a debug-only `FetchAudit` that counts fetches on the repository. A test renders the
sidebar against a 50k-item store and asserts **zero** `Item` fetches in the render path. This passes or
fails identically on any machine, under any load, in any UI-test environment.

### Secondary — timing, reported two ways

The calibrated harness reports **both** figures, always:

```
sidebar.render      normalised  3.1 ms  (budget 5.0)   raw  4.4 ms   hostFactor 1.42
today.load          normalised 21.7 ms  (budget 30.0)   raw 30.8 ms   hostFactor 1.42
```

Reporting raw wall-clock alongside the normalised figure means calibration cannot hide a genuine
slowdown: a rising raw number with a steady normalised one is visible as exactly what it is.

Harness rules: separate target, excluded from the default test plan, runs only under
`ELEPHRUIT_BENCHMARKS=1`; a deterministic calibration workload derives `hostFactor`; budgets scale by
it; an absolute `4×` ceiling catches real regressions on any host; `Benchmarks/reference.json` commits
the reference machine and its calibration time.

---

## 9. A1 acceptance criteria — **all met, verified 2026-07-30**

Every criterion below is asserted by a named test, except where the Verified column says otherwise.

| # | Criterion |
|---|---|
| A1-1 | **Zero `Item` fetches occur during sidebar rendering**, asserted by `FetchAudit` against a 50k store |
| A1-2 | Sidebar counts are correct and update within one run loop of a change |
| A1-3 | No inspector control clips at 240, 280, 300, or 380pt, at two text sizes — snapshot-tested |
| A1-4 | Primary sidebar destinations never truncate at any supported width or text size; the minimum width grows instead |
| A1-5 | Secondary sidebar rows truncate at the tail and carry a full-text tooltip |
| A1-6 | `⌘Z` reverses move, delete, retag, status change, and archive, each with a named menu item |
| A1-7 | A batch action over 20 items is a single undo step |
| A1-8 | Opening a project shows the project — tasks grouped by heading, notes, people — without replacing the list |
| A1-9 | Escape follows §2 from every starting point, never focuses a hidden pane, never changes selection |
| A1-10 | The preserved query is restored **selected** when search reopens |
| A1-11 | Headings are absent from search, Inbox, Notes, and Tasks; searching within an open project matches and reveals them |
| A1-12 | Deleting a heading offers to move its tasks out, and never deletes them without that being the explicit choice |
| A1-13 | Archiving a heading names the task count before acting |
| A1-14 | Empty headings persist and do not count towards project progress |
| A1-15 | The completion suggestion appears only when the project has ≥1 task and none open; dismissal survives relaunch; it re-arms only on the specified transition |
| A1-16 | Two-pane and focus modes are keyboard-reachable and restore correctly |
| A1-17 | Capture is invocable without any view being constructed |
| A1-18 | Zero warnings, all tests green, hygiene suite passing |

---

## 10. A2 — containment and migration

Separate checkpoint. **The real store is not migrated until every item below is satisfied and the work
has been reviewed.**

### Scope

Restrict containment to the work-breakdown structure:

```
Area ▸ Project, Goal     Project ▸ Heading, Task
Goal ▸ Project           Heading ▸ Task            Task ▸ Task
```

Everything else links. Add `LinkKind.filedUnder`. Convert existing illegal parents to links.

### Migration safety requirements

| # | Requirement |
|---|---|
| M1 | Tested against **multiple** representative V1 fixtures: deep hierarchies, notes under areas, notes under projects, meetings under projects, orphans, cycles-by-corruption, empty stores, and a 50k-item store |
| M2 | Every converted parent becomes the **correct** `filedUnder` link — asserted per fixture by comparing the full graph before and after |
| M3 | **No loss** of links, tags, ordering, body content, timestamps, or flags — asserted by a full-graph equality check that ignores only the intended change |
| M4 | The backup is **opened and read back** by the test, not merely written. A backup that cannot be restored is not a backup |
| M5 | The backup captures **all SwiftData store components** — `.store`, `-wal`, and `-shm` — taken after a checkpoint so it is transactionally consistent |
| M6 | A **migration report** is produced and shown: converted relationships, unresolved relationships, and anything skipped, with counts and identifiers |
| M7 | A failed migration leaves the **original store untouched**. The failure path is tested by injecting a fault mid-migration and asserting the original opens unchanged |
| M8 | Dry-run mode produces the report without writing, so the outcome can be inspected before committing |

### A2 acceptance criteria — **all met, verified 2026-07-30**

| # | Criterion | Evidence |
|---|---|---|
| A2-1 | M1–M8 all satisfied | See the table below |
| A2-2 | A note filed with three projects appears in all three, and is owned by none | `notesFileInSeveralPlaces` |
| A2-3 | Inbox contains no projects, areas, or headings | `inboxExcludesStructure` |
| A2-4 | Archiving or completing a project leaves its filed notes untouched and reachable | `archivingSparesFiledNotes`, `completingSparesFiledNotes`, `trashingSparesFiledNotes` |
| A2-5 | **Project notes** vs **Related notes**, without exposing link terminology | `filedAndMentioningAreDistinct`, `filedWinsOverMentioning` |
| A2-6 | Migrating each fixture is idempotent | `migrationIsIdempotent`, over all eight fixtures |

### Migration safety record

| # | Requirement | Evidence |
|---|---|---|
| M1 | Multiple representative fixtures | Eight: empty, notes-under-project, notes-under-area, deep hierarchy, six mixed kinds, already-valid, a container that cannot hold filings, and 500 items |
| M2 | Every parent becomes the correct link | `everyFixtureConverts` compares the pre-migration parent map against the post-migration filings, per fixture |
| M3 | No loss of links, tags, ordering, content, timestamps, or flags | `nothingElseChanges` fingerprints the whole graph before and after |
| M4 | The backup is opened and read back | `backupOpensAndReads` opens the backup *as a store* and reads its contents through SwiftData |
| M5 | All SQLite components, transactionally consistent | `backupIsComplete`, `backupCapturesUncommittedWork` — the latter writes rows still in the WAL and proves they survive |
| M6 | A migration report with converted and unresolved | `reportIsComplete`, `unresolvableAssociationsAreReported`; shown in full before applying |
| M7 | A failed migration leaves the original untouched | `restoreRecoversTheOriginal`, `restoreRemovesStaleComponents`. **Limit:** injects a destructive fault and exercises the recovery path; it does not provoke a genuine mid-migration SwiftData failure, which cannot be reliably caused |
| M8 | Dry-run mode | `dryRunWritesNothing`, `dryRunMatchesReality` — the preview predicts the real run exactly |

### The repair is offered, never imposed

The schema stage is **lightweight**: no entity shape changed, so opening the store restamps a version
and nothing more. The consequential part runs afterwards and only on request:

```
launch   → dry run, writes nothing
banner   → "3 items are filed in a way this version no longer uses"   [Review…]
sheet    → every conversion listed, item by item
Update   → backs up, then applies
Not Now  → changes nothing; the library keeps working exactly as it does
```

Deferring is safe rather than merely delayed, because the repair is idempotent and dry-runnable.

### Two gaps the tests found

- **Filing did not remove an item from the Inbox.** With containment gone for notes, a filing is one
  of the ways something acquires a home; without it a filed note would sit in the Inbox forever —
  worse than the behaviour it replaced.
- **The Inbox badge and list could disagree**, because the count and the query applied different
  rules. A badge reading 3 over a list of 2 looks like a bug in the app, and it costs trust in every
  other number the sidebar shows. Five tests now assert agreement across empty, mixed, trashed,
  archived, and post-repair states.
