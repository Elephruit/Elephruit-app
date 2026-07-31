# 22 — People module record

Slice **S16**, which absorbs S11 and fourteen of the rows `docs/17` had marked *Deferred*. Sixteen
of the twenty People requirements move to **Met**; the reasoning for each is in `docs/17` and the
decisions are in `docs/21-people-module-scope.md`.

## What was built

| Layer | Added |
|---|---|
| Core | `PersonObservation` + `FactLedger`, `AgeEstimator`, `GradeEstimator`, `RelationshipKind`, `PersonCommandParsing` + deterministic parser, `ContactAction`, `IdentityMatcher` + `MergePlan`, `Celebration`, `MeetingBrief`, `ShareProfile` + `VCardEmitter`, `PersonQuery`, `PersonTimelineEntry` |
| Model | `PersonObservationRecord`, `PersonRelationship`, `PersonCelebration`, thirteen columns on `PersonProfile`, `SchemaV4` |
| Persistence | `PersonRepository`, `PersonWorkspaceService`, `PersonIdentityService`, `PersonSearchService`, `PersonGroupService` |
| Integrations | `SystemContactsProvider`, `VisionTextRecognizer`, `BusinessCardInterpreter` |
| Features | People band and list, workspace, portrait cards, timeline, context sidebar, command bar, relationship charts, celebrations, meeting brief, My Card, card scan, duplicates, Contacts settings |
| App shell | Eight App Intents, Contacts entitlement, `NSContactsUsageDescription` |

## The five decisions, and what they cost

**Facts are observations.** The expensive part is that "what is Maya's employer" is now a query over
rows rather than a column read. At personal-library scale that is free, and it buys the three
questions a column destroys: what was it before, when did it change, and who said so.

**Estimates are computed.** `AgeEstimator` returns a *range* that widens as the year turns, because
"Jack is six" fixes a window of possible birthdays rather than a birthday. It collapses to a point on
each anniversary — the one moment the window lines up — and a recorded birthday switches to exact
arithmetic and ends the hedging entirely.

**Groups reuse `ItemCollection` and `SavedSearch`.** No new entity. The only People-specific thing
about either is a name prefix, so a group stays exportable, trashable, and restorable by the
machinery that already existed.

**Contacts is a pointer.** Read-only by construction: the protocol has no write method, and
`ContactsWriteSafetyTests` fails if the adapter reaches past it. A second test fails if it fetches a
key nothing displays.

**The parser is a protocol.** One deterministic implementation, and 32 tests written against the
grammar rather than the implementation, so an AI-backed conformance inherits all of them.

## Bugs the tests found

1. **A person created with a profile was indexed empty.** The search projection reads the profile, so
   it has to be refreshed *after* the profile is attached. Nobody was findable by role, organisation,
   or location.
2. **The family chart drew every relationship twice.** Walking out to Jack and back finds
   *Maya-is-parent* and *Jack-is-child* — one relationship, two raw values. Both halves of the dedup
   key are now canonicalised.
3. **Birthdays existed in two places.** `addCelebration` wrote the profile field *and* a row, so the
   celebrations list showed everyone twice.
4. **`add Theo Ramirez` corrupted Theo Brandt.** A first-name match consumed "Theo" and offered to
   append the word "Ramirez" to the existing record. Creation paths now require the match to account
   for the whole line.
5. **Leap-day birthdays, three attempts.** Comparing the 28th and the 29th by *date* shifts every
   leap year, because the 28th is always a day earlier. Comparing by *year* is what works.

## Two things found by looking at the running app

Neither was reachable by a test, and both are the reason the app was opened rather than only built.

**The relationship line was backwards.** It read "son of Jack Chen" on Maya's page. The label
describes what the *other* person is to this one, so "of" inverts it.

**Ages and grades were being nagged about.** They appeared under "has not been confirmed in a while"
with a *Still true?* prompt — which is the wrong question, because of course Jack is no longer six
and the app already knows it. They are the *inputs* to an estimator that labels its own output, so
they were removed from the staleness rule.

## Verification

| Check | Result |
|---|---|
| `swift test` | **828 tests pass** (from 631), three consecutive clean full runs |
| `xcodebuild` Debug and Release | Succeed, zero warnings |
| Schema 0.0.4 migration from a real pre-`TimeEntry` store | Passes — `RealStoreMigrationTests` |
| App launches, migrates, loads the fixture, renders | Verified on screen |
| Portrait, estimates, timeline, groups, smart groups, duplicates | Verified on screen |
| Light mode | Verified on screen |
| **Dark mode** | **Not verified visually** — see below |

### Dark mode, stated honestly

The system appearance could not be switched: doing so means changing a system setting, which is
outside what this session may do, and `-AppleInterfaceStyle Dark` in the argument domain does not
override AppKit's global.

What *is* guaranteed: `Theme.Colors` is built entirely from AppKit's semantic colours, and
`SourceHygieneTests.coloursComeFromTheDesignSystem` now fails if any view names a literal colour. A
hard-coded value is wrong in at least one of light, dark, Increase Contrast, and a non-default
accent — and wrong invisibly, because the screen that was reviewed looked fine. The test is the part
of this that stays true next month; it is not a substitute for looking.

**To check it yourself**, switch System Settings ▸ Appearance while the app is open.

## Deliberately not done

- **Attendee → person matching on calendar import** (`docs/17` P10). Meetings link to attendees and
  appear in timelines, but matching an EventKit attendee *name* to a person automatically is a
  guess with a wrong answer that is hard to notice, and it belongs with the identity layer's offer
  mechanism rather than beside it.
- **A QR code for My Card.** The vCard export and the share sheet are built; rendering the same
  payload as a QR image is presentation, and it was cut to keep the slice finishable.
- **Printing labels and envelopes.** Named as lower-priority in the specification and treated as
  such.
- **Focus filter system integration.** The internal model — scopes, groups, saved searches — is
  clean enough that `SetFocusFilterIntent` is an addition rather than a refactor, but no App Intent
  for it ships here.
- **An AI-backed command parser.** The protocol exists and the tests are written against the
  grammar, which is the whole point; no second conformance ships.
- **UI tests.** The `AccessibilityID`s the People module adds are consumed by nothing, exactly as
  `docs/17` I5 records for the rest of the app. That is slice S15's job and this slice did not
  change it.

## Follow-up worth doing next

1. **Attendee matching**, routed through `IdentityMatcher` so it offers rather than assumes.
2. **Fact suggestions from note text.** The specification asks for "Pepper dislikes thunderstorms"
   to be *offered* after that sentence is typed. `ObservationDraft` and the confirmation flow both
   exist; what is missing is the extraction, and it should be deterministic first.
3. **Per-attribute shelf lives in a preference.** They are constants today; a user who checks in with
   people twice a year wants different numbers from one who does it weekly.
4. **Injected clocks for the remaining timing tests.** `PendingSaveTests` was fixed here — it slept
   a fixed 120 ms after a 10 ms debounce, which asserts how busy the machine is rather than how
   `PendingSave` behaves, and adding 23 store-building tests to the same target was enough to break
   it. It now polls for the condition. Anything else asserting on a real delay has the same latent
   fault.
