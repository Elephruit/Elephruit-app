# 35 — Today as the information center (iPhone)

**Status:** plan only. Nothing in here is built.
**Scope:** `ElephruitiOS/Screens/TodayScreen.swift` and the shared model beneath it. The Mac inherits
whatever lands in `ElephruitCore` / `ElephruitFeaturesCore` but gets no new surface in this plan.

---

## 1. What was asked for

1. How many hours are free in the workday — with a setting for core workday hours.
2. All-day events separated out of the schedule and shown as *awareness*, not as agenda.
3. The core schedule as a list, with options to show it as blocks and to show free time.
4. Free time you can drop something into easily.
5. Today's todos schedulable — blocking the calendar for the length of the work.
6. Proposed travel blocks, from current location, when an invitation has a location.
7. The people being met today, carrying the key insights about them.

## 2. What already exists, and what does not

This matters more than usual here, because five of the seven asks are mostly *surfacing* work on a
model that already computes the answer, and two are genuinely new infrastructure. Sequencing the
cheap five first is what makes this shippable in pieces.

### Already there

| Ask | What already computes it |
| --- | --- |
| Hours free | `FocusTimeRules.focusTime(on:events:workingHours:now:calendar:)` — [DailyPlan.swift:436](Packages/ElephruitKit/Sources/ElephruitCore/DailyPlan.swift:436). Returns total free and the longest stretch. |
| Workday hours | `WorkingHours` — [CalendarSet.swift:110](Packages/ElephruitKit/Sources/ElephruitCore/CalendarSet.swift:110). Persisted per calendar set on `CalendarSetRecord`. |
| All-day vs timed | `DayPlan.allDayEvents(calendar:)` and `.timedEvents(calendar:)` — [DailyPlan.swift:1169](Packages/ElephruitKit/Sources/ElephruitCore/DailyPlan.swift:1169). Both exist and neither is called by the phone. |
| Event classification | `DayEventKind` — meeting / appointment / focusBlock / away / allDay, decided from what the event says about itself, never its title. |
| Blocks vs sections | `TodayFilters.usesIntegratedAgenda`, `DayAgenda.slots(for:calendar:)`, `DayAgenda.nowMarkerIndex(...)`. Unused on the phone. |
| Writing a calendar block | `EventDraft` + `CalendarService.create(_:)` → `Result<CalendarEventSummary, CalendarWriteFailure>`. |
| Linking a block to a task | `EventAnnotationService.link(record:to:)` — a *local* annotation, invisible to the calendar account. |
| People insights | `DayPerson` already carries `roleLine`, `lastContact`, `openTaskIDs`, `celebration`, and up to three `quickFacts` filtered for sensitivity by `DailyPlanService.quickFacts(from:)`. The phone draws the name, one reason line, and **one** fact. |

### Not there

- **Free time as values.** `DayFocusTime` gives a total and the longest stretch. The gaps themselves
  are computed inside `focusTime` and thrown away. Nothing can be drawn in a gap that no type names.
- **Any way to set workday hours on the phone.** `WorkingHours` is editable only from the Mac's
  calendar-set editor ([CalendarSetViews.swift:288](Packages/ElephruitKit/Sources/ElephruitFeatures/CalendarSetViews.swift:288)).
- **A workday at all, on a fresh phone.** `activeSet` resolves from a **per-device** `UserDefaults`
  key ([CalendarSetService.swift:54](Packages/ElephruitKit/Sources/ElephruitPersistence/CalendarSetService.swift:54)). With no set chosen on *this* iPhone it is `nil`, and the
  briefing silently falls back to `WorkingHours.standard` — 9:00–17:00, Mon–Fri
  ([DailyPlanService.swift:950](Packages/ElephruitKit/Sources/ElephruitFeaturesCore/DailyPlanService.swift:950)). **The "free" figure on the screenshot in `docs/ios/2026-08-04` is
  therefore measured against hours the user never chose and cannot see.** Fixing this is Phase 1 and
  it is a correctness fix, not a feature.
- **Scheduling a todo onto the calendar.** Nothing writes an event from a task anywhere in the app.
- **Anything location-shaped.** No `CoreLocation`, no coordinates on `CalendarEventSummary` (it has
  `locationName: String?` and nothing else), no location usage string in
  [ElephruitiOS-Info.plist](Configuration/ElephruitiOS-Info.plist).

