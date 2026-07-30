# Phase E — People and daily context: what was built and what was proven

---

## 1. Derived, never stored

Everything about a relationship is computed from links that already exist. There is **no new entity
and no new stored state** — no `lastContactedAt` column, no interaction count, no "relationship
health" score.

A stored `lastContactedAt` would be a second source of truth that goes stale the first time someone
edits a note, and there is no way for the user to notice it has. Computing it means editing a note
about someone *is* the act that updates it.

---

## 2. The distinction a test forced

The first version counted any mention as contact. A test written to check the summary line failed,
and the reason turned out to be a real design error rather than a broken expectation:

> Spoke to Ana three months ago. Wrote a task called "Email Ana" this morning.
> The app said: **last contacted today.**

Writing a task *about* someone is not contact *with* them. Counting it makes "you last spoke ninety
days ago" quietly false for anyone whose name appears in your work — which is exactly the population
a follow-up feature is for.

So there are two fields, and the rule lives in one place:

| | Counts | Answers |
|---|---|---|
| `lastContact` | Meetings and recorded conversations only | "When did we last speak?" |
| `lastMention` | Anything that references them | "What was I last doing about this?" |

`ContactMoment.isContact` is the single definition, so a person's summary line and a follow-up
suggestion can never disagree about it.

Someone mentioned but never spoken to reads **"Mentioned last week, not yet spoken"** — true, and
more useful than either "nothing recorded" or a false contact date.

---

## 3. Suggestions that never act

Follow-up nudges are **off by default** and, when on, do exactly one thing: say what is true and
offer a way through.

They never create a task, never schedule a reminder, never notify. `suggestionsNeverAct` asserts it
directly — asking for suggestions writes nothing, invents no task, and schedules nothing.

The policy is deliberately dull: a threshold in days. No scoring, no inference about who matters, no
learning from behaviour, all of which would produce confident recommendations nobody can explain or
correct.

**Someone with no recorded contact is never suggested.** There is nothing to follow up on, and
treating an empty record as "overdue by forever" would fill the list with everyone whose name has
ever been typed.

---

## 4. Daily entries are never created for you

`dailyEntry(for:creatingIfNeeded:)` takes the flag for a reason. Nothing writes one at launch, on a
timer, or when a day rolls over. Home offers a button; that is the whole mechanism.

An app that makes a note every morning fills a library with empty days, and then the user is
maintaining a diary they did not ask for.

At most one entry exists per day, keyed on `DayKey` rather than a date range — so "today's entry" is
an equality test and two entries for one day cannot quietly coexist across a timezone boundary.

---

## 5. Home

Today answers *what is due*. Home answers *what is happening* — which includes due work, but also the
meetings that will consume the time to do it in, the day's own note, and who is waiting.

Everything on it is a summary with a way through to the real thing. Nothing is edited there: a
dashboard that is also an editor becomes a worse version of both.

Overdue is split out from Due Today rather than shown twice. `ItemQuery.today` deliberately includes
overdue work — that is what makes Today usable — so Home separates them once rather than issuing two
store queries.

---

## 6. What is verified

| Property | Test |
|---|---|
| **A task about someone is not contact with them** | `mentionsAreNotContact` |
| Mentioned-but-never-spoken says exactly that | `mentionedButNeverSpokenTo` |
| Someone with no history is not made to look neglected | `emptyHistory` |
| A meeting counts at its scheduled time, not when written | `meetingsUseTheirOwnTime` |
| A future meeting is what is next, not what was last | `futureMeetingsAreNext` |
| Open tasks are counted; finished ones are not | `openWork` |
| A deleted mention stops counting | `deletedMentionsAreIgnored` |
| The summary reads as a sentence | `summaryIsReadable` |
| Recording a conversation makes it the last contact | `recordingUpdatesContact` |
| A conversation can be recorded after the fact | `backdatedInteraction` |
| **At most one daily entry per day** | `oneEntryPerDay` |
| **A daily entry is never created unasked** | `dailyEntryIsNotAutomatic` |
| Different days get different entries | `entriesAreScopedToTheirDay` |
| **A suggestion creates, schedules and changes nothing** | `suggestionsNeverAct` |
| Someone never spoken to is never suggested | `noHistoryIsNotOverdue` |
| Recent contact is not suggested | `recentContactIsNotSuggested` |
| Longest gap first | `longGapsSurface` |
| The threshold is honoured exactly, on the day | `thresholdBoundary` |
| Relative dates read as English at every distance | `phrasing` |

**512 tests pass. Debug and Release build with zero warnings.**

---

## 7. Not built in Phase E

- **Contacts integration.** `PersonProfile.contactsIdentifier` exists and nothing populates it. The
  entitlement is deliberately still absent — it goes in with the feature, not before.
- **Matching calendar attendees to people.** Attendee names are read and carried on the event value;
  nothing resolves them to `person` items yet.
- **A People overview** listing everyone by how long since contact. The data is there —
  `allContexts()` — but no screen shows it.
- **Notifications of any kind.** Follow-ups appear on Home when asked for and nowhere else. No
  notification entitlement, no badge, no scheduled alert.
