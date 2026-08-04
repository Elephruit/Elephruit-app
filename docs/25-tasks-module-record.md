# 25 — Tasks module record

> **Historical record.** The Tasks product surface was removed on 2026-08-03. Its ordinary work
> records migrate to reminders without changing identity, links, dates, recurrence, completion,
> hierarchy, or provenance. Bugs and features remain project-specific work records. See
> `docs/33-reminders-unification.md` for the current design.

What was built, the decisions behind it, and what was deliberately left.

## The product in one paragraph

Tasks answers four questions and refuses to answer them all with the same list: **what needs me now**
(Today), **what did I choose** (the plan inside Today), **what is coming** (Upcoming), and **where
does this belong** (areas, projects, lists, sections). It is calm rather than motivational: there is
no score, no streak, no percentage beside anything, and overdue work is amber on a date rather than
red across a row.

## The decision the module rests on

**A start date, a deadline, and a reminder are three different things, and only one of them can make
you late.**

| | What it means | Can it make a task overdue? |
|---|---|---|
| **Start** | Do not ask me about this until then. | Never. |
| **Deadline** | An external commitment with a consequence. | Yes — this alone. |
| **Reminder** | Interrupt me at this moment. | Never. |

`DeadlineUrgency` reads `deadlineAt` and nothing else. A test asserts that a start date thirty days
in the past produces no urgency at all, because that is the failure the whole model exists to
prevent: work that has not been asked for yet turning red beside work that is genuinely late.

Setting a date never creates a reminder. The one exception is typing a **clock time** in quick entry
— "tomorrow at 10" — because typing a time is asking for one, and the entry surface shows both
tokens before anything is created.

## Information architecture

**System views.** Inbox, Today, Upcoming, Anytime, Someday, Logbook. All six are visible on arrival,
in three bands: what is unfiled, what answers *when*, and what is behind you. Counts appear on **two**
rows.

Flagged, Waiting and All Tasks were system views and are now built-in smart lists, because that is
what all three always were — a rule over the library rather than a place in it. `TaskViewService`
returned a single ungrouped section for each, which is exactly what a smart list draws, so nothing
about their contents changed. The `TaskSystemView` cases stay, so a scene stored by an earlier build
still decodes. See `docs/31-tasks-interaction-scope.md`.

**Today** is a plan, not a pile. It is the union of exactly three things: work the user chose, work
whose start date is today, and work whose deadline is today or has passed. Nothing else arrives on
its own. A commitment is stored as a **day** rather than a flag, so carrying work forward is a fact
in the data — and Later Today applies only to a commitment made for today, because a task carried
over from Thursday has no back half of today to sit in.

**Upcoming** groups by day for the near future and collapses into weeks and months further out.
Every row says *why* the task is on that day, and the reason is what a drop moves.

**Containment.** Area ▸ Project | List | Goal; Project | List ▸ Section ▸ Task ▸ Subtask. A **list**
is its own kind: a project finishes and a list does not, and one container for both means either a
meaningless progress figure or an app that keeps offering to complete Groceries.

**Smart lists** compute membership. A task remains owned by its area, project, or list; nothing in a
smart list moves anything.

## The interaction model

**The editor is the row.** A task opens by making its own list row taller and putting the fields
inside it — see `TaskCard`. The rows above hold still, the rows below move down, and nothing else on
screen is covered, so the task never leaves the list that explains it. Three ways in: click a row
that is already selected, Return on the selection, or double-click. A single click on an unselected
row only selects it, because opening on first click would leave a trail of cards behind the arrow
keys. Escape closes; so does clicking another row, arrowing away, or changing list.

**There is no task detail column.** Tasks is a canvas module, on the same terms as Calendar and Time:
the list is the module. A column beside the list had to re-answer "which task is this?" with a header
and a container and a set of dates, every one of them a restatement of something already on screen.
Following a link to a task from elsewhere — a backlink, a person's page, a search result — navigates
to the list the task lives in and opens its card there; `TaskRedirect` and `TaskHome` are the two
halves of working out where that is.

**A control is a button while its value is absent and a chip once it is set.** Six attributes obey
it — When, Tags, Checklist, Deadline, People, Priority — so a task with nothing set is one short row
of controls rather than six empty form rows. The rule is a value, `TaskAttributes.layout`, with a
suite over all six rather than a convention inside a `body`.

**When is one control.** Today, This Evening, a date, Someday and Add Reminder are five answers to
one question, and putting them in one popover is what stops a task being scheduled for Thursday and
parked as Someday at the same time. Every route through it writes a start, a commitment or a
reminder, and **never a deadline** — `TaskWhenChoice` names the five and `TaskWhenChoiceTests` walks
them.

**Actions live at the foot of the list**, not in the window toolbar, because what is useful depends
on whether a card is open. The bar has three states — the list, the open task, and a multiple
selection — and the last of those is what used to be a separate batch bar.

## Steps versus subtasks