### Two constraints that shape the design

**The app has already refused to guess a block, on the record.** `TodayActions.openInCalendarForFocus`
and §7 of [30-today-record.md](docs/30-today-record.md) both say it in as many words: *where a block
goes depends on what else is on the day and on what the person is protecting, and an app that guesses
both has written an appointment somebody now has to delete.* This plan does not reverse that. It
narrows it: the app may **propose** a slot with a specific start and length, drawn from free time it
computed; a tap is what writes. Nothing here writes to a calendar without a tap on a proposal that
names the calendar, the time, and the length.

**Network.** Settings currently promises, in the user's own words, that *"Apple's CloudKit is the
only thing this app talks to on the network — no account with us, no analytics, no third-party
service."* Real travel-time estimation is geocoding plus routing, and both are network calls to
Apple. That promise is why travel is last, staged, and opt-in — see §9.

---

## 3. The target screen

Top to bottom, on one scroll:

```
Today · Tuesday 5 August
┌──────────────────────────────────────────────────┐
│  2 overdue   3 meetings   4h 20m free of 8h      │   ← header figures, now stated against
│  ⟳ Now · Focus — pricing model            2:00PM │      a workday the user set
└──────────────────────────────────────────────────┘

Awareness                                            ← NEW: all-day, multi-day, away.
  ✈︎  Berlin — day 2 of 4                                Never in the agenda, never counted
  ●  Rosa's birthday                                     as a meeting, no time column.

Schedule                        [ List | Blocks ]  ⓘ  ← NEW: style control + free-time toggle
   9:30  Standup
  10:00  Design review · Room 2 · overlaps
         ↳ Leave by 9:45 · 15 min                    ← Phase 7 (travel), a proposal not a write
  11:30 ─ 12:30  1h free            [ + ]            ← NEW: free slots are rows you can tap
  12:30  Lunch
   2:00  Focus — pricing model

To do                                                ← unchanged rows; one new swipe action
  ○ Draft the pricing memo            [ Block time ] ← proposes 11:30–12:30 from the free slot above
  ○ Reply to Sam

People today                                         ← promoted from a line to a card
  MC  M. Chen · Head of Design, Northwind
      10:00 · Design review
      Last spoke 3 weeks ago · 1 open item with them
      "Prefers written proposals" · "New to the role"

The day's note ›
```

Everything above the People section is already computable today except the free-slot rows and the
awareness split.

---

## 4. Phase 0 — Domain foundations (no visible change)

Two additions to `ElephruitCore`, both pure, both testable against a fixed clock.

**0.1 Free time as values.** Add to `DailyPlan.swift`:

```swift
/// One unclaimed stretch inside the working window.
public struct DayFreeSlot: Sendable, Hashable, Identifiable {
    public var range: Range<Date>
    /// Whether this slot is happening now, so a row can say "now" rather than a clock time.
    public var isCurrent: Bool
    public var id: Date { range.lowerBound }
    public var duration: TimeInterval { ... }
}
```

Extend `DayFocusTime` with `slots: [DayFreeSlot]`. `FocusTimeRules.focusTime` already builds exactly
this array internally (`var gaps: [Range<Date>]`) and discards it — the change is to keep it. Filter
to slots of **15 minutes or more**: the existing `longestStretchSummary` already uses that floor, and
a five-minute gap between two meetings is not free time, it is walking.

`available` and `longestStretch` keep their current meanings, so nothing that reads them changes.

**0.2 The awareness split.** `DayPlan` already has `allDayEvents(calendar:)`. Add the counterpart
naming for what the phone will draw:

```swift
/// Entries that describe the shape of the day rather than occupying a slot in it.
/// All-day, multi-day, and anything marked away. Never counted as meetings, never in the agenda.
public func awarenessEvents(calendar: Calendar) -> [DayEvent]
```

Definition: `occupiesAllDayRow(calendar:)` **or** `kind == .away`. A four-day trip and a day of leave
belong here; a timed meeting with eleven people on it does not, whatever its length — the existing
`DayEventRules.kind` ordering already makes attendees win, and this must not undo that.

