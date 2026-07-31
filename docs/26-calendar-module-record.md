# 26 — Calendar module record

What was built, what went wrong on the way, and what was deliberately left.

---

## What is there

| Area | Where |
|---|---|
| Event, calendar, attendee, alarm, availability values | `ElephruitCore/CalendarModel.swift`, `CalendarEvent.swift` |
| Recurrence, with an occurrence generator | `ElephruitCore/EventRecurrence.swift` |
| Write requests, validation, confirmation rules | `ElephruitCore/EventDraft.swift` |
| Calendar Sets, working hours, density, view kinds | `ElephruitCore/CalendarSet.swift` |
| Templates | `ElephruitCore/EventTemplate.swift` |
| Display zones, dual labels, DST inspection | `ElephruitCore/TimeZoneDisplay.swift` |
| Overlap layout, all-day bars, density | `ElephruitCore/EventLayout.swift` |
| Natural-language parsing | `ElephruitCore/EventPhraseParser.swift` |
| Search grammar | `ElephruitCore/EventSearchQuery.swift` |
| Deep links | `ElephruitCore/CalendarDeepLink.swift` |
| EventKit adapter, read and write | `ElephruitIntegrations/EventKitCalendarProvider.swift` |
| Synthetic calendar for review and tests | `ElephruitIntegrations/FixtureCalendarProvider.swift` |
| Set and template storage | `ElephruitModel/CalendarRecords.swift`, schema `0.0.6` |
| Set, template, and annotation services | `ElephruitPersistence/Calendar*.swift`, `EventAnnotationService.swift` |
| Cache and FTS5 index | `ElephruitSearch/CalendarIndexStore.swift`, `CalendarSearchPlan.swift` |
| The module's brain | `ElephruitFeatures/CalendarService.swift` |
| Per-window navigation | `ElephruitFeatures/CalendarWorkspaceModel.swift` |
| Six views | `CalendarTimeGrid`, `CalendarMonthView`, `CalendarAgendaView`, `CalendarOverviewViews` |
| Editor, recurrence editor, scope sheet | `ElephruitFeatures/EventEditorView.swift` |
| Natural-language entry | `ElephruitFeatures/EventQuickEntry.swift` |
| The CRM half | `ElephruitFeatures/EventInspectorView.swift` |
| Menu bar | `ElephruitFeatures/CalendarMenuBar.swift` |
| Shortcuts and intents | `Elephruit/CalendarIntents.swift` |

## Bugs found, and what each one taught

### The package did not compile at all

Before a line of calendar code was written. A person row's tooltip referred to `subtitle`, a property
the row had lost when its middle line was split into an identity line and a relationship line.
Nothing else in the file defined that name, so the whole of `ElephruitFeatures` failed on one stale
identifier inside a `private var` on a view.

Worth being precise about why it was invisible: a test suite cannot catch a build break, and the
build that would have caught it was not run between writing the identity line and committing it.
Fixed in the first commit of this branch.

### The grid was laid out in the machine's time zone

`CalendarService` took its device zone from `TimeZone.autoupdatingCurrent` while taking everything
else from the injected `DateProvider`. In the app those are the same zone. In a test with a fixed GMT
clock they are not, so day boundaries came from whatever zone the test machine happened to be in, and
two tests that had passed for a year started failing on an assertion about which day an event falls
on.

The failure reads as a date bug and is really a dependency-injection one: a clock was injected and
then half-ignored.

### A skipped wall-clock time cannot be detected from a `Date`

The first version of `nonexistentLocalTime` took a `Date` and asked for its components back. It
returned `nil` for every input, and the test that caught it said why: the instant "02:30 on 8 March in
New York" does not exist, so anything holding such a value has *already* resolved it to 03:30, and
asking the same question of the answer round-trips perfectly.

The check now takes a day, an hour, and a minute — the shape the editor actually has, since it
composes a date from two pickers.

### The calendar search returned nothing, silently

`title` and `location` exist on both the `events` table and the FTS table. The search path joins
them, and an unqualified column name made the statement fail to prepare — which surfaced as an empty
result set that looks exactly like "nothing matched". Every column in the shared `SELECT` list is now
qualified.

### FTS5 threw a syntax error at somebody for typing English

Stripping punctuation dealt with `-` and `"`. It did not deal with the words AND, OR, NEAR and NOT,
which survive the strip and are still keywords — so a search for "and then what" was a syntax error
presented to the user. Terms are now stripped *and* quoted.

### A meeting item was given a due date it is not allowed to have

`ItemKind.meeting` deliberately does not support `dueAt`: an event has an end, not a deadline.
`ItemValidator` refused it, which is how it was caught rather than shipped as a field nothing read
and nobody could see. The end lives on the `EventReference`.

### Two shortcuts collided on their first outing

⌃⌘N and ⌥⌘F — the obvious choices for a new event and a calendar search — are already New Window and
Focus Mode. `ShortcutRegistryTests` caught both immediately. They are now ⌃⌘E and ⌃⌘F.

### An event outside the visible hours was drawn at the top of the grid

The layout clipped an event's hours to the visible window *before* testing whether it fell inside it,
so a 3 a.m. event on a grid starting at eight was given a start of eight and a minimum height, and
drawn at the top of the morning as though it were happening. The test is `outsideVisibleHours`.