A **checklist item** has a title and a tick and exists only inside its parent. A **subtask** is a
task, with dates, a project, a place in Today, and a row in every list. Both exist because making
everything a subtask fills Anytime with fragments of single actions, and making everything a step
means a step can never be scheduled the moment it turns out to need it. The cheap one is the default;
the conversion is offered in a menu, in both directions, and never automatic.

## Recurrence

One row, not a hundred. Completing an occurrence leaves it exactly where it is as history and creates
a **new** row carrying the series forward. Most apps move the same row's dates and log nothing, which
means a weekly task has one completion in its history however many years it has run.

`RecurrenceRule.Anchor` decides what the next occurrence is measured from. Rent is due on the 1st
whether or not you paid late; plants need watering three days after you last watered them. Cancelling
does **not** roll the series forward — skipping one Friday is not doing it.

Steps come across unticked. The Reminders link does not come across at all: two tasks claiming one
reminder is how a sync pass starts deleting things.

## Apple Reminders

**This is the first integration in the app that writes**, and the guarantee the other two rest on is
not available. Calendar and Contacts are read-only *by construction* — their protocols have no write
method. A task manager linked to Reminders that cannot tick a reminder off is not linked to anything.

So the guarantee changed shape:

- Every write is a `ReminderWrite` value that can be previewed, logged, and asserted about.
- `RemindersProviding.apply(_:)` is the single door.
- `RemindersWriteSafetyTests` **counts** the EventKit write calls in the adapter. A count rather than
  a ban, because banning is not available; the number is what forces a fourth write to be justified.
- The calendar's broad source scan now excludes this one file and checks it against a narrower list —
  it writes reminders and must still never write an event.

**What crosses:** title, notes, start date, deadline, alarm, completion and its date, priority,
repeat (schedule-anchored only), list.

**What stays here, and why:** areas, projects, sections, Today and Later Today, today's manual order,
Someday, waiting-for, linked people and notes, provenance, attachments, smart-list rules, and task
history. The list is in `ReminderFieldMapping.appOnlyFields` with a reason each, and it is shown
verbatim in Settings.

Nothing private is smuggled into a title or a note. That text appears in Apple's own app on every
device, and in a shared list it appears to everybody it is shared with. A test exports a task that is
in an area, in a project, tagged, waiting on a named person, and committed to today, then greps the
resulting reminder for all six.

**Reconciliation** compares a fingerprint of exactly the mapped fields, taken from the reminder as it
came *back* from the store. EventKit's `lastModified` moves for changes the app does not map and, on
an iCloud store, for no local reason at all. Recording what was *sent* rather than what was *stored*
makes every pass see a difference and push again — a test runs three passes and asserts one write.

**A conflict is surfaced, never resolved.** Three outcomes are offered: keep local, keep remote, keep
both (the reminder is untouched and the local edits become a separate task linked to it).

**A vanished reminder is never a deletion here.** The task keeps its notes, links, and history, and
the user is offered keep-as-local, delete, or relink. Deleting a linked task offers two explicit
commands rather than one plus a warning dialogue.

**Permission.** The five-paragraph explanation is on screen *before* the button that triggers the
prompt, because macOS records the decision permanently and the only way back is System Settings. No
list participates until it is chosen. The module is fully useful with access denied.

## Migration

Schema **0.0.6**: twenty-one attributes on `Item`, one on `SavedSearch`, one kind, two link kinds,
no new entities. Additive throughout.

`TaskDateMigration` converts what is certain and flags what is not:

- `deferUntil` → `startAt`. It already meant "hidden until this date" and could never make anything
  overdue. Lossless, so it happens without asking.
- `dueAt` stays a deadline. It was the only date that ever produced overdue behaviour.
- **A `dueAt` carrying a time of day is not touched.** Before reminders existed as a field, a time on
  a deadline was the only way to write "at five o'clock", and that could have meant finish-by or
  tell-me. The value stays where it is and the task is marked, so the choice is offered later with
  the task in front of the user. A migration that guessed would silently manufacture notifications on
  somebody's real library, or silently remove them.
- Where two start dates disagree, the earlier survives — a task appearing sooner is recoverable, one
  vanishing for five days is not — and the flag records that a decision was made.

The calendar is injected. A stored midnight is midnight *where the user is*, and reading a library in
the wrong zone finds a time of day on every date in it.

## Performance, and what the measurement actually showed

`TaskViewService` does **one fetch and then Swift**, because none of the scheduling rules translate
to SQL. That is the decision carrying the most risk in the module, so it was measured rather than
argued about.

At **5,000 open tasks** the bare fetch costs **222 ms**, and all four system views land between
**320 and 337 ms** — within 5% of each other despite doing very different amounts of work afterwards.
Today evaluates a scheduling rule per row; the smart list evaluates two trivial predicates; Anytime
additionally walks up the tree per row to find its container. If the *rules* dominated, those three
would differ by a lot. They do not.

**Roughly two-thirds is materialising rows and one-third is rules** — about 20 µs a task for
everything the scheduling model does, traversals included. The benchmark measures the bare fetch
alongside the views and asserts the relationship, so the claim is checked rather than written down:
if a view ever costs twice its own fetch, something has become quadratic or has started faulting in a
relationship per row, and the test says so.