**0.3 Workday resolution in one place.** Today `DailyPlanService.briefing` reaches for
`services.calendar.activeSet?.workingHours ?? .standard` inline. Move that to a single resolver so
that every surface — the briefing, the free slots, the settings screen, the block proposals — reads
one answer:

```swift
extension AppServices {
    /// The hours the user actually works, and where that answer came from.
    public var workday: WorkdayHours { ... }
}
```

**Tests (Phase 0):** free slots on a day with three meetings, on an empty day, on a day already half
gone (the `now` floor), on a non-working weekday (`nil` window → no slots), and where a focus block
marked *free* does not consume the slot but a meeting does. Awareness split over the fixture
calendar's four-day trip, leave day, all-day birthday, and a long timed meeting.

**Commit:** *Give the day's free time a shape of its own.*

---

## 5. Phase 1 — Core workday hours, settable on the phone

The correctness fix. Three questions, one answer:

- **Where does it live?** `WorkingHours` stays the type. Add an **app-level default** persisted in
  the store — so it syncs, which a `UserDefaults` value would not — with the active calendar set
  continuing to override it when one is chosen. `WorkdayHours` resolution order: active set's hours →
  app default → `.standard`. That keeps the existing "the briefing and the time grid cannot disagree"
  guarantee while giving a phone with no set a real answer.
- **Schema.** One new record (or fields on an existing settings record) → `SchemaV17`, version
  `0.0.17`. Patch only, additive, defaults on every field, per the repo's versioning rule.
- **Surface.** A new `Workday` section in [SettingsScreen.swift](ElephruitiOS/Screens/SettingsScreen.swift):
  two time pickers, a weekday row of seven toggles, and a footer that states plainly what the number
  is used for — *"How much of your day is free is measured against these hours."* When a calendar set
  is active and overrides them, the section says so and links to the set rather than silently lying.

**Tests:** resolution order with and without an active set; migration from `SchemaV16` leaves an
existing library reading 9–5 Mon–Fri (i.e. no behavior change for anyone already running).
**Verification:** screenshot the settings screen; screenshot Today showing the "free" figure move
when the hours change.

**Commit:** *Let the phone say when the working day starts and ends.*

---

## 6. Phase 2 — Awareness, and a schedule that is only the schedule

`TodayContent.eventsSection` currently renders `plan.events` — everything, all-day rows included,
with the time column reading "All day". Split it:

- **`awarenessSection`**, above Schedule: compact rows, no time column, symbol from
  `DayEventKind.symbolName`, and a day-N-of-M line for multi-day entries. Tapping opens the event.
  No conflict warnings here — an all-day entry overlaps everything by construction, which
  `DayEventRules.conflicts` already knows and excludes.
- **`scheduleSection`**: `plan.timedEvents(calendar:)` only, minus anything the awareness section
  took.

The header figure `otherEventCount` should stop counting awareness entries as schedule; check
`DayBriefing.figures` reads sensibly afterwards.

**Verification:** screenshot against the fixture calendar, which already carries the four-day trip,
the leave day, and the all-day birthday.

**Commit:** *Lift the all-day entries out of the schedule and into awareness.*

---

## 7. Phase 3 — Free time you can see, Phase 4 — free time you can fill

These two are one idea and ship as two commits.

**Phase 3 — see it.** Interleave `DayFreeSlot` rows into the schedule list, behind a toggle in the
section header (persisted; see the `TodayFilters` note below). A slot row is quiet: a rule, a
duration, a range. `isCurrent` slots read *"free now · 40m"*. Slots are drawn only for today and the
future — a gap in a day already gone is not an opportunity.

**Phase 4 — fill it.** Tapping a slot opens a small sheet offering, in this order:

1. **Today's unscheduled work**, longest-fitting first — the todos already on the page with no
   `pinnedAt`. Choosing one writes a block (Phase 5's machinery, so land Phase 5 first or land them
   together).
2. **Block this time** — a plain focus block, `availability: .free`, so it defends the time without
   telling colleagues you are busy. This is what `DayEventKind.focusBlock` already means.
3. **Add a reminder** — `TodayActions.createTask(titled:on:)` with the slot's start as a timed
   reminder.

