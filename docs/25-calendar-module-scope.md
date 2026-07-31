# 25 — Calendar module scope

The decisions taken before the module was built, and the reasoning that survived contact with it.

Nine decisions. Each one closed a question that would otherwise have been re-answered differently in
three places.

---

## D1. The read-only guarantee is replaced, not weakened

Phase D shipped a calendar that could only read, and proved it with a test asserting that no mutating
EventKit call existed anywhere in the integrations module. That was the right guarantee for a feature
that displayed events beside tasks. It is the wrong guarantee for an application whose job is
creating them.

So the absolute guarantee goes, and three narrower ones replace it. All three are enforced by
`CalendarWriteSafetyTests`, and all three are properties a calendar application can actually keep.

**1. Writes take an `EventDraft` and nothing else.** A draft holds twelve fields, every one of them
something a person decides: calendar, title, start, end, all-day, time zone, location, notes, URL,
availability, alarms, recurrence. There is no field for a linked person, a meeting note, a project,
or a prior interaction, so the CRM cannot reach a synced calendar event however the calling code is
later edited. The test asserts the exact field list, which turns "should this be synced?" into a
question somebody has to answer out loud rather than one nobody asks.

**2. Mutating EventKit calls live in exactly three methods.** `createEvent`, `updateEvent`, and
`deleteEvent`. The test reads the adapter, works out which method each line sits in, and fails if a
mutating call appears anywhere else — including inside a method whose name says it reads, which is
the shape the mistake would really take.

**3. Nothing crosses a series without an explicit scope.** `EventEditScope` has no default value at
any call site. "This one" can never quietly mean "all of them".

## D2. EventKit stays authoritative; the cache is derived

There is no SwiftData entity for an event, and there never will be. A table of events in this store
would be a second copy that can disagree with the first, which is exactly what
`docs/03-storage-matrix.md` exists to prevent.

What the module does need is a cache, for three reasons in order of how often they bite:

1. **Search.** "Lunches last year" against EventKit means materialising a year of `EKEvent` objects
   per keystroke.
2. **Offline and denied.** A calendar the app cannot currently read should show what it last knew,
   with a note saying so, rather than going blank.
3. **Linked context.** "Meetings with Maya" is a question about *Elephruit's* links, which EventKit
   knows nothing about.

So `CalendarIndex.sqlite` sits beside `SearchIndex.sqlite`, on the same terms: derived, versioned by
drop-and-rebuild, and deletable without loss. It is a **separate file** because the two are
invalidated by different things — a calendar refresh must not throw away the work of indexing fifty
thousand notes.

## D3. An event's links are an `Item`, not a table

A meeting somebody has attached people, notes, a project, and a file to is an `Item` of kind
`.meeting` carrying an `EventReference`, which this store has had since milestone 1.

Standing rule R5 in `docs/18` asks for proof that the existing shape cannot do the job before a new
stored one is added. There is none. Reusing it means:

| Need | What it already is |
|---|---|
| Link a person | `ItemLink(kind: .participant)` |
| File under a project | `ItemLink(kind: .filedUnder)` |
| Attach a file | `Attachment` on the item |
| Write a debrief | The item's body |
| Find it later | The existing search index |
| Export it | The existing archive |
| Survive a person merge | The existing identity service |

A parallel table would have needed its own answer to every row of that table.

**The item is created lazily**, on the first thing attached. A year of somebody's calendar is several
thousand events; writing a row for each so that eleven of them can have notes would make the store
larger than the library it belongs to, and would fill search with meetings nobody wrote anything
about.

## D4. Recurrence is a second type, and the reason is structural

`RecurrenceRule` describes how a *task* repeats. Its defining feature is `Anchor` — the distinction
between "pay rent monthly" and "water the plants three days after I last did" — and an event has no
completion to anchor to. Conversely an event needs ordinal weekdays ("the third Thursday") and months
of the year, which a task never uses.

One type serving both would carry a field that is meaningless in half its uses, in both directions.
So `EventRecurrence` is its own type with a shared vocabulary of frequencies, and the translation to
`EKRecurrenceRule` is one function in each direction.

EventKit has only two spans, `.thisEvent` and `.futureEvents`. The third scope — the entire series —
is honoured by applying `.futureEvents` to the series' **master** event, reached through
`calendarItems(withExternalIdentifier:)`. There is no span that reaches backwards from the middle.

## D5. Changing the display zone never changes a stored date