A deeply nested chain — two hundred levels of subtask — costs 25 ms, which is the bound on
`ancestors()` doing its job rather than merely existing.

Budgets are set from the measurement with headroom, because a budget nobody has measured against is a
number rather than a target — the first version of the benchmark carried 120 ms, invented before
anything had been run, and it was wrong by a factor of three. And **5,000 open tasks is not a
realistic library**: it is a situation no task manager fixes. At a few hundred, which
is a heavy real user, the same path is tens of milliseconds. The escalation path if that stops being
true is the derived index in ADR 0004, not a bigger predicate.

## Major files

| Layer | Files |
|---|---|
| Core | `TaskScheduling`, `TaskViews`, `TaskFilter`, `TaskChecklist`, `TaskRecurrence`, `TaskEntryParser`, `ReminderBridge`, `RemindersProvider` |
| Model | `ItemTask`, `TaskDateMigration`, `SchemaV6`, `ItemKind`, `ItemValidator` |
| Persistence | `TaskService`, `TaskViewService`, `TaskEntryComposer`, `ReminderSyncEngine` |
| Integrations | `EventKitRemindersProvider`, `FixtureRemindersProvider` |
| Features | `TaskWorkspaceView`, `TaskRow`, `TaskSupportingViews`, `TaskDetailPanels`, `TaskQuickEntryView`, `TasksSidebarSection`, `TaskSidebarModel`, `RemindersService`, `RemindersSettingsView`, `TaskSampleData` |

## Deliberately not built

Stated rather than implied, because a half-built feature that looks whole is worse than an absent
one.

1. **Local notifications are not delivered, and the interface now says so.** `ReminderOwner` records
   *who* is responsible and the invariants keep it honest, so a linked reminder never produces a
   second alarm. But nothing schedules a `UNNotificationRequest` yet: the app holds no notification
   entitlement and asks for no permission. A reminder on a local-only task is a date the interface
   shows, not an interruption.

   The choice when the When popover was built was to withhold *Add Reminder* until a scheduler lands
   or to offer it and be explicit. It is offered, and the line under the control reads "Elephruit
   shows this time on the task. It does not send a notification yet." The field already exists on the
   model and already draws on the row, so hiding it in the one place somebody would go looking for it
   makes the app seem to have lost the time rather than seem careful. What would not be acceptable is
   a prominent *Add Reminder* that silently never interrupts, which is why the sentence is part of
   the control rather than a footnote. A reminder owned by Reminders says the opposite, because that
   one really does arrive.
2. **No editor for custom smart lists.** The rule model, its storage, its evaluation, and its
   round-trip are complete and tested, and a saved list appears in the sidebar and works. There is no
   screen to build one from menus, so today they can only arrive from sample data or a future import.
   No control is shown that does nothing.
3. **The global quick-entry shortcut is application-scoped.** It is bound and it works while
   Elephruit is frontmost. Registering it system-wide goes through `GlobalHotKey`, which is wired for
   Quick Jot only.
4. **Calendar events are not shown inside Upcoming.** The calendar integration exists, and Today
   folds events into the day. Upcoming still shows only dated tasks, which is the remaining half of
   this: an agenda of the next four months that omits the meetings is an agenda somebody has to read
   beside another one. Events would be read-only when it lands.
5. **Recurrence is set from four cadences, not built.** The bottom bar's *Repeat* offers daily,
   weekly, monthly and yearly, and *Stop Repeating*. `RecurrenceRule` can express far more —
   intervals, weekday sets, a day of the month, two anchors, three ways to end — and quick entry
   already reads most of it from a phrase like "every 3 days after completion". What does not exist
   is a screen for building one, so the popover says in a sentence where the rest lives rather than
   offering a half-editor that looks like the whole thing. `RecurrenceEditScope` and its three
   outcomes are defined and documented; editing a repeating task still changes the live occurrence.
6. **Location reminders are recognised and declined out loud.** "Remind me when I get home" produces
   a token that says the app cannot do that, and the words stay in the title. EventKit's location
   alarms are not something this app creates.
7. **No column view for sections.** Sections work as headings in a list; the optional kanban-style
   arrangement is not built.
8. **Reminders sync is manual or on demand.** There is a Sync Now button and the store-change stream
   exists; no background coordinator watches it yet.

## Reviewing it

With synthetic data, and nothing real touched:

```bash
open -n "$(xcodebuild -project Elephruit.xcodeproj -scheme Elephruit -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}' | head -1)/Elephruit.app" --args -ElephruitDevelopmentMode -ElephruitUseTemporaryStore
```

Then **Settings ▸ Advanced ▸ Load Sample Data**. The library that appears contains one of every state
the module can be in, including all four Reminders states — written directly, so no permission is
requested and no real store is read.

To exercise the Reminders flow **against your own data**, open **Settings ▸ Tasks**, read the five
paragraphs, and press *Connect Reminders…*. Nothing participates until you tick a list. Everything
already linked keeps working if you disconnect.
