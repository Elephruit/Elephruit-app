# Phase C — Time tracking: what was built and what was proven

---

## 1. The one exception to "everything is an Item"

`TimeEntry` is its own entity. Every other thing a user thinks about in Elephruit is an `Item`; this
is the first considered departure, and it was made deliberately rather than drifted into.

A time entry has no title, no body, no children, cannot be linked to and cannot be filed. More
decisively, they arrive by the hundred thousand. As `Item`s they would flood the Inbox, the search
index, every sidebar count, and every list that did not explicitly exclude them — and each of those
exclusions would be a place to forget.

So it points *at* an item instead of being one. A timer can also run against nothing at all, because
the alternative is filing something before you are allowed to start, and that is the friction that
stops people tracking.

---

## 2. The invariant

**At most one entry has `endedAt == nil`.**

It lives in `TimeEntryRepository`, not on the type, because it is a statement about the whole store.
Every path that could break it either refuses or resolves explicitly:

| Path | What it does |
|---|---|
| `start` | Refuses if one runs, and names what is running |
| `switchTo` | Stops the current one and starts another, as one action |
| `resume` | Switches — continuing something is what you do *instead* of what you were doing |
| `restore` a discarded running entry | Closes it at the moment it was discarded |
| Recovery after a crash | The user chooses; nothing resolves itself |
| Two devices | The earlier is closed where the later began; nothing is deleted |

`start` refusing rather than silently stopping is the point. A running timer is a record of what
someone is doing, and quietly ending it is exactly the kind of unrequested consequential decision
this app does not make. The caller that means "switch" says so.

---

## 3. Crash, sleep, and the three-way choice

A heartbeat is written every thirty seconds while a timer runs, and once more on
`NSWorkspace.willSleepNotification`.

Without it, a timer found running after a crash offers only two honest options — count the whole gap
or throw it away — and both are usually wrong. With it, the app can say *"it was definitely running
until 14:22"*, which is the only version where someone can answer without guessing.

At launch, a timer silent for more than five minutes produces:

> A timer for **Drafting the brief** was running when Elephruit last quit.
> 30m is accounted for, and 3h is not.
> **Stop at 14:22** · **Keep Running** · **Discard** · *Not Now*

Four ways out, and the app takes none of them itself. Each destroys something different — time,
accuracy, or a record — and which of those matters is not something the app can know.

**"Not Now" is a real option.** The timer is left exactly as it was and offered again next launch.
Not deciding is a legitimate answer to a question about the past, and forcing a choice in order to
close a banner is how someone discards a day's work by reflex.

**Sleep gets the same treatment, and matters more**, because it is ordinary. Shut the lid at 18:00,
open it at 09:00, and the fifteen hours are offered for a decision rather than quietly billed.

---

## 4. What is verified

| Property | Test |
|---|---|
| A second timer cannot start while one runs | `secondTimerRefused` |
| The refusal names what is already running | `refusalNamesTheRunningTimer` |
| Switching closes the first and starts the second | `switchingIsOneAction` |
| An entry can never end before it starts | `durationCannotGoNegative`, `editingCannotInvert` |
| Restoring a discarded running entry keeps the invariant | `restoringDoesNotBreakTheInvariant` |
| Two devices reconcile without deleting anything | `reconcileClosesRatherThanDeletes` |
| Three concurrent timers collapse into a chain | `reconcileHandlesMoreThanTwo` |
| Deleting an item keeps the hours worked on it | `deletingAnItemDoesNotDestroyTime` |
| Time on a task rolls up to its project | `timeRollsUpToTheProject` |
| An entry spanning midnight belongs to both days | `overlapRatherThanContainment` |
| **A crashed timer is offered for recovery** | `crashOffersRecovery` |
| **Nothing is decided on the user's behalf** | `recoveryIsNeverAutomatic` |
| A recently-beating timer is not disturbed | `freshTimerIsNotOfferedForRecovery` |
| Each of the three choices does what it says | `stopAtLastActivity`, `keepRunning`, `discardIsSoft` |
| Dismissing changes nothing and asks again | `deferringIsAllowed` |
| An entry with no heartbeat degrades to its start | `missingHeartbeatDegradesGracefully` |
| Two running timers are reconciled at launch | `launchRepairsTheInvariant` |
| A populated library survives the migration | `existingDataSurvives` |
| Time tracking works on a library that predates it | `timeTrackingWorksAfterMigrating` |
| A backup is written, and it opens | `migrationIsBackedUp` |
| Memoised project resolution agrees with the slow path | `snapshotsMatchIndividualResolution` |
| A session across midnight splits between days | `midnightIsSplit` |
| Two tags count in full under each, total does not double | `tagsCanOverlap` |
| A report clips to its window | `clippingToTheWindow` |

### How the crash is produced

By writing the state a crash leaves behind — a running entry with a stopped heartbeat, in an on-disk
store, read back through a fresh container. That is precisely what `kill -9` during a timer leaves,
because the process dies without stopping anything.