Every write names the calendar it is going to, in the sheet, before the tap.

**`TodayFilters` note.** `scheduleStyle` (Phase 5) and `showsFreeTime` belong on `TodayFilters`,
which is `Codable` in `UserDefaults`. Swift's synthesized `init(from:)` does **not** apply property
defaults for missing keys, so adding fields would throw and silently reset everybody's filters — the
fallback in [TodayPreferences.swift:36](Packages/ElephruitKit/Sources/ElephruitFeaturesCore/TodayPreferences.swift:36) catches it, but resetting is not the intent. Write an explicit
`init(from:)` using `decodeIfPresent` when the first field is added.

**Commits:** *Show the gaps between the meetings.* / *Let a gap take work.*

---

## 8. Phase 5 — Blocking time for a todo

The payoff. A new action on `TodayActions`:

```swift
/// Proposes a calendar block for a task, and writes it only when accepted.
public func proposeBlock(for task: Item, in slot: DayFreeSlot?) -> BlockProposal
public func commit(_ proposal: BlockProposal) async -> Result<CalendarEventSummary, CalendarWriteFailure>
```

- **Reached from** a trailing swipe action and the context menu on the To-do rows, and from the
  free-slot sheet. `MobileItemRow` itself is not touched — the Reminders module's presentation is
  owner-polished and stays as it is.
- **How long?** In order: the task's own estimate if it has one, else the slot's length capped at one
  hour, else 30 minutes. The sheet shows the length and lets it be changed before the write. It does
  not guess silently.
- **Where?** The proposed start is the first free slot that fits, today, after now. The sheet shows
  it and allows another.
- **What is written.** `EventDraft(title: task.displayTitle, availability: .free, …)` — nothing else
  from the task. No notes, no project, no people. `EventDraft`'s field list is guarded by
  `CalendarWriteSafetyTests.draftCarriesNothingPrivate` and **this plan adds no field to it.**
- **The link back** is local: on success, `services.eventLinks.link(record: task, to: event)`. The
  calendar account never sees it. That is the whole reason `EventAnnotation` exists.
- **Undo.** The confirmation says what was written and offers to remove it, because the fastest way
  to make somebody distrust this button is for the first block to be wrong and hard to delete.

**Tests:** proposal arithmetic (fit, cap, fallback, no free time at all); a draft that carries only
the permitted fields; the annotation link surviving; a `CalendarWriteFailure` surfacing as a message
rather than a silent no-op.

**Commit:** *Let a todo claim a block of the day.*

---

## 9. Phase 6 — People, with what is worth knowing

Cheapest large win on the list: `DayPerson` already carries everything and the phone draws a tenth of
it. Replace `TodayPersonRow` with a card:

- Name, and `roleLine` — *"Head of Design, Northwind"*.
- The meeting: time and title, from `primaryReason`.
- `lastContact` as a sentence — *"Last spoke 3 weeks ago"* — and `openTaskIDs.count` as *"2 open
  items with them"*.
- Up to three `quickFacts`, which are already filtered to non-sensitive stated facts by
  `DailyPlanService.quickFacts(from:)` (§ its doc comment: a briefing surface is the screen most
  likely to be visible to somebody else in the room).
- A birthday, when `celebration` is set.

Two rules carried over rather than reinvented: honor `CalendarSetDefinition.showsPersonContext`
(off = name and meeting only, for a set somebody might screen-share), and never infer a fact. If the
library knows nothing about somebody, the card is a name and a meeting time, and that is a complete
answer rather than a gap to fill.

**Commit:** *Give the people on today's page something worth knowing.*

---

## 10. Phase 7 — Travel time, staged

The only ask that needs new permissions and new network. Split it, because most of the value does not
need either.

### 7a — "Leave by", with no network at all

- An event qualifies when it has a `locationName` that is **not** a conferencing link. The test
  already exists: `MeetingLink.url(in:)` reads the location field looking for exactly that, and
  `isKnownConferencing` names the hosts. A Zoom URL in the location field is not a place to travel to.
- The duration comes from the user, not from a server: a default travel buffer in Settings, and a
  remembered duration **per location string** once they have set one. The second time there is a
  meeting in "Room 2" the app already knows it takes five minutes.
