# 29 — Time tracking, focus, reports, and the settings rebuild

What was built, what it refuses to do, and what was deliberately left.

---

## What is there

| Area | Where |
|---|---|
| Participants, rounding, periods, grouping | `ElephruitCore/TimeTracking.swift`, `TimeReporting.swift` |
| The focus-cycle state machine | `ElephruitCore/Pomodoro.swift` |
| What a calendar write may contain | `ElephruitCore/TimeMirroring.swift` |
| CSV, both shapes of it | `ElephruitCore/TimeExport.swift` |
| People, project, focus count, mirror ids | `ElephruitModel/TimeEntry.swift`, schema `0.0.9` |
| Repository writes and reads | `ElephruitPersistence/TimeEntryRepository.swift` |
| The running timer and the focus cycle | `ElephruitPersistence/TimerService.swift` |
| The tracker card and its pickers | `ElephruitFeatures/TimeEntryBar.swift`, `TimePickers.swift` |
| The focus strip and its banner | `ElephruitFeatures/FocusControls.swift` |
| The log | `ElephruitFeatures/TimeView.swift`, `TimeEntryEditing.swift` |
| Reports, chart, export | `ElephruitFeatures/TimeReportView.swift` |
| The calendar mirror | `ElephruitFeatures/TimeCalendarMirror.swift` |
| Time preferences | `ElephruitFeatures/TimeSettingsView.swift` |
| Appearance preferences | `ElephruitFeatures/AppearanceSettings.swift` |
| The settings window | `Elephruit/ElephruitApp.swift` |

---

## The decisions worth keeping

### People are a relationship, not a tag

A `with-sarah` tag has no identity. It does not follow a rename, does not survive merging two
duplicate contacts, cannot be clicked through, and a report grouped by it lists strings rather than
people. All four already work for an `Item` of kind `person`, so standing rule R5 goes the other way
here: what was missing was never a new stored shape, only a way to point at the one that exists.

`people` is its own relationship rather than more uses of `item` because the two mean opposite
things. Time filed *against* a person is time spent on them — writing their review, preparing their
onboarding. Time *with* a person present is time spent alongside them. One list holding both makes
"time on Sarah" and "time with Sarah" the same number and neither answerable.

### Rounding never touches the store

An entry that ran for fifty-one minutes ran for fifty-one minutes. A store holding fifty-four because
somebody once invoiced in tenths of an hour has lost the only number that could settle a dispute. So
`TimeRounding` applies to a report row, an export column, a copied total — and the report's own total
rounds *once*, independently, rather than by adding rounded rows together. Rounding per entry would
bill eight two-minute interruptions as forty-eight minutes, which is not what anybody means.

### The project is derived unless it is stated

Walking up from the subject is what makes time-by-project answerable without filing anything twice,
and it stays the normal path. `TimeEntry.project` carries only what the walk cannot reach — an hour
on a note, a meeting, or nothing at all, worked on for a project it does not sit inside — and when
set it wins, because an explicit answer outranks a derived one.

The consequence that bit: an editor must be filled from an *explicit* project only.
`TimeEntrySnapshot.isProjectExplicit` exists for that. Prefilling from a derived one and saving would
pin it, and the entry would stop following its task the next time that task moved — to every entry
anybody so much as corrected a typo on.

### A focus cycle is not persisted

A pomodoro is a fact about the next twenty-five minutes of your attention. Restoring one an hour
after the app quit would ring a bell for a block nobody is working. The *time* it produced is
durable, because that goes to entries as it happens; the intention behind it is not.

Three rules the cycle enforces, each of which is a way the naive version lies:

- **A break stops the timer.** A day whose totals include forty minutes of coffee makes every number
  on the screen an estimate.
- **Skipping a block does not count it.** A streak the app hands out for pressing Skip measures
  nothing.
- **Idle detection is silent during a break.** Asking where you went is the app noticing its own
  instruction being followed.

And one asymmetry: breaks start themselves, work does not. An ignored break costs nothing; work that
starts by itself begins a timer against your name while you are still in the kitchen, and writes an
entry somebody has to find and correct later.

### The calendar mirror is outbound only, and lossy on purpose

An event edited in Calendar.app does not change the entry it came from and never will. The entry is
the record; the event is a copy. Two writable copies of the same hour is the failure
`docs/03-storage-matrix.md` exists to prevent.

Three things never cross, whatever the settings say, and `TimeMirrorFields` has nowhere to put any of
them:

- **People.** An hour with somebody is a fact about *them* as much as about you. An event syncs to
  every device on the account and is visible to everybody a calendar is shared with — an audience
  they never agreed to.
- **Notes and bodies.** Whatever an item says is why it lives here rather than in a calendar.
- **Billability and rates.** What you charge is not something to leave in a shared diary.

`TimeMirroringTests` asserts a name cannot reach either the title or the notes with every option
turned on. Mirrored events are free rather than busy, carry no alarm, and are never written for a
date in the future.

Turning the mirror off leaves everything it wrote in place. Deleting a month of somebody's calendar
deserves its own button, its own confirmation, and its own count — not a side effect of a toggle.

### Phase endings do not use Notification Center

That needs a permission this app has never asked for. Asking for notification access is a decision
with its own settings row and its own explanation of what will and will not be sent, not something to
acquire as a side effect of a focus timer. A sound and a bouncing icon reach somebody in another app,
which is the case that matters; the banner says what happened when they come back.

**This is the obvious next slice.** If it is built, it needs: the entitlement note in `docs/06`, a
settings row that says exactly which events post and which do not, and a test that no notification
body ever contains a subject title — the same guarantee the calendar mirror already keeps.

---

## What is deliberately not there

- **No rollup table.** A week is a few hundred rows and a year-by-project report a few tens of
  thousands, both fast enough over a date-bounded fetch. A derived `TimeDayRollup` would be a second
  source of truth maintained for no measured benefit.
- **No reading back from the calendar.** See above.
- **No streaks, badges, or focus history.** The count of finished blocks is on the entry, where it
  can be reported on honestly. It is not a score.
- **No day target across a week.** Five days times a daily figure minus whatever the user counts as a
  working day is a guess, and guessing is how a tracker starts telling somebody they are behind on a
  Sunday. The bar appears for a single day, and only when a target was set.
- **No sidebar density preference.** It would mean threading a stored value through ten
  `@ScaledMetric` call sites; the system text-size setting already scales every one of them.

---

## Known loose ends

- **Not reviewed on screen.** Every claim above is from the source and the tests. The module has not
  been looked at in either appearance, and the report chart in particular has never been drawn with
  real data in front of a person.
- **`Color.<name>` literals survive elsewhere.** `coloursComeFromTheDesignSystem` scans for
  constructors like `Color(red:)` and does not catch `Color.pink`. The pink child cards were one
  instance; `PersonCaptureSheets`, `PersonWorkspaceView`, `CalendarTimeGrid`, and
  `CalendarOverviewViews` still hold others. Extending the scan is a one-line change and a
  many-line fix, and it wants doing as its own piece of work rather than inside this one.
- **`PersonActionAvailabilityTests` fails on `main`** and still fails here — a phone-formatting
  expectation, untouched by any of this.
