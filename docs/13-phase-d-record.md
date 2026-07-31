# Phase D — Calendar, read-only: what was built and what was proven

---

## 1. The finding that shaped everything

**EventKit has no read-only permission tier.**

Verified against the macOS SDK headers on this machine rather than from memory or from a
documentation page — both doc fetches returned a model's recollection with a disclaimer attached,
which is exactly what the brief said not to trust.

```
requestFullAccessToEventsWithCompletion:       API_AVAILABLE(macos(14.0))
requestWriteOnlyAccessToEventsWithCompletion:  API_AVAILABLE(macos(14.0))
requestAccessToEntityType:completion:          API_DEPRECATED(macos(10.0, 14.0))
```

Write-only is for apps that only *add* events. An app that merely **reads** has to ask for **full
access**. There is no narrower request to make.

So Elephruit holds a permission far broader than it uses, and the user has no way to grant less. That
is Apple's model, not a choice, and it moves the entire weight of "read-only" onto the code — which
is why the acceptance criterion about writes is the most important thing in this phase.

### What was verified, and where

| Fact | Source |
|---|---|
| `requestFullAccessToEvents()` exists, macOS 14+ | `EKEventStore.h:84` |
| The combined request is deprecated | `EKEventStore.h:90` |
| `.fullAccess` / `.writeOnly` status cases | `EKTypes.h:27` |
| `EKEventStoreChangedNotification` | `EKEventStore.h:475` |
| `calendarItemExternalIdentifier`, macOS 10.8+ | `EKCalendarItem.h:70` |
| `occurrenceDate`, macOS 10.8+ | `EKEvent.h:152` |
| `com.apple.security.personal-information.calendars` | Calendar.app's own entitlements |
| `NSCalendarsFullAccessUsageDescription` | Xcode's `CoreBuildSystem.xcspec` |

---

## 2. Read-only by construction

Three independent guarantees, because any one alone can be defeated:

1. **`CalendarProviding` has no write method.** Calling one is a compile error, not a policy.
2. **The `EKEventStore` is private to an actor and never escapes.** There is no way to reach past the
   protocol from feature code.
3. **`CalendarWriteSafetyTests` reads the adapter's source** and fails if it ever contains
   `store.save(`, `store.remove(`, `store.commit(`, `.saveEvent(`, `.removeEvent(` or six others.
   Named individually rather than pattern-matched, so adding one means adding it to the list too.

The third exists because the first two are true *today*. "I did not call the write API" is precisely
the kind of claim that stops being true during a later edit.

### An actor, not a lock

`EKEventStore` is not `Sendable`, and the two usual escapes — `@unchecked Sendable` on the wrapper or
`@preconcurrency` on the import — are both **banned by this project's own source-hygiene test**. That
rule fired during this phase and was right to: an actor needs neither, because every `EKEvent` is
projected into a value *inside* the actor before anything crosses back.

---

## 3. Off until asked for

Calendar access is a preference, stored per device, and it starts off. Until it is turned on the app
holds a `NoCalendarProvider`, never constructs an `EKEventStore`, and never prompts.

That ordering is the point. A permission dialogue on first launch — before anyone has decided the
feature is wanted — is what gets an app denied permanently, and macOS records that refusal forever.

The switch lives in Settings, where someone has gone looking for the feature. The copy says what the
prompt will not: that macOS will ask for "full access" because it offers no read-only option, and
that Elephruit never writes.

---

## 4. Occurrence-stable identity

A recurring event is one record with many occurrences. `eventIdentifier` names the **series**, so a
note linked by identifier alone follows the whole series rather than the Tuesday it was about — and
breaks outright when someone edits the series.

The key is the pair: `calendarItemExternalIdentifier` (stable across sync and across devices) plus
`occurrenceDate` (the occurrence's *original* start, which does not move when the series is edited
around it). Stored as one column so matching is one equality test.

Two details that are easy to get wrong and are tested:

- **An identifier may itself contain `#`.** EventKit identifiers are opaque; assuming a separator
  never appears in one is how links silently break for a subset of users.
- **A deleted occurrence falls back to its series** rather than resolving to nothing. A note about a
  cancelled instance should still point at the meeting it was about.

---

## 5. What is verified

| Property | Test |
|---|---|
| **No call that could change a calendar exists in the adapter** | `adapterNeverWrites` |
| Write-only permission reads as no access at all | `writeOnlyIsTreatedAsNoAccess` |
| Only an undecided permission is worth asking about again | `askingAgainIsPointlessOnceDecided` |
| Every refused state explains itself | `refusalsAreExplained` |
| **A fresh install never reads the calendar or prompts** | `nothingHappensUntilEnabled` |
| Enabling asks exactly once, then reads | `enablingRequestsAccess` |
| A refusal is an explained state, not a crash or an empty day | `refusalIsExplained` |
| Turning it off forgets what was read | `disablingClearsEvents` |
| **Revoking in System Settings degrades to an explained state** | `revocationWhileRunning` |
| Declined events are hidden; cancelled ones are not | `declinedHiddenCancelledShown` |
| An event is on every day it touches | `multiDayEvents` |
| **A link to one occurrence survives a series edit** | `occurrenceLinkSurvivesSeriesEdit` |
| A deleted occurrence falls back to its series | `deletedOccurrenceFallsBack` |
| Two occurrences of one series are separately linkable | `occurrencesResolveIndependently` |
| An occurrence round-trips through storage | `occurrenceRoundTrips` |
| An identifier containing `#` is not truncated | `identifiersMayContainSeparators` |

**490 tests pass. Debug and Release build with zero warnings.**

### The limit, stated

None of this runs against real EventKit. The tests drive a double, and what they prove is that *the
app's* logic is right — the opt-in ordering, the identity scheme, the degradation on revocation. What
they cannot prove is that EventKit behaves as its headers say when a real user edits a real recurring
series in Calendar.app.

That gap is narrowed by having read the headers rather than guessed, and by the fallback behaviour
when an occurrence cannot be found, but it is not closed. It closes the first time this is used
against a real calendar.

---

## 6. Interface decisions

**Events are a separate section above the work, not interleaved.** Events are when you are *not*
free; tasks are what you might do with the rest. Merging them into one ordered list implies a
sequence that does not exist and hides how much of the day is already spoken for.

**Distinct by shape, not colour.** An event row leads with a time range where a task leads with a
status circle, so the difference survives greyscale and a glance.

**Declined hidden, cancelled shown struck through.** A meeting you said no to is not part of your
day. A meeting cancelled an hour beforehand is information you need — silently removing it makes the
app look wrong to someone who remembers it being there.

**All-day events get a band, not a time.** "00:00–23:59" is noise pretending to be information.

**A refused permission offers System Settings, not "try again".** macOS records the decision
permanently; a retry button would visibly do nothing.

---

## 7. Not built in Phase D

- **Event → person links.** Attendee names are read and carried on the event value, but nothing
  matches them to `person` items yet — that belongs with Phase E's people work.
- **A calendar view.** Events appear in Today and Upcoming; there is no month or week grid, and the
  `calendar` sidebar destination is still declared-but-unavailable.
- **Starting a timer from an event**, which is a one-line join once someone wants it.
- **Writing anything, ever.** Not a gap — the point.
