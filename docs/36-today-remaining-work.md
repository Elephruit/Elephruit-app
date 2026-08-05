# 36 — Today: the work that is left

Written to be handed to a fresh thread. Self-contained: you do not need the conversation that
produced it. The design record is [35](35-today-information-center-plan.md); this is what remains of
it plus what has been decided since.

Branch: `claude/today-view-remaining-work-62cc78`, off `013ed730` (the merge of PR
[#75](https://github.com/Elephruit/Elephruit-app/pull/75)).

**One thing is left to build: §3.5, travel with a real ETA.** Everything else this document asked
for is done. §3.6 is still blocked on a decision that is not mine to make.

---

## 1. Where the page is now

Today is one continuous thread down the **left edge**, scrolling from three months back to three
months forward. Every row has the same skeleton, and keeping that skeleton is the whole reason the
page reads as one thing:

| Column | Says | Examples |
|---|---|---|
| The rail, at the left edge | *what kind of thing this is* | one badge on the line. On a task the badge **is** the checkbox. |
| Content | everything else, including *when* | time, title, location, conflict, reason |

### The skeleton changed, on the owner's direction

There used to be a third column: a 64-point gutter left of the rail holding a time, a face or a
completion circle. It is gone. Two things were wrong with it — the gutter was mostly empty, because
only meetings and timed reminders had anything to put there, so the page paid a permanent column for
an occasional fact; and a person's initials sat *outside* the line that is meant to hold everything
the day contains, which reads as a marginal note rather than an entry.

So the rail moved to the margin, the gutter went, and the time became the first thing the content
says. **Do not reintroduce a leading column.** If something needs to be said before the title, it
goes in the content.

Built, verified, committed:

- **Workday hours**, settable on the phone, store-backed so they sync, overridden by a calendar set
  while one is active. Schema 0.0.17.
- **Free time** as `DayFreeSlot` values, drawn as a *dashed stretch of the thread*. Behind a
  persisted switch in the Schedule header.
- **Awareness band** — all-day, multi-day and away entries above the schedule, with "Day 2 of 4".
- **The briefing figure** with a denominator: "5h 15m free of 7h 40m", the denominator being what is
  *left*, not the whole day.
- **People grouped by the thing that gathers them** — a meeting is one row with overlapping faces;
  opening it gives each person their role, history and facts.
- **The feed, both ways** — days after today arrive a week at a time on scroll geometry to a
  ninety-day horizon; days *before* today arrive on request and then on reaching the top, to a
  horizon of their own. Tapping any day opens it in full, drawn by the same builder that draws today.
- **Blocking time** — a gap can be asked what it is for, and a to-do can ask for a gap. §3.1, done.
- **People insights** — last contact, open items, up to three facts, behind the person-context
  switch. §3.3, done.
- **Travel 7a** — "leave by", from the user's own numbers, no network. §3.4, done.

### The files

| File | What it is |
|---|---|
| `ElephruitiOS/Components/Timeline.swift` | The rail: `TimelineRow`, `TimelineHeader`, `Timeline.Badge`, `railStyle`, the geometry constants, `timelineIsPast` |
| `ElephruitiOS/Components/PeopleGathering.swift` | Grouping rule + the meeting-with-faces row |
| `ElephruitiOS/Screens/TodayScreen.swift` | Assembly, `daySections(_:isAnchor:)`, both feeds, the way back to now |
| `ElephruitiOS/Screens/TodayFeed.swift` | Day marker, compact summary lines, header and footer of the run |
| `ElephruitiOS/Screens/BlockTimeSheet.swift` | The sheet a gap, a task or a journey opens; `TodayReviewLaunch` |
| `Packages/.../ElephruitCore/TimeBlock.swift` | What fits in a gap, how long a block lasts, what a block writes |
| `Packages/.../ElephruitCore/Travel.swift` | Which entries are somewhere to go, and when to leave |
| `Packages/.../ElephruitCore/DailyPlan.swift` | `DayFreeSlot`, `awarenessEvents`, `scheduleEvents`, `proportionSummary`, `MeetingLink` |
| `Packages/.../ElephruitFeaturesCore/TodayModel.swift` | Both horizons, `extendFuture()`, `extendPast()` |
| `Packages/.../ElephruitFeaturesCore/TodayActions.swift` | Every mutation the page can make, including the three block proposals |
| `Packages/.../ElephruitFeaturesCore/TravelPreferences.swift` | The default buffer and the per-place memory |
| `Packages/.../ElephruitPersistence/WorkdayService.swift` | Workday resolution order |

---

## 2. Decisions already made — do not re-litigate

1. **iPhone Today only.** The Mac keeps its two-column page.
2. **A future day is a summary; tapping opens it in full**, drawn by `daySections(_:isAnchor:)`.
   Empty days are shown, not skipped.
3. **The rail is at the left edge and there is no leading column.** See above.
4. **A block written for a todo offers busy *or* free, per block.** The sheet asks.
5. **Past days load only on request**, and then on reaching the top of the run. Nothing behind today
   is loaded on arrival.
6. **A past day dims *and* its rail fades.** Both.
7. **Two ways back to now**: the toolbar button — which now also appears when today has merely been
   scrolled out of sight — and a floating pill that says which way.
8. **The horizontal day-swipe is gone.** Tomorrow is further down and yesterday further up; it was a
   second, less obvious way to do what the scroll does, competing for the same gesture as the rows'
   own swipe actions. The toolbar menu still steps a day at a time.
9. **The blocks view is deferred** — the owner is undecided. Do not add a `TodayFilters` switch for
   it until there is something behind it.

---

## 3. The work

### 3.1 Blocking time — **done**

Tapping a gap offers, in this order: the day's unscheduled work longest-fitting first, a plain focus
block, and a reminder for a moment inside the gap. A to-do reaches the same sheet from a trailing
swipe action and its context menu. The sheet shows the hours, the length, the calendar and
busy-or-free before writing anything, becomes its own receipt afterwards, and offers to remove what
it just wrote.

The event carries the task's title and **nothing else**; the link back is written locally through
`EventAnnotationService.link(task:to:)`. `EventDraft` gained no field, so
`CalendarWriteSafetyTests.draftCarriesNothingPrivate` still guards the same list.

### 3.2 Backwards through the feed — **done**

`TodayModel.extendPast()` mirrors `extendFuture()` with its own horizon. See §5 for the four wrong
turns this took; three of them are traps anything scroll-driven on this page will hit again.

### 3.3 People insights — **done**

"Last spoke 3 weeks ago · 1 open item with them" on one line, then up to three quick facts. All of it
behind the active Calendar Set's `showsPersonContext`.

### 3.4 Travel, 7a — **done**

`TravelRules` decides what is somewhere to go: a location that is not a conferencing link, not
all-day, not cancelled, and not already past. `TravelPreferences` holds a default buffer and
remembers what was allowed **per place**, written when a block is created rather than while a picker
is scrolled. The line writes a real block through §3.1's machinery, named after the place rather than
the meeting.

### 3.5 Travel, 7b — real ETA, opt-in — **the one thing left**

Approved, with the cost understood.

- **Needs:** `NSLocationWhenInUseUsageDescription`, `CoreLocation`, `MKLocalSearch` to resolve the
  location string, `MKDirections.calculateETA`. Optionally carry EventKit's `structuredLocation`
  coordinate onto `CalendarEventSummary` — a *read* type, so `EventDraft`'s allowlist is untouched —
  to skip geocoding when the organizer set a real place.
- **Its own switch**, off by default, in Integrations beside Calendar and Reminders. When off, none
  of the frameworks are touched.
- **Only the location string and coordinates ever leave the device.** Never a title, an attendee, a
  note.
- **The Settings copy has to be rewritten in the same commit.** Two places, and both are false the
  moment this ships: the iCloud section's *"Apple's CloudKit is the only thing this app talks to on
  the network"*, and the About section's *"With sync off, the network is never used at all"*. Find
  them in `ElephruitiOS/Screens/SettingsScreen.swift`.
- Never automatic. Travel is a proposal like everything else here.

**How to make it verifiable**, which is the part that needs deciding before any code: the simulator
has no real location, so nothing here can be checked by screenshot the way the rest of this page was.
Follow the calendar's shape — a `RouteProviding` protocol in `ElephruitIntegrations` with a MapKit
adapter and a `FixtureRouteProvider`, chosen by launch argument exactly as
`-ElephruitUseFixtureCalendar` chooses one. Then the arithmetic and the refusals are unit-testable,
and the adapter is the only untested file. A safety test in the shape of
`CalendarWriteSafetyTests` — the integrations module cannot import the store, and the route adapter
never sees anything but a string and a coordinate — is what keeps the privacy promise structural.

Where it plugs in: `TravelPreferences.minutes(to:)` is the single question the page asks today.
An ETA should arrive as a *better answer to that question*, not as a second code path — the row, the
sheet and the block already read it.

#### Should the Mac get this switch too? Not yet, and the reason is not caution

Asked because `TravelPreferences` sits in `ElephruitFeaturesCore` and `MapKitRouteProvider` in
`ElephruitIntegrations` — both shared, both linked by the Mac already, so a Settings row would be
an afternoon. It should still wait, because **the prerequisite is missing rather than the plumbing.**

Route estimates is not a feature on its own. It is a better answer to "when should I leave", and on
the Mac nothing asks that question. Every caller of `TravelPreferences` and `TravelRules` is a phone
file — `ElephruitiOS/Screens/TodayScreen.swift` and `BlockTimeSheet.swift`. The Mac has the whole
Today feature in `ElephruitFeatures/TodayView.swift` and its rows show an event's location
(`TodayRows.swift:180`), but no leave-by line, no journey, and no travel block. A switch shipped
into that would change nothing a user could see, which is the worst kind of privacy control: it
asks somebody to weigh a real cost against no benefit.

So the order is: **port the leave-by line to the Mac's Today first** — §3.4's work, which needs only
`TravelPreferences` and a default-minutes setting, no permission and no network — and only then is
there something for an estimate to improve. If that port is never wanted, the answer to this
question is a permanent no rather than a deferral.

Two costs that only exist on the Mac, worth knowing before the port is scheduled:

- **Location is a sandbox entitlement here, not just a usage string.** `Configuration/Elephruit.entitlements`
  lists Location under "Deliberately ABSENT", and that list is the app's own record of restraint.
  On iOS the same feature costs a usage string and TCC. The Mac would be spending something the
  phone did not have to spend.
- **A Mac is more often the thing you are travelling *from* than the thing you carry.** A desktop's
  answer to "how long from here" is right for the office it is sitting in and wrong for anywhere
  else, in a way a phone's never is.

### 3.6 The blocks view — blocked on a decision

Ask 3 was "options to adjust to show blocks". Deferred; the owner is undecided between a proportional
rendering of the same list (each row's height reflecting its duration) and a phone-width port of the
Mac's `CalendarTimeGrid`, which is its own project. **Do not build a toggle until this is answered.**

---

## 4. How to work on this

**Look with `Scripts/shot.sh`, assert with tests.** It installs the built app, launches it with the
fixture arguments, and photographs it — **5.5 seconds**, no simulator lock, no build.

```bash
Scripts/shot.sh /tmp/today.png
```

**Development launch switches**, all inert without `-ElephruitDevelopmentMode`. They exist because a
state that can only be reached by a thumb is a state nobody looks at until it ships:

```bash
Scripts/shot.sh /tmp/sheet.png -ElephruitTodayBlockSheet gap    # or: work
Scripts/shot.sh /tmp/past.png  -ElephruitTodayEarlierDays 21
```

Each is **one-shot per launch**. Both were written as flag-driven and both broke something: a sheet
that reopened over the page it was meant to reveal, and a past that reopened when somebody pressed
"Today". Anything added here must fire once.

**Tests go through the harness**, which serialises against every other worktree:

```bash
ELEPHRUIT_SCHEME=ElephruitiOS ELEPHRUIT_DESTINATION='platform=iOS Simulator,name=iPhone 17 Pro' \
    Scripts/xctest.sh test -only-testing:ElephruitiOSUITests/TodayScreenUITests
```

Redirect the output to a file rather than piping it through `head` — `head` closes the pipe, the run
dies on SIGPIPE, and the result bundle is left unfinalised and unreadable. **A failing UI test's
result bundle cannot be exported at all**, which is exactly when the screenshots are wanted; that is
the argument for the launch switches above.

`swift test` in `Packages/ElephruitKit` needs none of this. `SearchSessionTests` fail under the full
package run and pass alone — a known flake, nothing to do with this page.

### Five traps, each already paid for

1. **`EmptyView` takes no part in layout.** Fixed centrally in `TimelineRow`; do not undo it.
2. **A `ZStack`'s alignment is two axes.** `.trailing` centres vertically.
3. **Match content by text, chrome by identifier.** A title is content; a header is chrome.
4. **A `List` only realises cells near the viewport.** Anything below the fold is absent from the
   accessibility tree; scroll to it first. This has now broken four tests, twice after a layout
   change made a day taller, and once because a test written before lunch was run after it.
5. **A `List` recycles what it scrolls past, and modifiers differ on it.** `onScrollVisibilityChange`
   never fires for a `List` row at all. Geometry read from a recycled row keeps answering with its
   last value forever. `onAppear`/`onDisappear` are the signals that survive.

### Verification standard

Every visible step is photographed before it is committed. Nine defects in this work so far were
caught by looking and by nothing else — a toggle rendering at 0×0, a leading column collapsed by
`EmptyView` twice, a `ZStack` centring, a day header whose tap target covered only its text, a
timestamp printed twice, a sheet that said "there is no calendar" because it asked a beat too early,
a form invisible below a half-height sheet, and a "back to now" pill that never appeared. None of
them would have failed a build or a test.

---

## 5. What §3.2 cost, and why it is written down

Four wrong turns, in the order they happened. Three are traps rather than mistakes — anything
scroll-driven on this page will meet them again.

1. **Proximity paging in both directions runs the window to its ceiling in one gesture.** Each load
   leaves the reader where they were with the new days above them, so "near the top" is true again
   immediately, and a week of clear days is barely four hundred points tall. The top pages on being
   *reached* instead.
2. **Do not restore the scroll anchor by hand.** The `List` already holds the visible row still and
   grows upward behind it. A hand-written restore re-pins the reader to one row every time a week
   loads, which turns scrolling into the past into hitting a wall. This was proved by accident: a
   scroll to yesterday appeared to do nothing because the list had not moved in the first place.
3. **A row's position cannot answer "is today on screen".** See trap 5 above. The signal that works
   is which day *arrived* most recently, which also gives the direction by comparing dates.
4. **"Back to today" must not reset the window on the way.** Collapsing the history while the scroll
   to today is still in flight lands the page wherever the collapse left it.
