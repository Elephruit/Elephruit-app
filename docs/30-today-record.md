# 30 — Today

What was built when Home and Upcoming became one destination, the rules that decide what a day
holds, and what was deliberately left.

---

## 1. Why three destinations became one

The sidebar's primary band held four rows: Home, Today, Upcoming, Inbox. Three of them were answers
to the same question asked at different angles.

- **Home** said what was *happening* — the day's meetings, its note, who had gone quiet.
- **Today** said what was *due* — a flat list of every kind of record with a date of today or earlier.
- **Upcoming** said what was *dated* — largely the same records, sorted by day instead.

Somebody opening the app in the morning read two of them and did the joining themselves, because none
of the three could do it: none had seen the others' records. And the joining is the whole value. The
person in your ten o'clock is also the person a task is waiting on and also the person whose birthday
it is. That is one row on a page that has seen all three, and three rows on two pages that have not.

Inbox stayed. It answers a genuinely different question — what has arrived and not yet been filed —
and that is not a fact about a day.

Reminders now has one graph-backed workspace. The global Today remains the whole day: reminders,
meetings, and the people they involve. Choosing a legacy Tasks destination redirects to Reminders,
so a restored window or old deep link never strands the user.

## 2. The redirect

`SidebarSelection.home` and `.upcoming` are still declared, still `Codable`, and still decode.
Deleting them would have broken three things that are not the sidebar: a `@SceneStorage` string
written by the previous build, a `NavigationModel` restored from one, and any link, intent or launch
argument that named them.

`SidebarSelection.canonical` maps both to `.today`, and `NavigationModel.select(_:)` applies it. Every
route into the app funnels through there — a click, a menu command, the palette, a deep link, an
intent, a restored scene — so a redirect cannot be forgotten at one of them. `SidebarRegistry` marks
both rows unavailable rather than deleting them, which is the same convention every other retired
destination follows: the accessors filter on availability, so neither is ever enumerated in a
sidebar, a shortcut order, or a width calculation.

`ShortcutCommand.goHome` and `.goUpcoming` are gone. `ShortcutRegistry.load(from:)` already skips
unknown raw values, so a customised binding for either is simply dropped. **⌘2 is deliberately left
unbound.** It belonged to Upcoming, and the three bindings below it are stable bindings for three
modules rather than positions in a list — relearning three shortcuts to close one gap is the worse
trade.

## 3. Today is a canvas

The shell asked the *module* which layout to wear, and outside a module there was exactly one answer.
That was right while every module-less destination was a list. It is wrong for this one: a briefing,
a timeline, work and people do not fit in the 340 points a list column gets, and squeezing them there
is the bug the calendar already had once — the thing a destination exists to show, drawn in a third
of the window, beside 720 points of "Nothing selected".

So `NavigationModel.shellLayout` asks the selection as well as the module, and `TodayLayout` is a
canvas: an unbounded primary column, no detail column, and an inspector that arrives with a
selection. The page caps its own measure from the inside at `Theme.Size.todayContentWidth` — 1080
points, wider than the editor's 720 because the constraint is different. A paragraph is capped so the
eye does not travel back across it; a day's plan has no paragraphs, it has a date rail, a time gutter
and metadata that need room to sit on one line. It is capped all the same, because a briefing
stretched across an ultrawide display puts a metre of glass between "2 overdue" and the work it is
about.

## 4. The rules

All of them are pure values over a clock, in `ElephruitCore/DailyPlan.swift`, and all of them are
asserted in `DailyPlanTests` rather than reviewed on screen. Four are worth restating.

**Not every calendar entry is a meeting.** A meeting is an entry somebody else is on the invitation
to, and nothing else. A dentist appointment, a school pickup and a defended block of time are events.
Calling them meetings inflates "six meetings today" into a number nobody can act on, and invites the
interface to offer a guest list for a haircut. What an entry *is* comes from what it says about
itself — attendees, then availability, then shape — and never from its title, because title matching
reads "Travel to Berlin" as a journey and reads it wrongly in every language the app is not written
in.

**A conflict is two things that genuinely occupy the same time.** A focus block overlapping a meeting
is the meeting eating the block, which is ordinary; an all-day entry overlaps everything by
construction. Marking either would put a warning on most days of most calendars, which is the fastest
way to teach somebody to ignore warnings.

**Free time starts now, and is measured against hours the user already set.** For today the window
opens at the current moment rather than at nine, because time already spent is not available. The
hours come from the active `CalendarSetDefinition`, so the briefing and the time grid cannot disagree
about when the working day ends. On a day the user does not work there is no figure at all: free time
on a Sunday is the whole day, and saying so in hours is noise dressed as insight.