An event happens at an instant; a calendar draws that instant somewhere. Conflating the two is how a
calendar quietly moves somebody's flight when they land.

Every method on `TimeZoneDisplay` returns a *position* or a *label*. None returns a `Date`, and
`CalendarTimeZoneTests.noMethodReturnsANewDate` is a source check that fails if one is added —
because a helper that "converts an event into another zone" is entirely reasonable in review and
moves people's meetings the first time it is called on a save path.

Travel mode is explicit rather than inferred from the system zone changing. Automatic detection means
an app that reshuffles somebody's whole calendar the moment their laptop notices an airport's Wi-Fi,
which is exactly when they are least able to check whether it got it right.

## D6. Calendar colours become palette names

An `EKCalendar` has a `CGColor`. A fixed colour triple is wrong in at least one of light mode, dark
mode, and Increase Contrast, and it is wrong *silently* — the screen that was reviewed looked fine.
`SourceHygieneTests.coloursComeFromTheDesignSystem` exists to stop exactly that value reaching a view.

So the colour is read once, at the boundary, and reduced to the nearest `Theme.Palette` name. The
cost is fidelity: a calendar somebody tinted a particular teal becomes "teal". The benefit is that
their calendar is legible at night, which matters more.

`CalendarPaletteAgreementTests` keeps the mapper's vocabulary and the design system's in agreement,
because an unknown name does not fail loudly — it resolves to the accent colour and looks
deliberate.

## D7. Raw typing and parsed state never touch

The natural-language field owns a `String` and reports what was typed. The model owns an
interpretation derived from it and never writes back.

That is not tidiness. Every failure the specification names — a lost space, a re-ordered paste, an
undo that needs pressing twice, a caret that jumps, an input method's composition destroyed
mid-word — is what happens when a field rewrites what somebody is typing, and the only reliable fix
is for the write-back path not to exist.

It is an `NSTextView` rather than a `TextField` for the same reason: a `@Binding<String>` round-trips
by design, and when SwiftUI writes the value back it resets the caret and discards marked text.
Invisible in English, catastrophic in Japanese.

Corrections made in the chips are **overrides applied after each parse**, so typing more text
re-parses everything and keeps the correction, and clearing one returns to what the words say.

## D8. Two things are confirmed; everything else is not

Dragging an event to another calendar, and changing an occurrence of a series.

Both are changes whose *effect* is larger than the gesture that caused them. Dragging two columns
left in a week view is one movement; if those columns are different calendars it has also moved a
private appointment onto one colleagues can see, before the pointer was released.

Everything else — retitling, adding an alarm, changing a location — is proportionate to the gesture
and is not interrupted. Interrupting every edit trains people to click through the ones that matter.

## D9. What automation may and may not do

Reading is unrestricted. Creating an event is allowed, because its effect is entirely contained — a
new event appears and nothing that existed changes.

**Editing and deleting are not exposed to automation at all.** Both require an `EventEditScope`, and
the whole point of that type is that a person chooses it in front of a sheet explaining what each
choice does. An automation running unattended cannot make that choice, and defaulting it is how
somebody loses a year of a series. Not granting the capability is stronger than a confirmation an
automation could be written to dismiss.

Deep links follow the same rule from the other direction: every case navigates, and
`CalendarDeepLinkTests.linksOnlyNavigate` fails if a writing case is added. A link arrives from an
email or a web page with nothing in front of it.

---

## Explicitly not built

Per the specification, and enforced by their absence rather than by a flag:

- Weather
- Scheduling links, public booking pages, availability publishing
- Conference creation or joining (an event's `URL` field is displayed and is otherwise ordinary)
- Tasks or reminders inside any calendar view — a follow-up creates a task in Tasks and says so
- Meeting proposals, voting, registration
- Free/busy coordination between invitees

## Known external limits

| Limit | Cause | What is done instead |
|---|---|---|
| Attendees cannot be added or removed | EventKit exposes `EKEvent.attendees` read-only and offers no way to construct an `EKParticipant` | Existing attendees are shown and can be linked to CRM people |
| Event attachments do not sync | `EKCalendarItem` has no public attachments API at all | Attachments are Elephruit's, on the meeting item, and the panel says so |
| A recurring event cannot change calendar | EventKit refuses the save | Detected before the attempt and explained in words rather than passed through as a framework error |
| Permission is broader than the use | EventKit offers only full access and write-only | Explained before the prompt, and narrowed by D1 |
