# UI/UX audit and redesign pass

Branch `claude/macos-app-redesign-f9c507`, on top of `bf78afe`.

Every finding below was reproduced in the running app, launched with sample data, a synthetic
calendar and a synthetic address book:

```bash
open -n "$(xcodebuild -project Elephruit.xcodeproj -scheme Elephruit -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}' | head -1)/Elephruit.app" --args -ElephruitDevelopmentMode -ElephruitUseTemporaryStore -ElephruitUseFixtureCalendar -ElephruitUseFixtureContacts
```

## What was wrong, by severity

### Broken

1. **List rows disintegrated below about 200 points.** Tag chips compressed one character at a time
   until "urgent" was six rows of a single letter; "Yesterday" became three stacked syllables; the
   title beside them was a letter and an ellipsis. Reachable by dragging the divider, and the state a
   freshly created window opened in. **Fixed.**
2. **Search results were not reachable from the keyboard.** The results were `Button`s inside a
   `List` with no selection binding, so the arrow keys had nothing to move between. A search could be
   typed without the mouse and only finished with one. **Fixed.**
3. **Sample data was never indexed.** `loadSampleData()` wrote ~140 items straight through
   `ItemService` and never told the search index, which had already been opened and found complete.
   Searching "pricing" returned nothing while three items containing the word sat in the list.
   **Fixed.**
4. **The calendar hour ruler wrapped.** `.shortened` times ("10:00 AM") in a 56-point column: 8 AM
   and 9 AM fitted, everything after wrapped to "10:00 A / M" and was pushed off its own hour line.
   **Fixed** — it now shows the hour, as Calendar does.
5. **The Today banner had no button.** `CalendarStatusBanner` handled "not enabled" and "asked and
   refused" but not the state in between — enabled, never asked — which is where a new library sits.
   It printed an offer with no control beside it. **Fixed.**
6. **Dangling separator.** A row with a parent and no body read "Planning ·". Visible on every
   untitled or bodyless item in the app. **Fixed.**
7. **"Nothing matches matching “pricing”."** A subtitle fragment interpolated after a verb.
   **Fixed.**

### Inconsistent

8. **Three different row layouts** for the same items — Today (checkbox, title, chips and date right
   aligned), Tasks (metadata on a second line, `#hash` tags), Notes (no date at all). *Not addressed;
   see remaining issues.*
9. **Two vocabularies for the same two fields, on screen at once.** A task's detail pane says
   "Start" and "Deadline"; the inspector beside it says "Defer until" and "Due". *Not addressed.*
10. **"Colour" in three pickers**, plus "recognised" in three strings. **Fixed.**
11. **"promise" as a tag chip.** The word was the app's, not the user's — sample data planted it and
    three files matched the literal. **Fixed**: `TagConventions.owed` is `follow-up`, and `promise`
    is still recognised so existing libraries keep their filing.
12. **Two disclosure affordances 30 points apart** in the Tasks sidebar — "More" with a leading
    chevron, "Smart Lists" with a trailing one. *Not addressed.*

### Visually weak

13. **Empty-state actions were accent-coloured text**, with no border, no hover, no pressed state
    and a hit target the width of the words — "Ask Again" under a padlock, "Add Time…" under a
    stopwatch. On an otherwise empty screen this is the only thing to do. **Fixed.**
14. **Time said "empty" three times on one screen** — window subtitle, a large "0:00" over "Nothing
    tracked in this period.", and the centred empty state. **Fixed.**
15. **"Show All Calendars" was the one sidebar row without a symbol**, so it read as a caption.
    **Fixed.**
16. **A fake example in the People search prompt** — "people in Austin · likes natural wine", a
    sentence about somebody who does not exist sitting where the user's text goes. **Fixed.**
17. **Person profile: oversized cards.** Ten quick facts, each a rounded card with a coloured icon
    chip, consuming the whole scroll. *Not addressed.*
18. **People rows are ~80 points tall** for two lines of text, against the design system's own
    `rowHeightExpanded: 44`. *Not addressed.*

### Layout