- Rendered as a subordinate line under the event — *"Leave by 9:45 · 15 min"* — with an action that
  writes a travel block ahead of the meeting through the same `proposeBlock` machinery as Phase 5.
- No permission, no network, no promise broken.

### 7b — Real ETA, opt-in

Only if 7a proves it is wanted.

- **Needs:** `NSLocationWhenInUseUsageDescription`, `CoreLocation` for the current position,
  `MKLocalSearch` to turn the location string into a coordinate, `MKDirections.calculateETA` for the
  duration. Optionally `structuredLocation`'s coordinate from EventKit carried onto
  `CalendarEventSummary` (a *read* type — not `EventDraft`, so the write-safety allowlist is not
  touched) and through `IndexedEvent`, which would avoid geocoding entirely for events whose
  organizer set a real place.
- **The privacy cost is the decision, not the code.** This sends a location string and a coordinate
  to Apple. The Settings copy currently promises CloudKit is the only network destination, and that
  copy would have to change. So: its own switch, off by default, in the Integrations section
  alongside Calendar and Reminders; the usage string says exactly what leaves the device; only the
  location string and coordinates ever leave — never a title, never an attendee, never a note; and
  when the switch is off, none of the frameworks are touched at all.
- **Never automatic.** Travel is a proposal like everything else here.

**Commits:** *Say when to leave for a meeting with a place.* / *(later, gated)* *Ask Maps how long
the journey takes.*

---

## 11. Sequence, and what each step is worth on its own

| Phase | Delivers | Visible? | Risk |
| --- | --- | --- | --- |
| 0 | Free slots and the awareness split as values | No | None |
| 1 | Workday hours settable; the "free" figure becomes true | Yes | Schema 0.0.17 |
| 2 | Awareness band; schedule is only the schedule | Yes | None |
| 3 | Free time shown | Yes | None |
| 5 | Blocking time for a todo | Yes | First calendar write from Today |
| 4 | Free slots accept work | Yes | Depends on 5 |
| 6 | People insights | Yes | None |
| 7a | "Leave by" | Yes | None |
| 7b | Real ETA | Yes | Permission + network + a promise to rewrite |

Phases 1–3 alone answer asks 1, 2, and half of 3, and each is independently shippable. Phase 5 before
4 because 4 uses 5's writer.

## 12. Verification, throughout

Per the repo's habits and the phone's tooling:

- `swift test` for every domain change in Phase 0, 1, 5, 7a; a clean `xcodebuild` is the bar per step.
- Every phase with a visible change gets a screenshot before it is committed, driven headlessly by
  XCUITest with `-ElephruitUseTemporaryStore -ElephruitUseFixtureCalendar -ElephruitLoadSampleData`.
  The fixture calendar already carries the hard cases: clashing mornings, a defended block marked
  free, leave marked unavailable, a four-day trip, a call with a join link, a declined invitation, a
  cancelled meeting still showing.
- The fixture calendar needs **one addition** for this work: a couple of events with real-looking
  physical locations and a clean two-hour gap in the afternoon, so free slots and travel proposals
  have something to be drawn against.
- Dark appearance and an accessibility text size on the two new row types (free slot, person card),
  which is where the existing `@ScaledMetric` time column was caught getting it wrong.

## 13. Decisions

1. **Workday hours — app-level default, with the calendar set overriding it.** Decided 2026-08-05.
   Resolution order stands as §5 describes it: active set → app default → `.standard`. Schema 0.0.17.
2. **7b, real ETA — build it.** Decided 2026-08-05, with the network cost understood: the Settings
   copy that promises CloudKit is the only network destination has to be rewritten in the same commit
   that adds the switch. Every guard in §10 holds — off by default, its own switch, only the location
   string and coordinates ever leave the device, and never automatic.

### Still open

3. **Should a block written for a todo show as busy or free?** Plan assumes `.free`, matching what
   `focusBlock` already means, so colleagues can still book over it. Busy is defensible and is a
   one-line change. Needed by Phase 5.
4. **Blocks view (ask 3, "show blocks")** — the design above treats it as a proportional rendering of
   the same list rather than the Mac's full `CalendarTimeGrid`. The time grid is a large component and
   a phone-width port of it is its own project. Needed by the blocks phase, not before.
