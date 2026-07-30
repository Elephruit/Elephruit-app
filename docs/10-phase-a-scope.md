# Phase A — Shell, navigation, inspector

Agreed scope, interaction model, and acceptance criteria. No new domains: this is the phase that
fixes how the app *feels* before anything is added to it.

Decisions recorded from review, 2026-07-30:

| # | Decision |
|---|---|
| 1 | Headings are `ItemKind.heading`. Project organisation, not general content — excluded from search, Inbox, and content lists unless explicitly requested |
| 2 | Global capture: App Intent + Services first. Design so a native hotkey can be added later behind opt-in |
| 3 | Calendar and Time live in Library; present contextually elsewhere; promotable by customisation. The top band must not grow |
| 4 | Completing the last task **suggests** completing the project. Never automatic, never nags after dismissal |
| 5 | CloudKit deferred until after Phase D, but new models must not make sync harder |
| 6 | Notes are independently owned and **linked** to projects, never contained by them |

Standing constraints: calendar events stay externally owned in the read-only phase · time entries stay
separate records · **suggestions and recovery states never decide anything on their own** · benchmarks
run against a normalised environment and must not make ordinary builds flaky.

---

## 0. Capture verification (decision 2)

Checked against current sources rather than assumed, because it changes the recommendation.

**Carbon `RegisterEventHotKey` works in a sandboxed Mac App Store app with zero entitlements.** This
is confirmed on Apple's own developer forums — it is the API sandboxed apps are expected to use for
user-customisable global shortcuts. Since macOS 15 a registration must include at least one modifier
that is not Shift or Option (an anti-keylogging measure); macOS 15.2 relaxed that so Option-only works
again. It quietly fails to reach apps that draw their own terminal, which does not affect us.

**Better still: an App Intent gets a global hotkey for free, with no API and no permission.** Shipping
`AppIntents` actions means the user can double-click the shortcut in Shortcuts.app, choose *Add
Keyboard Shortcut*, and press it from any application. Zero entitlements, zero prompts, fully
supported, and it works today.

**Therefore:**

- **Phase A** factors capture so its entry point is a plain function over `CaptureDraft`, callable
  from a view, an App Intent, a Service, or a hotkey handler. No UI dependency in the path.
- **Phase F** ships `CaptureEverythingIntent` + `NSServices`, which *already* gives a global hotkey via
  Shortcuts.app. A built-in hotkey picker using `RegisterEventHotKey` becomes a convenience behind an
  opt-in setting, not a necessity — and it stays App Store legal.