19. **The declared column policy is not applied.** `ModuleLayoutPolicy` states a minimum, ideal and
    maximum for every column of every module, and `ModuleShellLayout` resolves them carefully — then
    AppKit ignores the result. Measured: a fresh window laid the list out at **198 points against a
    declared minimum of 260**; a window restored from AppKit's own split-view autosave laid it out at
    **808 against a maximum of 520**, with the People detail pane at **351 against a minimum of 400**.
    **Partly fixed** — the minimum is now also stated as a frame on the column's content, which the
    split view cannot draw narrower than, and the list opens at 260. The maximum is still unenforced.

### Accessibility

20. Search results had no keyboard path at all (see 2). **Fixed.**
21. Empty-state actions had no focus ring and no default-button behaviour. **Fixed** — they are now
    the default action, so Return works.

### Performance

Nothing was regressed and nothing new was introduced. The row fixes are `lineLimit`, `fixedSize` and
`layoutPriority` — all layout-time, no allocation, no measurement pass. `ViewThatFits` was
considered for the chip row and rejected: it measures every candidate on every row, which is exactly
the cost that must not enter a 400-row People list.

## The design rules that came out of it

Small, and stated where the next person will change them rather than in a document:

- **A separator goes *between* two things.** Compose a line from the parts that exist.
- **Metadata is drawn whole or not at all.** Chips and dates get `lineLimit(1)` and `fixedSize`; the
  title carries the ellipsis, because it is the thing that has one. Stated once as
  `layoutPriority(1)` on the row's trailing cluster.
- **If there is something to say, there is something to press.** A banner or empty state that
  describes a capability must offer the control that reaches it, in *every* state it can be in.
- **An empty state's action is its primary action**, by construction — nothing competes with it. So
  it is `.borderedProminent`, large, and the default button.
- **Do not say the same thing twice on one screen.** A headline zero above a sentence restating it
  above an empty state restating it again is a summary of nothing.
- **A prompt is not a worked example.** Placeholders name the field; they do not invent content.
- **Vocabulary the app reads lives in one constant** (`TagConventions`), not in four string literals.

## Before and after

| | Before | After |
|---|---|---|
| Today | [before](before/today.png) | [after](after/today.png) |
| Tasks | [before](before/tasks.png) | [after](after/tasks.png) |
| People profile | [before](before/people-profile.png) | [after](after/people-profile.png) |
| Calendar, week | [before](before/calendar-week.png) | [after](after/calendar-week.png) |
| Time | [before](before/time.png) | [after](after/time.png) |

Both sets were captured from a real build at the same window size, against the same fixture library.
The "before" set is a build of `bf78afe` in a scratch worktree.

## Commits

| | |
|---|---|
| `86b9ccb` | Keep list rows legible at every column width |
| `c3e985b` | Make search results reachable from the keyboard |
| `a739918` | Fix the calendar hour ruler, and say things in American English |
| `4bb1256` | Give every offer something to press |
| `adff8ea` | Stop the Time module saying "empty" three times |

## Builds and tests

- `xcodebuild -project Elephruit.xcodeproj -scheme Elephruit -configuration Debug build` — succeeds,
  no warnings, after every pass.
- `swift test` across all eight modules — **1,693 tests pass** (1,686 before; seven added for the
  search traversal).
- Every change was checked in the running app, in light appearance.

## Remaining issues, ranked

1. **The declared column maximum is still not enforced** (finding 19). The detail pane takes all the
   slack the window has, past its own ceiling. A frame maximum would cap the *content* and leave the
   pane's remainder empty, which reads as a rendering fault, so it needs the divider moved rather
   than the content constrained — most likely by holding the pin from `applyModuleLayout()` until a
   drag is detected, rather than releasing it after 50 ms.
2. **Three row layouts for the same items** (finding 8). The largest remaining consistency problem
   and the one most visible to a reviewer. Wants one row component with a per-module metadata slot.
3. **"Start/Deadline" vs "Defer until/Due"** (finding 9) — two names for two fields, both on screen.
   Pick one pair.
