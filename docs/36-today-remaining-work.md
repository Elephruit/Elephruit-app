# 36 — Today: the work that is left

Written to be handed to a fresh thread. Self-contained: you do not need the conversation that
produced it. The design record is [35](35-today-information-center-plan.md); this is what remains of
it plus what has been decided since.

Branch: `claude/ios-today-view-redesign-8b7a0f`, twelve commits on `cb29c20b`, merged with `main` at
`0eb9592a`. PR [#75](https://github.com/Elephruit/Elephruit-app/pull/75).

---

## 1. Where the page is now

Today is one continuous thread down the left, scrolling from this morning into next month. Every row
has the same skeleton, and keeping that skeleton is the whole reason the page reads as one thing:

| Column | Says | Examples |
|---|---|---|
| Leading | *when, or who* | a time, a completion circle, a face. **Never a title.** |
| The rail | *what kind of thing this is* | one badge on the line |
| Content | everything else | title, location, conflict, reason |

Built, verified, committed:

- **Workday hours**, settable on the phone, store-backed so they sync, overridden by a calendar set
  while one is active. Schema 0.0.17.
- **Free time** as `DayFreeSlot` values, drawn as a *dashed stretch of the thread* — free time is the
  absence of an entry, and a break in the line says so before a word is read. Behind a persisted
  switch in the Schedule header.
- **Awareness band** — all-day, multi-day and away entries above the schedule, with "Day 2 of 4".
- **The briefing figure** with a denominator: "5h 15m free of 7h 40m", the denominator being what is
  *left*, not the whole day.
- **People grouped by the thing that gathers them** — a meeting is one row with overlapping faces;
  opening it gives each person their role, history and facts.
- **The feed** — days after today arrive a week at a time on scroll geometry, to a ninety-day
  horizon; tapping a day opens it in full, drawn by the same builder that draws today.

### The files

| File | What it is |
|---|---|
| `ElephruitiOS/Components/Timeline.swift` | The rail: `TimelineRow`, `TimelineHeader`, `Timeline.Badge`, the geometry constants |
| `ElephruitiOS/Components/PeopleGathering.swift` | Grouping rule + the meeting-with-faces row |
| `ElephruitiOS/Screens/TodayScreen.swift` | Assembly, `daySections(_:isAnchor:)`, scroll paging |
| `ElephruitiOS/Screens/TodayFeed.swift` | Day marker, compact summary lines, footer |
| `Packages/.../ElephruitCore/DailyPlan.swift` | `DayFreeSlot`, `awarenessEvents`, `scheduleEvents`, `proportionSummary` |
| `Packages/.../ElephruitFeaturesCore/TodayModel.swift` | Horizon, `extendFuture()`, `isExtendingFuture` |
| `Packages/.../ElephruitPersistence/WorkdayService.swift` | Workday resolution order |

---

## 2. Decisions already made — do not re-litigate

1. **iPhone Today only.** The Mac keeps its two-column page.
2. **A future day is a summary; tapping opens it in full**, drawn by `daySections(_:isAnchor:)`.
   "In full" must mean the *same* full or a day means different things depending on where you found
   it. Empty days are shown, not skipped.
3. **Travel is staged**: 7a ("leave by", no network) then 7b (real ETA). **7b is approved** with its
   cost understood — the Settings copy promising CloudKit is the only network destination has to be
   rewritten in the same commit that adds the switch.
4. **A block written for a todo offers busy *or* free, per block.** Not a fixed default — the sheet
   asks. See §3.1 for what that implies.
5. **Past days load only on scroll-up**, nothing pre-loaded beyond a day or two.
6. **A past day dims *and* its rail fades.** Both.
7. **Two ways back to now**: the toolbar button *and* a floating pill.
8. **The blocks view is deferred** — the owner is undecided. Do not add a `TodayFilters` switch for
   it until there is something behind it.

---

## 3. The work, in order

### 3.1 Blocking time for a todo, and filling a free slot — *do this first*

The two halves of one idea, and the payoff for everything already built: the free slots are drawn and
tapping one currently does nothing.

**Tapping a free slot** opens a sheet offering, in this order:

1. Today's unscheduled work, longest-fitting first — the todos already on the page with no `pinnedAt`.
2. **Block this time** — a plain focus block.
3. **Add a reminder** — `TodayActions.createTask(titled:on:)` with the slot's start as a timed reminder.

**The sheet** names the calendar, the length, and — decided — **shows-as: free or busy**, per block.

```
Block 11:30 – 12:30
  Calendar    Work ▾
  Shows as    ( Free | Busy )
  Length      1h ▾
  [ Add to calendar ]
```

**Reached from** a trailing swipe action and the context menu on the To-do rows as well as the slot
sheet. `TodayTaskRow` is Today's own row now, so it may gain affordances freely.

**Length**, in order: the task's own estimate if it has one, else the slot capped at one hour, else
30 minutes. Shown and changeable before the write. Never guessed silently.

**What is written.** `EventDraft(title: task.displayTitle, availability: chosen, …)` and **nothing
else from the task** — no notes, no project, no people. `EventDraft`'s field list is guarded by
`CalendarWriteSafetyTests.draftCarriesNothingPrivate`; **this work adds no field to it.**

**The link back is local**: on success, `services.eventLinks.link(record: task, to: event)`. The
calendar account never sees it. That is what `EventAnnotation` is for.

**Undo.** The confirmation says what was written and offers to remove it. The fastest way to make
somebody distrust this button is for the first block to be wrong and hard to delete.

**One consequence to handle deliberately:** a block written as *busy* reduces the free time it was
created from, so the page rearranges under the thumb that just wrote it. That is honest, but it must
not read as a glitch — animate the change, and do not let the sheet's dismissal and the reassembly
land in the same frame.

**Tests:** proposal arithmetic (fit, cap, fallback, no free time at all); a draft carrying only the
permitted fields; the annotation link surviving; a `CalendarWriteFailure` surfacing as a message
rather than a silent no-op.

**Commits:** *Let a todo claim a block of the day.* / *Let a gap take work.*

### 3.2 Backwards through the feed

Today is the top of the page and the past is above it, on demand.

- **Arrival:** nothing pre-loaded beyond a day or two. Scrolling *up* past today pulls in earlier
  days — the mirror of `extendFuture()`, with the same guard against asking while a request is
  outstanding, and its own horizon. `TodayModel` already has `previousDays`, `isShowingPreviousDays`
  and `showPreviousDays()`.
- **Reading as past:** dim the whole day *and* fade the rail above today. Both were chosen.
- **Scroll anchoring is the hard part.** Inserting content *above* the viewport moves everything
  under the thumb unless the list is anchored. Use `.defaultScrollAnchor` / `scrollPosition` so the
  day being read stays still while earlier days arrive above it. Expect this to be where the time
  goes, and verify by screenshot rather than by reasoning.
- **Back to now:** both the toolbar button (extend the existing one, which today appears only when
  the *anchor* changed, to also appear when today is scrolled out of view) and a floating pill that
  says which way to go — "↑ Today" when ahead, "↓ Today" when behind.
- **The horizontal day-swipe** should be reconsidered here: forward-swipe is largely redundant once
  the next day is simply further down.

### 3.3 People insights

Cheapest remaining win — `DayPerson` already carries everything and the expanded rows draw part of
it. Add `lastContact` as a sentence ("Last spoke 3 weeks ago"), `openTaskIDs.count` ("2 open items
with them"), and up to three `quickFacts` rather than one.

Two rules carried, not reinvented: honor `CalendarSetDefinition.showsPersonContext` (off for a set
somebody might screen-share), and never infer a fact. `DailyPlanService.quickFacts(from:)` already
filters for sensitivity — a briefing surface is the screen most likely to be visible to somebody else
in the room.

### 3.4 Travel, 7a — "leave by", no network

- An event qualifies when it has a `locationName` that is **not** a conferencing link. The test
  exists: `MeetingLink.url(in:)` reads the location field looking for exactly that.
- Duration comes from the user, not a server: a default buffer in Settings, remembered **per location
  string**, so the second meeting in "Room 2" already knows.
- Drawn as a subordinate line under the event — "Leave by 9:45 · 15 min" — with an action that writes
  a travel block through §3.1's machinery.
- The fixture calendar needs a couple of events with real-looking physical locations.

### 3.5 Travel, 7b — real ETA, opt-in

Approved, with the cost understood.

- **Needs:** `NSLocationWhenInUseUsageDescription`, `CoreLocation`, `MKLocalSearch` to resolve the
  location string, `MKDirections.calculateETA`. Optionally carry EventKit's `structuredLocation`
  coordinate onto `CalendarEventSummary` — a *read* type, so `EventDraft`'s allowlist is untouched —
  to skip geocoding when the organizer set a real place.
- **Its own switch**, off by default, in Integrations beside Calendar and Reminders. When off, none
  of the frameworks are touched.
- **Only the location string and coordinates ever leave the device.** Never a title, an attendee, a
  note.
- **The Settings copy about CloudKit being the only network destination must be rewritten in the same
  commit.** Shipping the switch without it makes the app's own privacy statement false.
- Never automatic. Travel is a proposal like everything else here.

### 3.6 The blocks view — blocked on a decision

Ask 3 was "options to adjust to show blocks". Deferred; the owner is undecided between a proportional
rendering of the same list (each row's height reflecting its duration) and a phone-width port of the
Mac's `CalendarTimeGrid`, which is its own project. **Do not build a toggle until this is answered.**

---

## 4. How to work on this

**Look with `Scripts/shot.sh`, assert with tests.** It installs the built app, launches it with the
fixture arguments, and photographs it — **5.5 seconds**, no simulator lock, no build. The
`xcodebuild test` it replaces is minutes. A test is for asserting something; when the question is
"what does it look like now", do not run one.

```bash
Scripts/shot.sh /tmp/today.png
```

**Tests go through the harness**, which serialises against every other worktree — the collision that
bites is not derived data (Xcode isolates that by project path) but the simulator, since every
worktree targets the same devices and the app has one bundle identifier:

```bash
ELEPHRUIT_SCHEME=ElephruitiOS ELEPHRUIT_DESTINATION='platform=iOS Simulator,name=iPhone 17 Pro' \
    Scripts/xctest.sh test -only-testing:ElephruitiOSUITests/TodayScreenUITests
```

Scope to the method you are iterating on; run the target once, at the end. Each XCUITest relaunches
the app, so every test method is a permanent tax.

**Before merging**, `Scripts/premerge.sh` builds the branch *merged with main* in a throwaway
worktree. The iPad is the reliable victim: `ElephruitiOS/Pad/` reuses phone views, it is newer than
most branches, and a `grep` for a view's callers in a worktree that predates it finds nothing and
reports the view as unused.

### Four traps, each already paid for

1. **`EmptyView` takes no part in layout.** A `.frame(width:)` around one is discarded and the column
   collapses. You do not have to *pass* `EmptyView` to hit this — an `if` with no `else` is enough.
   `TimelineRow` now backs its leading column with `Color.clear`, so this is fixed centrally; do not
   undo it.
2. **A `ZStack`'s alignment is two axes.** `.trailing` centres vertically. Against a tall row a
   centred time drifts into the middle of a block it is meant to label the top of.
3. **Match content by text, chrome by identifier.** A reminder's title is content and matching it is
   the test doing its job. A section header is chrome, and chrome is what gets restructured — adding
   a control to a header stopped it being a `StaticText` at all. Three misleading thirty-second
   timeouts came from getting this backwards.
4. **A `List` only realises cells near the viewport.** Anything below the fold is absent from the
   accessibility tree; no timeout conjures it. Scroll to it first.

### Verification standard

Every visible step is photographed before it is committed. Six defects in the work so far were caught
by looking and by nothing else: a toggle rendering at 0×0 that nobody could press, a leading column
collapsed by `EmptyView` (twice), a `ZStack` centring every time against its row, a day header whose
tap target covered only its text, and a timestamp printed twice on one line. None of them would have
failed a build or a test.