**Overdue work belongs to today alone.** Repeating it on tomorrow and the day after would make every
future day open as a crisis before it had begun.

**A flag is a bookmark, not a date.** It puts work on today, only today, and only when nothing else
already did.

## 5. People appear because the day put them there

`DayPersonReason` is the whole of the promise: somebody is on the page because they are in a meeting,
because a task is waiting on them, because a task is about them, because it is their birthday, or
because a follow-up is due and follow-up suggestions are switched on. If none of those is true, they
are not shown.

`DayPeopleRoster` merges by the library's identifier wherever there is one, so the same person
reached through an invitation and through a task collapses into one entry carrying both reasons. An
attendee resolves to a record by **email address**, which is an identity, or by a name that matches
exactly one person. Two people called James Wilson resolve to neither: attaching somebody's private
history to a stranger is not a mistake that announces itself.

Nobody is created from an invitation. An address the library has never heard of stays an unlinked
attendee, drawn as one, with a way to link them by hand in the calendar — where the choice between
two people with the same name can actually be made.

**What a card shows is narrower than what the library knows.** Anything marked sensitive or private
is excluded, and health and private reflections are excluded regardless of how they were marked. A
briefing surface is read in the seconds before a conversation and is the most likely screen in the
app to be visible to somebody else in the room, so a *summary* only ever carries what its subject
would say out loud. The full record is one click away on their own page, where somebody went looking
for it.

## 6. Nothing here is a copy

Every value on the page is derived from tasks, events, people, celebrations and notes that already
exist. There is no Today table, nothing is written on assembly, and an edit made anywhere else is
visible on the next pass. `DailyPlanServiceTests` proves the direction that matters: completing a
task from the day changes the task, and it is in the Logbook immediately.

`plans(from:count:)` reads the library once for the whole window. None of the scheduling rules
translate to a predicate — they compare against today in the user's calendar, read a commitment made
on an earlier day, and consult a lifecycle derived from four columns and a traversal — so answering
"what is on Thursday" means walking every open task. A page showing five days walked a real library
five times before this was fixed.

`CalendarService.revision` bumps only when the events come back **different**. Today reloads when it
changes and loads the calendar in order to reload; a counter bumped on every load meant load, bump,
invalidate, load, for as long as the page was on screen.

## 7. What was deliberately left

- **A generated narrative.** The page is useful without one and the plumbing for one is not here.
  Anything added later has to be grounded in the same records and has to be droppable without the
  page losing its meaning.
- **Drag and drop between days.** Rescheduling is a menu and a hover control. Dragging a row onto a
  date rail is the obvious next step and is not built.
- **Reordering within a day.** `todayOrder` exists and Reminders honours it; this page sorts
  by why something is here.
- **A per-day time surface.** Tracked time is still the Time module's; the briefing does not say how
  long the day has taken.
- **Creating a focus block in place.** "Block Focus Time" opens the calendar's quick entry on that
  day. Where a block goes depends on what else is on the day and on what the person is protecting,
  and an app that guesses both has written an appointment somebody now has to delete.
- **Carrying unfinished work forward automatically.** A commitment made on Monday is carried to
  today by the existing rule; nothing is rewritten, and nothing is moved without being asked.

## 8. Verification

`swift test` — 767 tests across 75 suites, plus 498 in the features target. `xcodebuild` Debug builds
the app with no warnings.

**Not done: a look at it on screen.** Screen-recording access was declined in the session that built
this, so the page has not been photographed in either appearance. What is enforced instead is the
same rule the rest of the app holds to — no view names a literal colour, so every colour resolves
through AppKit's semantic palette in light, dark, Increase Contrast, and under a non-default accent —
and the layout arithmetic is asserted at three window widths in `ModuleLayoutTests` rather than
eyeballed. That is the part that stays true; it is not a substitute for looking.

To look:

```bash
open -n "$(xcodebuild -project Elephruit.xcodeproj -scheme Elephruit -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}' | head -1)/Elephruit.app" --args -ElephruitDevelopmentMode -ElephruitUseTemporaryStore -ElephruitUseFixtureCalendar -ElephruitLoadSampleData
```

The synthetic calendar carries the cases worth looking at: a morning where three things clash, a
defended block marked free, leave marked unavailable, a call with a link to join, a meeting with
three people on it, a declined invitation, a cancelled meeting still visible, a four-day trip in the
all-day band, and a quiet weekend a few days out. Two birthdays are derived from the clock — one
today, one tomorrow — because fixed dates would put every celebration months away for most of the
year, and a briefing that can never demonstrate the case it exists for is a briefing nobody has
looked at.