4. **The person profile is the narrowest of four columns** and its quick facts are oversized cards
   (17). The pane with the most to say has the least room.
5. **People rows are near twice the height they need** (18).
6. **Two disclosure affordances in the Tasks sidebar** (12).
7. **Notes rows carry no date** — the single most useful thing in a notes list.
8. **Dark mode was not reviewed on screen.** No literal colour is named anywhere
   (`SourceHygieneTests.coloursComeFromTheDesignSystem` enforces it), so it should be correct, but
   "should be" is not "was looked at".
9. **Settings ▸ Advanced computes index statistics and never shows them** — `refreshStatistics()`
   casts to `DefaultSearchEngine`, the engine is an `FTSSearchEngine`, the cast fails silently.
10. **Arrow keys in the search *field*** do not move the highlight — only Tab-then-arrows does. The
    field is in the toolbar and outside the view's responder chain; doing it properly needs an
    `NSEvent` monitor or a custom field.

## Manual QA checklist

- [ ] Drag the list/detail divider as narrow as it goes in Today, Tasks and Notes. Chips and dates
      stay whole; only the title truncates.
- [ ] Today: a task with a project and no body reads "Planning", not "Planning ·".
- [ ] Settings ▸ Advanced ▸ Load Sample Data, then search a word you can see in the list. It is
      found without rebuilding the index.
- [ ] Search: type two letters, press Tab, then Down/Up. Each result is highlighted and shown in the
      detail pane. Return moves focus into it.
- [ ] Search something with no matches: the message reads "Nothing in your library is matching …".
- [ ] Calendar ▸ Week and Day: the hour ruler reads 8 AM … 12 PM … 11 PM on one line each, aligned
      to its grid line. Check with a second time zone turned on.
- [ ] Turn the calendar off in Settings. Today's banner and the Calendar module both show a button.
- [ ] Time with nothing tracked: one empty state, one prominent "Add Time…". Track something; the
      totals return.
- [ ] Item inspector and calendar-set editor say "Color".
- [ ] People: the search field says "Search People".
- [ ] **Dark mode**, and **Increase Contrast**, across the same screens — not yet done.
- [ ] People with 400+ records: scrolling stays smooth (the row changes are layout-only, but worth
      confirming on your own library).

## Driving this app from Claude

Not built. What exists and what it would take:

The app already exposes **15 App Intents** — `CaptureIntent`, `FindPersonIntent`, `CreatePersonIntent`,
`AddPersonNoteIntent`, `LogInteractionIntent`, `RecordFactIntent`, `CreateFollowUpIntent`,
`MeetingBriefIntent`, `UpcomingCelebrationsIntent`, `TodaysAgendaIntent`, `NextEventIntent`,
`SearchCalendarIntent`, `CreateEventIntent`, `SwitchCalendarSetIntent`, `OpenCalendarIntent` — all
registered through `ElephruitShortcuts: AppShortcutsProvider`, and `CaptureBridge.adopt(services)`
already routes an intent firing in this process to the open store rather than opening a second one.
That is most of an automation surface.

The gap is that `shortcuts list` only enumerates *saved Shortcuts*, not an app's raw App Intents —
verified on this machine — so there is no supported command line that runs `FindPersonIntent`
directly. Two ways to close it:

1. **Wrap each intent in a saved Shortcut** (no app changes). An MCP server then shells out to
   `shortcuts run "Elephruit — Find Person" -i input.txt` and reads stdout. Quick, but it depends on
   15 hand-made Shortcuts existing on every machine, and passing structured input through them is
   awkward.
2. **Add a URL scheme, and an MCP server over it** (the better one). `elephruit://find-person?q=…`
   handled by `onOpenURL` in `ElephruitApp`, reusing the same service calls the intents already make,
   with results returned via a reply file or a local socket. Fully under our control, testable, and
   it gives Claude the same verbs as Siri.

I would recommend (2), and it is a feature-sized piece of work rather than something to fold into a
design pass — it needs its own decisions about which verbs are readable, which are writable, and how
a write is confirmed. Say the word and I will scope it.