Sources:
[HotKey support for sandboxed apps](https://developer.apple.com/forums/thread/790771) ·
[RegisterEventHotKey modifier restriction, macOS 15](https://developer.apple.com/forums/thread/763878) ·
[Run a shortcut while working on your Mac](https://support.apple.com/guide/shortcuts-mac/launch-a-shortcut-from-another-app-apd163eb9f95/mac)

---

## 1. Scope

### In

| Area | Work |
|---|---|
| **Sidebar** | New IA, three bands, collapsible Library, pinning, customisation sheet, quiet selection treatment |
| **Counts** | `CountsService` — incremental, cached, `@Observable`. Kills the two full-store fetches per render |
| **Inspector** | Adaptive layout: label-above below 300pt, label-beside above. Nothing clips at 240pt |
| **Detail views** | Per-kind surfaces: Note, Task, Project, Area, Bookmark, Person (minimal), plus a generic fallback |
| **Headings** | New kind, inline in Project detail, drag to reorder, archive/trash cascade |
| **Containment** | Restricted to the work-breakdown structure. Notes link via `LinkKind.filedUnder` |
| **Layout modes** | Full · two-pane · focus |
| **Selection** | Multi-select, batch actions |
| **Undo** | Structural undo for move, delete, retag, status, archive |
| **Project completion** | Non-blocking suggestion with dismissal memory |
| **Capture seam** | Capture path refactored to be callable without UI |
| **Benchmarks** | Normalised harness, opt-in, with a committed reference baseline |
| **Perf fixes** | `itemByTitle` O(n) → indexed lookup; index warm off the main actor |

### Out — and where it goes

FTS5 and inline search → **B** · `TimeEntry` and the timer → **C** (Phase A reserves the toolbar slot)
· EventKit → **D** · Person workspace, Home, daily notes → **E** · App Intent, Services, attachments,
drag-and-drop beyond headings → **F**.

Sidebar rows for Home, Calendar, and Time are **not shown by default in Phase A**. They appear in the
customisation sheet marked as arriving later. A row that leads nowhere is worse than no row.

---

## 2. Model changes

`SchemaV2`. Additive attributes are lightweight; the containment repair is a **custom stage**, tested
against a V1 store fixture per the rules in `docs/05`.

### Containment becomes the work-breakdown structure only

```
Area     ▸ Project, Goal
Goal     ▸ Project
Project  ▸ Heading, Task
Heading  ▸ Task
Task     ▸ Task
```

Everything else — notes, bookmarks, references, ideas, decisions, interactions, meetings, people,
daily entries — contains nothing and is contained by nothing. All other association is a link.

This is decision 6 taken to its conclusion. A note relating to three projects is now expressible; a
project archived no longer drags its notes with it; and "where does this live?" has exactly one answer
for every kind.

### New `LinkKind.filedUnder`

Distinguishes *filed here deliberately* from *happens to mention this*. The project workspace shows
`filedUnder` notes as its own, and wiki-link mentions in a separate, quieter group.

### Migration stage V1 → V2

For every item whose parent is no longer legal: create `ItemLink(kind: .filedUnder, source: item,
target: oldParent)`, then null the parent. Nothing is deleted; nothing is orphaned. A store backup is
written first because this is not a lightweight stage.

### `ItemKind.heading`

Supported fields: title, children, sort order. Nothing else — no body, no dates, no status, no tags.

### `ItemKind.participatesInContentViews`

`false` for `.heading`. Search, Inbox, Notes, Tasks, and every content list exclude non-participating
kinds unless the query names them explicitly (`type:heading`). One declaration, enforced in
`ItemQuery` and in the search engine, so it cannot drift between the two.

### Added to `Item`

```
+ estimatedMinutes: Int?               ← projects and tasks; drives estimate vs actual in Phase C
+ completionPromptDismissedAt: Date?   ← decision 4
```

### CloudKit posture (decision 5)

Every new attribute has a default. No unique constraints. No ordered relationships. `filedUnder` links
reuse the existing `ItemLink`, which already carries its inverses. Nothing here makes Phase-D-onwards
sync harder, and the `filedUnder` change actually helps: a note linked to three projects merges
cleanly, whereas a single `parent` under concurrent edits does not.

---

## 3. Shell states

### Full — three panes

```
┌─────────────┬──────────────────────────┬─────────────────────────────┐
│  ⌂ ⌘0       │ Today                    │  Draft the announcement     │
│             │ ⌕ Filter…            ⇅   │  ─────────────────────────  │
│ ◎ Today   3 │ ──────────────────────── │  Q3 Product Launch · today  │
│ ▤ Upcoming  │ OVERDUE                  │                             │
│ ⌵ Inbox   2 │ ○ Send pricing table  4d │  Tone: matter-of-fact.      │
│             │ TODAY                    │  Reference [[Positioning]]. │
│ PINNED      │ ○ Draft the announce…  ◀ │                             │
│ ◫ Q3 Launch │ ○ Weekly review          │                             │
│ ☺ Priya R.  │ 14:00│ 1:1 with Sarah    │                             │
│             │                          │  ⌄ Linked from 2            │
│ LIBRARY  ⌄  │                          │                             │
│ ✎ Notes     │                          │                             │
│ ◫ Projects  │                          │                             │
│ ⬡ Areas     │                          │                             │
│ ☺ People    │                          │                             │
│ # Tags   ›  │                          │                             │
│ ⌕ Saved  ›  │                          │                             │
│ ⌸ Archive   │                          │                             │
│ ⌫ Trash     │                          │                             │
└─────────────┴──────────────────────────┴─────────────────────────────┘
   200pt              340pt ideal                  remainder
```

### Two-pane — `⌘⌃S`

```
┌──────────────────────────┬──────────────────────────────────────────┐
│ ‹ Today                  │  Draft the announcement                  │
│ ⌕ Filter…            ⇅   │  ──────────────────────────────────────  │
│ ──────────────────────── │  Q3 Product Launch · today               │
│ ○ Send pricing table  4d │                                          │
│ ○ Draft the announce…  ◀ │  Tone: matter-of-fact.                   │
└──────────────────────────┴──────────────────────────────────────────┘
```

A `‹` breadcrumb replaces the sidebar's orienting role. Clicking it opens a popover of destinations —
the sidebar's content, on demand.

### Focus — `⌘⌥F`

```
┌──────────────────────────────────────────────────────────────────────┐
│                                                                      │
│              Draft the announcement                          ⓘ      │
│              Q3 Product Launch · due today                           │
│              ──────────────────────────────────                      │
│                                                                      │
│              Tone: matter-of-fact. Reference the                     │
│              [[Positioning Notes]] for framing.                      │
│                                                                      │
│                     ← 720pt measure, centred →                       │
└──────────────────────────────────────────────────────────────────────┘
```

Escape leaves focus mode. Inspector still available via `⌘⌥I`, overlaying rather than splitting.

### Inspector, adaptive

Above 300pt — label beside control:

```
│  Kind      [ ◎ Task      ⌄ ]  │
│  State     [ Open        ⌄ ]  │
│  Due       [ 30 Jul 2026 ] ⊗  │
```

Below 300pt — label above control, full width, nothing clipped:

```
│  KIND                          │
│  [ ◎ Task                 ⌄ ]  │
│                                │
│  STATE                         │
│  [ Open                   ⌄ ]  │
│                                │
│  DUE                           │
│  [ 30 Jul 2026 ]           ⊗   │
```

The three-way status control becomes a menu below the breakpoint. Snapshot-tested at 240, 280, 300 and
380pt; a clipped control fails the build.

### Multi-select

```
│ ☑ Send pricing table to Priya          4d │
│ ☑ Draft the announcement                  │
│ ☐ Weekly review                           │
│ ───────────────────────────────────────── │
│ 2 selected   ✓ Complete  # Tag  ◫ Move  ⋯ │   ← contextual bar, appears on selection
```

The bar appears only while a multi-selection exists and carries the five most useful actions; the rest
are in `⋯` and the context menu. It never becomes a permanent toolbar.

### Project completion suggestion (decision 4)

```
│  Things to buy                                  ⋯  │
│  ✓  Extra camera battery                           │
│  ✓  Power adapter                                  │
│                                                    │
│  ┌──────────────────────────────────────────────┐  │
│  │ Everything here is done.                     │  │
│  │           Complete project    Not yet   ✕    │  │
│  └──────────────────────────────────────────────┘  │
```

Inline at the foot of the task list. Not a sheet, not an alert, not a toast that steals focus. "Not
yet" or `✕` sets `completionPromptDismissedAt` and it does not return — until a new open task is added
and the project reaches zero open tasks again, which re-arms it.

---

## 4. Sidebar states

### Default, with pins

```
╭────────────────────────╮
│  ◎  Today          3   │  ← selected: accent fill at 12% opacity,
│  ▤  Upcoming           │    6pt radius, accent-tinted icon and text
│  ⌵  Inbox          2   │
│                        │
│  PINNED                │  ← band header: 11pt semibold, tertiary, 0.4 kerning
│  ◫  Q3 Product Launch  │
│  ☺  Priya Raman        │
│  ⌕  Overdue & urgent   │
│                        │
│  LIBRARY          ⌄    │
│  ✎  Notes              │
│  ◫  Projects           │
│  ⬡  Areas              │
│  ☺  People             │
│  #  Tags          ›    │
│  ⌕  Saved Searches ›   │
│  ⌸  Archive            │
│  ⌫  Trash              │
╰────────────────────────╯
```

### No pins yet — the band is absent, not empty

```
╭────────────────────────╮
│  ◎  Today          3   │
│  ▤  Upcoming           │
│  ⌵  Inbox          2   │
│                        │
│  LIBRARY          ⌄    │
│  ✎  Notes              │
│  …                     │
```

### Library collapsed

```
╭────────────────────────╮
│  ◎  Today          3   │
│  ▤  Upcoming           │
│  ⌵  Inbox          2   │
│                        │
│  PINNED                │
│  ◫  Q3 Product Launch  │
│                        │
│  LIBRARY          ›    │
╰────────────────────────╯
```

Collapse state persists per window in `SceneStorage`, so a second window can be configured differently.

### Tags disclosure — bounded, never a scroll pit

```
│  #  Tags          ⌄    │
│     work           24  │
│     urgent          6  │
│     writing         5  │
│     home            3  │
│     …                  │
│     All Tags…          │  ← opens a管理 view with search and rename
```

Eight most recently used. The full set lives behind *All Tags…*, never in the sidebar.

### Customisation sheet

```
┌─ Customise Sidebar ──────────────────────────────┐
│                                                  │
│  TOP                                             │
│  ⠿ ◎ Today                              ☑        │
│  ⠿ ▤ Upcoming                           ☑        │
│  ⠿ ⌵ Inbox                              ☑        │
│                                                  │
│  LIBRARY                                         │
│  ⠿ ✎ Notes                              ☑        │
│  ⠿ ◫ Projects                           ☑        │
│  ⠿ ⬡ Areas                              ☑        │
│  ⠿ ☺ People                             ☑        │
│  ⠿ # Tags                               ☑        │
│  ⠿ ⌕ Saved Searches                     ☑        │
│  ⠿ ⌸ Archive                            ☑        │
│  ⠿ ⌫ Trash                              ☑        │
│                                                  │
│  LATER                                           │
│    ⌂ Home                        arrives in E    │
│    ▦ Calendar                    arrives in D    │
│    ⏱ Time                        arrives in C    │
│                                                  │
│  Drag between groups to promote or demote.       │
│                            Reset      Done       │
└──────────────────────────────────────────────────┘
```

Rows can be dragged between TOP and LIBRARY, satisfying decision 3 without letting the top band grow
by default. Stored in `UserDefaults` — a per-device preference, per the storage matrix.

### Visual specification

| Property | Value |
|---|---|
| Width | 200pt default, 180 min, 280 max |
| Row height | 26pt |
| Row inset | 10pt leading, icon 16pt column, 8pt gap |
| Icon | SF Symbol, `.secondary`, regular weight; accent when selected |
| Label | `.body`, primary; medium weight when selected |
| Selection | Accent at 12% opacity, 6pt continuous radius, inset 4pt from edges |
| Hover | Neutral fill at 6% opacity, same geometry |
| Keyboard focus | 2pt accent ring, distinct from selection so both can show at once |
| Band header | 11pt semibold, tertiary, 0.4 kerning, 16pt above / 6pt below |
| Count | `.caption`, tertiary, monospaced digits, trailing |
| Material | `.sidebar`, falling back to opaque under Reduce Transparency |

No disclosure triangles on destination rows. No full-width saturated selection bar. No badges other
than the two counts.

---

## 5. Interaction model

### Keyboard map

| Key | Action |
|---|---|
| `⌘0` | Today |
| `⌘1`–`⌘9` | Sidebar destinations in the user's own order |
| `⌘K` | Command palette |
| `⌘F` | Focus the list's search field |
| `⌘⇧F` | Clear and focus the search field |
| `⌘L` | Focus the sidebar |
| `Tab` / `⇧Tab` | Traverse sidebar → list → detail → inspector |
| `⌘⌃S` | Toggle sidebar |
| `⌘⌥I` | Toggle inspector |
| `⌘⌥F` | Focus mode |
| `↑` `↓` | Move within a list |
| `⇧↑` `⇧↓` | Extend selection |
| `⌘A` | Select all in the list |
| `Space` | Toggle completion |
| `↩` | Open in the detail pane |
| `⌘↩` | Open in a new window |
| `⌘⌫` | Move to Trash |
| `⌘⇧A` | Archive |
| `⌘⇧D` `⌘⇧P` `⌘⇧T` | Due date · Project · Tags |
| `⌘Z` `⌘⇧Z` | Undo · Redo |

### Escape is a ladder, and always predictable

```
sheet or palette   →  dismiss
search field, text →  clear the text, stay in search
search field, empty→  leave search, restore the previous list and selection
detail editor      →  return focus to the list, keep the selection
list               →  return focus to the sidebar
sidebar            →  nothing
focus mode         →  leave focus mode
```

The rule: Escape always moves one rung *outward*, never destroys work, and never changes the
selection.

### Undo

Structural undo uses the window's `UndoManager`, registered by the repository. `NSTextView` keeps its
own, so which one responds is decided by focus — standard AppKit behaviour, and the reason typing
undo and structural undo do not interleave confusingly.

Batch operations open an undo group, so retagging twenty items is one `⌘Z`. Every registered action
carries a name, so the menu reads **Undo Move to Trash**, not **Undo**.

### The running-timer slot

Phase A reserves the trailing toolbar position and renders nothing there. Phase C fills it with a
compact pill — `⏱ 1:12 ⏸ Drafting the brief` — that truncates to `⏱ 1:12` at narrow widths. It never
becomes a persistent toolbar when no timer is running.

---

## 6. Benchmarks

Per the constraint: **benchmarks must not make ordinary builds flaky.**

- They live in a separate target and **do not run** under the default test plan.
- They execute only when `EVERYTHING_BENCHMARKS=1` is set.
- Each run first executes a deterministic **calibration workload** — fixed CPU plus fixed SQLite work —
  and derives `hostFactor = hostCalibration / referenceCalibration`.
- A measurement passes if it is within `target × hostFactor`, so a temporarily loaded or slower host
  scales its budget instead of failing.
- A second, absolute ceiling of `target × 4` catches genuine regressions on any host.
- `Benchmarks/reference.json` records the reference machine — model identifier, core count, macOS
  version, and its calibration time — and is committed.
- Output is a table of measured, budget, and ratio-to-baseline, so a regression is visible as a trend
  rather than a pass/fail bit.

Phase A's own targets: sidebar render including counts **< 5 ms**, Today load **< 30 ms**, both against
the 50k-item corpus.

---

## 7. Acceptance criteria

Each is observable, and "finished" means the check passes.

| # | Criterion |
|---|---|
| A1 | Sidebar renders in < 5 ms against 50k items, verified by benchmark. No query in the sidebar path materialises the store |
| A2 | No inspector control clips at 240, 280, 300, or 380pt — snapshot-tested at all four |
| A3 | `⌘Z` reverses move, delete, retag, status change, and archive, with a named menu item for each |
| A4 | A batch action over 20 items is a single undo step |
| A5 | Opening a project shows the project — tasks, headings, linked notes, people — without replacing the list |
| A6 | Inbox contains no projects, areas, or headings |
| A7 | Headings do not appear in search results, Inbox, Notes, or Tasks unless `type:heading` is given |
| A8 | Dragging a heading moves its tasks with it; archiving one archives its tasks; restoring brings back exactly that set |
| A9 | Migrating a V1 store converts every illegal parent to a `filedUnder` link, loses nothing, and is proven by a fixture test |
| A10 | Archiving a project leaves its linked notes untouched and still reachable |
| A11 | Completing the last task shows the suggestion inline; dismissing it prevents recurrence until a new open task is added and completed |
| A12 | Sidebar customisation persists, survives relaunch, and differs per device |
| A13 | Escape follows the ladder in §5 from every starting point, without changing selection |
| A14 | Two-pane and focus modes are reachable by keyboard and restore correctly |
| A15 | Zero warnings, all tests green, no force unwraps outside `#Predicate`, hygiene suite passing |
