# 36 — Today: the work that is left

Written to be handed to a fresh thread. Self-contained: you do not need the conversation that
produced it. The design record is [35](35-today-information-center-plan.md); this is what remains of
it plus what has been decided since.

Branch: `claude/today-view-remaining-work-62cc78`, off `013ed730` (the merge of PR
[#75](https://github.com/Elephruit/Elephruit-app/pull/75)).

**Everything this document asked for is now built.** §3.5 shipped on
`claude/travel-real-eta-631378`; see §3.5 below for what it actually became. §3.6 is still blocked on
a decision that is not mine to make, and is the only thing left in this file.

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

### 3.5 Travel, 7b — real ETA, opt-in — **done**

Built as planned, on `claude/travel-real-eta-631378`. `MKGeocodingRequest` rather than
`MKLocalSearch` — it is the iOS 26 API for turning an address into a place — and the optional
coordinate carry became compulsory, because skipping the geocode for a place the organizer already
resolved is strictly less guessing. It rides on `CalendarEventSummary`; `EventDraft`'s allowlist is
untouched, so the app can be *told* where a meeting is and still cannot write a coordinate.

`TravelPreferences.minutes(to:)` kept its signature exactly. The ordering lives in one method — a
fresh measurement, then what the user said, then the default — and every step down is silent.
`travel(to:)` is the richer answer for the one caller that needs the provenance.

| File | What it is |
|---|---|
| `Packages/.../ElephruitCore/Route.swift` | `RoutePlace` (the closed query), `RouteRules`, `RouteEstimate`, `RouteFailure`, `TravelNumber`, `RouteTransport` |
| `Packages/.../ElephruitIntegrations/Routing.swift` | `RouteProviding` + `NoRouteProvider` |
| `Packages/.../ElephruitIntegrations/MapKitRouteProvider.swift` | The adapter. The only file no test reaches |
| `Packages/.../ElephruitIntegrations/FixtureRouteProvider.swift` | Answers for street addresses, refuses for rooms |
| `Packages/.../ElephruitFeaturesCore/TravelPreferences.swift` | The ordering, the estimate cache, the remembered refusals, the switch |
| `Tests/ElephruitCoreTests/RouteSafetyTests.swift` | The field list, the query's arguments, the confined import |

Four things worth carrying forward:

1. **Refusals must be remembered, not just successes.** A `List` redraws on every scroll, a meeting
   room never geocodes, and the room is what appears in a calendar five days a week. Caching only
   the answers leaves the commonest case asking forever. Half a day for a place that does not exist,
   five minutes for a service that was merely unreachable.
2. **Measure the whole day, never per row.** Per row looks right — `.task` follows the row's life —
   but a `List` does not realise cells below the fold, so an evening journey stays unmeasured until
   it is scrolled to and then changes under the thumb. Worse, the block sheet reads the number when
   it opens, so a journey reached any other way books the guess. Trap 4 again, in a new costume.
3. **A review launch has to open its sheet after the work, not alongside the assembly.** The travel
   sheet was photographing the guess the page was about to replace.
4. **Giving a `Toggle` an accessibility identifier collapses the row into one wide `Switch`**, so
   `tap()` aims at the label and nothing happens. See `flip` in `RouteEstimateSettingsUITests`.

The Settings copy was rewritten in the same commit, as required. The iCloud and About claims are now
true in *both* states rather than following the switch — a privacy claim you have to watch is not
worth having. **The Mac's `Elephruit/SyncSettingsSection.swift` still carries the old claim, and it
was already false there** for an unrelated reason: `MapPlaceSearchField` searches Apple Maps when
somebody types a venue into an event. Route estimates have no macOS switch and cannot be turned on
there, so this is a pre-existing inaccuracy rather than a new one — but it is still wrong.

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
Scripts/shot.sh /tmp/sheet.png -ElephruitTodayBlockSheet gap    # or: work, travel
Scripts/shot.sh /tmp/past.png  -ElephruitTodayEarlierDays 21
Scripts/shot.sh /tmp/eta.png   -ElephruitUseFixtureRoutes       # measured travel, no real location
```

The first two are **one-shot per launch**. Both were written as flag-driven and both broke something:
a sheet that reopened over the page it was meant to reveal, and a past that reopened when somebody
pressed "Today". Anything that *opens* something must fire once.
`-ElephruitUseFixtureRoutes` is a different kind of switch — it chooses a provider for the whole run,
exactly as `-ElephruitUseFixtureCalendar` does — and so is deliberately not one-shot.

**`shot.sh` cannot scroll**, which is most of why the launch switches exist. For a screen it cannot
reach on the phone, the iPad shell routes by name and draws the same views:

```bash
ELEPHRUIT_SIM="iPad Pro 11-inch (M5)" Scripts/shot.sh /tmp/settings.png -ElephruitPadRoot settings
```

**Tests go through the harness**, which serialises against every other worktree:

```bash
ELEPHRUIT_SCHEME=ElephruitiOS ELEPHRUIT_DESTINATION='platform=iOS Simulator,name=iPhone 17 Pro' \
    Scripts/xctest.sh test -only-testing:ElephruitiOSUITests/TodayScreenUITests
```

Redirect the output to a file rather than piping it through `head` — `head` closes the pipe, the run
dies on SIGPIPE, and the result bundle is left unfinalised and unreadable.

**Correction to an earlier note here: a failing UI test's result bundle *can* be exported.** This
document previously said it could not, and that cost the travel work two blind runs. It works:

```bash
xcrun xcresulttool export attachments --path <newest>.xcresult --output-path /tmp/att
```

Read `/tmp/att/manifest.json` for the mapping from exported filename to attachment name. It carries
the screenshots *and* — the thing that actually solved the toggle — the "Debug description for
`<element>`" text files, which print each element's frame. When a tap lands and nothing happens, that
frame is the answer.

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