## Seven more, found by re-reading the views against what they claimed to do

None of these was caught by a test, and the reason is the same for all seven: each is in the *wiring*
between a service that works and a view that calls it, and every unit test of both halves passed.

### The keyboard did nothing at all

`onKeyPress` only fires on a focused view. The workspace had a complete key handler — arrows,
shift-arrows, T, N, ⌘1–⌘6, Escape, Delete — attached to a view that could never receive a key event.
Every shortcut compiled, read correctly, and did nothing.

### Delete on a repeating event performed a move

Deleting built its pending request out of a type that had only `move` and `resize` cases, so it
passed a move to the time the event already had. A no-op behind a sheet saying "Delete", whose
buttons also read "Changes this occurrence" because `isDeletion` was hardcoded false. There is now
one path for a drag, a resize, and a deletion, because the question in front of all three is the same
one.

### A month cell had two tap gestures, which is one

`.onTapGesture` does not stack — a second replaces the first silently. The cell had a line setting
the keyboard focus that never ran, so clicking a day left the focus ring elsewhere and the arrow keys
then moved from somewhere other than the day just clicked.

### Revoked access blanked a calendar the app had just read

The service fell back to the cache correctly and the view hid the result behind the permission
explanation, so the fallback worked and nobody could see it. What the app read five minutes ago is
still true; the explanation now appears only when there is genuinely nothing to show.

### The menu bar shrank the window a window was showing

Both called `load(range:)`, which records what it read so a change notification can reload it. The
menu bar wants two days and a window wants a month; whichever called last decided what the *other*
reloaded. `peek(range:)` reads without claiming.

### A menu bar request was consumed while the window was drawing

`RootView` was handed `consumeCalendarRequest()` in the scene's body — a mutation during a view's
evaluation, which SwiftUI may run at any time and more than once. Clicking "New Event" in the menu
bar while a window was already open did nothing.

### And one behaviour that was wrong rather than broken

Ticking a calendar off made its past unsearchable. The cache replaces a window wholesale, which is
right, but a narrowed fetch says nothing about the calendars it did not cover — and deleting their
rows on that basis is inferring from silence. A box that hides something is not a box that forgets
it.

## What is deliberately not there

### Attendee editing

`EKEvent.attendees` is read-only and `EKParticipant` has no public initialiser. There is no supported
way to add or remove an attendee through EventKit. Existing attendees are displayed, matched, and
linked to CRM people; the editor does not pretend the list can be changed.

This is not a limitation of the implementation and no amount of further work removes it.

### Synchronised attachments

`EKCalendarItem` exposes no attachments API — not read, not write. Anything claiming an attachment
syncs with the event would be false. Attachments are Elephruit's, held on the meeting item beside
every other attachment in the library, and the inspector says so in a sentence rather than leaving
somebody to assume.

### Focus Filters

`SetFocusFilterIntent` would let a macOS Focus switch the active Calendar Set automatically, which is
the natural home for this feature. It is not implemented: the intent requires an App Intents
extension target, and adding a target to a hand-maintained `pbxproj` is a change to the project's
structure rather than to this module. The capability it would provide is reachable today through
`SwitchCalendarSetIntent`, which a Focus automation can call.

Recorded here rather than left as a silent gap.

### Two things the fixture cannot demonstrate

The synthetic calendar shows every state the module renders, but two behaviours are EventKit's rather
than the app's and can only be seen against a real store: the `EKEventStoreChanged` notification
arriving when somebody edits an event in Calendar.app, and a delegated Exchange calendar refusing a
write for a reason the account decides. Both have code paths and both are exercised by tests through
the double; neither has been watched happening.

## Numbers

| Check | Result |
|---|---|
| `swift build` | Succeeds, zero warnings |
| `swift test` | 1,181 tests, all passing |
| `xcodebuild` Debug | Succeeds, zero warnings |
| Schema | `0.0.6`, additive, two entities |
| New entitlements | None — the calendar entitlement was already present |
| New usage strings | None — `NSCalendarsFullAccessUsageDescription` was reworded |

## What has not been looked at

The same gap the People module recorded, for the same reason. **The calendar has not been reviewed on
screen in dark mode**, and the six views have not been watched under Increase Contrast or Reduce
Transparency. What is enforced instead is that no view names a colour the system cannot adapt
(`SourceHygieneTests`), that the palette mapper and the design system agree
(`CalendarPaletteAgreementTests`), and that Reduce Transparency produces an opaque surface rather
than a less-transparent one (`Theme.floatingControl`).

That is the part that stays true. It is not a substitute for looking.

To look:

```bash
open -n "$(xcodebuild -project Elephruit.xcodeproj -scheme Elephruit -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}' | head -1)/Elephruit.app" --args -ElephruitDevelopmentMode -ElephruitUseTemporaryStore -ElephruitUseFixtureCalendar
```

That launches against a throwaway library and a **synthetic calendar** — invented events on
fictional calendars — so the whole module can be exercised without EventKit being touched. The
fixture deliberately contains the awkward cases: a morning with three overlapping meetings, a
four-day trip in the all-day band, a recurring standup, a declined invitation, a cancelled meeting,
an event in another time zone, and a read-only subscribed calendar that refuses an edit and says why.