**The limit, stated:** no real process is spawned and killed. What is proven is that the on-disk
state a crash produces is detected and recoverable. What is not proven is that no *other* state can
result from a kill at some unlucky instant; autosave and the single-transaction writes in
`TimeEntryRepository` are what bound that.

---

## 5. Performance, and the table that was not built

A `TimeDayRollup` derived cache was designed for in `docs/09` and deliberately **not** built, on the
grounds that a week touches a few hundred rows. The benchmark exists to check that claim rather than
assert it.

Measured over a **200,000-entry, three-year history** — the size the published criterion names:

| Report | Budget | Measured | |
|---|---|---|---|
| **Week, by project** — the published criterion | 50 ms | **47.1 ms** | ✅ |
| Day, by item | 50 ms | **22.7 ms** | ✅ |
| Month by project — the widest the app offers | 200 ms | **126.2 ms** | ✅ |
| "Is anything running?" | 5 ms | **0.04 ms** | ✅ |
| A year by project | *recorded, not budgeted* | ~1.5 s | — |

**The rollup table stays unbuilt.** Every report the interface can actually produce is well inside
budget, and a second source of truth maintained for no measured benefit is worse than the arithmetic.

### Why the year figure is recorded rather than asserted

It *was* a 400 ms budget, and it failed at 1.5 s. That looked like a defect until the obvious
question: nothing in the app asks for a year. `TimeWindow` offers today, yesterday, this week, last
week, and this month — that is the whole set. A budget on a report the product does not have is not
a criterion; it is a number invented to be missed.

So it is kept as a measured characteristic, because it answers something worth knowing: reports cost
roughly linear time in the entries they read, so this is the scale at which the rollup table stops
being optional. The condition for building it is now a number rather than a feeling.

**This is not the same as moving a budget.** The week report — the one `docs/09` published and the
one the product has — is asserted unchanged at 50 ms, and passes.

---

## 5a. The index that was not being used

"Is anything running?" took **7.1 ms** over a 200,000-entry store. It is asked at every launch, on
every timer command, and every thirty seconds for the heartbeat.

Four fixes were tried and **none of them worked**:

1. Adding `#Index` on `endedAt`, `deletedAt` and `startedAt` as three single-column indexes
2. Dropping the `ORDER BY`, on the theory that the sort was choosing the wrong index
3. Fetching through a fresh `ModelContext`, on the theory that the fixture's 200,000 registered
   objects were being reconciled on every fetch
4. Moving the fixture from an in-memory store to disk, on the theory that in-memory stores have no
   B-tree

What settled it was not another theory but a measurement: **the same query at two store sizes.**
0.73 ms at 20,000 entries, 7.1 ms at 200,000. Ten times the rows, ten times the cost — a scan, and
therefore an index genuinely not being used rather than fixed overhead somewhere.

The fix was one line. A **compound** index on `(endedAt, deletedAt)` — exactly the pair the predicate
`AND`s together — instead of separate indexes on each column:

```
7.1 ms  →  0.04 ms
```

A hundred and seventy-five times faster. The general rule, learned expensively: **an index has to
match the shape of the predicate, not the list of columns that appear in one.**

The second finding was smaller but the same species. Resolving each entry's project independently
made a year of history take 1.9 s, because tens of thousands of entries walked their parent chains
to arrive at a few hundred distinct answers. Memoised per item — with a test asserting the fast path
returns exactly what the slow one did, since a cache that disagrees with what it replaced is worse
than the cost it saved.

---

## 6. Where it lives in the interface

**The menu bar carries the elapsed time as its label**, not just an icon. The whole reason to be up
there is to answer "how long has this been going" without a click — a timer you can only see by
switching to Elephruit is one you forget is running, and a forgotten timer is how eleven hours get
billed to a task that took two.

**Time is in the Library band of the sidebar**, not the top one — the decision of record. The top
band is for what you are doing now; time is something you look back at.

**The start/stop control lives on the item.** One button that shows what pressing it will do. Timing
something else switches rather than refusing, because a button that reports an error when pressed is
not one anyone presses twice.

**Entries are edited in place**, not in a sheet. Correcting time is the most common thing anyone does
with it — you stopped twenty minutes late, or forgot to start — and a sheet for a two-minute
correction turns a habit into a chore.

**Manual entry is not a convenience.** A tracker that only accepts time it watched happen gets
abandoned the first afternoon someone forgets to press start.

---

## 7. Not built in Phase C

- **Estimate vs actual.** `Item` has no estimate field yet; adding one is a schema change and was not
  worth bundling into this one.
- **Billing rates.** `rateMinorUnits` and `currencyCode` exist on the entity and nothing reads them.
  They are in the schema now because adding an attribute later is a migration, and they are certain
  to be wanted the first time anyone invoices from this.
- **Idle detection** — noticing the machine was untouched for twenty minutes and offering to trim.
  The heartbeat makes it possible; nothing uses it yet.
- **Starting a timer from a calendar event**, which needs Phase D.
- **Exporting a report** as CSV.
