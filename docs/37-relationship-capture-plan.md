# 37 — Logging what you learn about somebody

Written to be handed to a fresh thread. Self-contained: you do not need the conversation that
produced it. The people module's design record is [21](21-people-module-scope.md) and its build
record is [22](22-people-module-record.md); this is about the one thing neither of them finished,
which is *getting a fact into the app in the ninety seconds after you hear it*.

Branch: `claude/family-info-logging-plan-8f3e0b`, off `f6cb2e60`.

## Status

| Phase | State |
|---|---|
| 1 — Core | **Done.** High-school words parse; `SchoolYearIntent`; `FactAttribute.school`; `RelativeCapture` / `PersonUpdate`. |
| 2 — Persistence | **Done.** Schema 0.0.18 (`hasStatedName`); `createUnnamedRelative`; `renamePerson` with phrase refresh; `apply(_:source:observedOn:)`; `thingsToFillIn(for:)`. |
| 3 — Provenance | **Folded into 2.** Everything written through `apply` carries its source. The remaining `source: nil` call sites are facts typed directly with no source to carry — honest, not an omission. The debrief in §5 is what makes the rest of them non-nil. |
| 4.1 — macOS family editor | **Done.** `AddRelativesSheet` replaces `AddRelationshipSheet`. |
| 4.2 — macOS fact sheet | **Done.** Grade and School are separate categories; school-year control and reading line. |
| 4.3 — Command grammar | **Done.** Bare grades, `at <school>`, and a relative with no name. The command bar's own write path is gone — it builds a `PersonUpdate` like everything else. |
| 5 — Meeting debrief | **Done for macOS.** `MeetingDebriefSheet`, reached from the event inspector. 5.3 (the Today row) not started. |
| 6 — iOS parity | **6.1 done** — `RelativesSheet` on `PersonScreen`, plus phone review routing. 6.2 (log an interaction) and 6.3 (brief and debrief on `EventScreen`) not started. |
| 7 — The fill-in queue | **Done on the phone** — "To fill in" on `PersonScreen`, with a one-field naming sheet. Not on the Mac; no Today card. |
| 8 — Hardening | **Done.** See below. |

## 8. Widening it past the case it was built for

The plan above solves one conversation well and generalises badly, which was fair criticism. Two
changes, both of which turned out to be *removing* a narrowing rather than adding a feature.

**`FactAttribute` is reachable.** It has always been an open string type — its own documentation
gives *allergic to shellfish* as the reason — but every interface reached it through
`QuickFactCategory`, a closed list of eleven. An open type reachable only through a closed menu is a
closed type with extra steps. `FactAttribute.custom(_:)` makes one from what the user typed, and
nothing downstream needed changing: the display name, symbol, multi-value rule, staleness, search
projection and export filter all had defaults that were already right for an attribute nobody had
declared. A named attribute that matches a curated one **folds back into it**, so typing "School"
gives the School card rather than a second card beside it that neither supersedes nor merges.

**The capture form asks rather than decides.** `RelativeCapture` held five named properties drawn
behind `if kind == .child`, so adding a field cost six file edits and a colleague could not have an
age. It is a `[FactAttribute: String]` now; editors ask `RelationshipKind.suggestedAttributes` what
to *offer* and `FactAttribute.captureKind` how to draw it — three cases, because nearly everything
is a line of text and the two exceptions are exceptions for reasons already in the model. The old
properties survive as accessors over the dictionary, which is why this was a rewrite of three
editors and not of every call site.

**What was deliberately not done: a general "facts that age" engine.** There are two estimators and
a `schoolYearStart` column serving one attribute, and turning that into a declared drift model is
tempting. But age and grade may be the only facts that *estimate forward* — "married in 2019 → 6
years" is arithmetic on a date, not estimation — and building the engine for two cases is
speculative generality that will be wrong in ways nobody can predict until a third exists. Wait for
the third.

**Verification, honestly.** `PersonCaptureUITests` drives the phone's capture end to end — press
*Son*, type "senior", save, find the child, name him — and its screenshots are attached to the
result bundle. The **macOS** sheets have never been looked at: they build, they are covered by unit
tests, and `-ElephruitOpenSheet relatives` opens the family editor headlessly, but `screencapture`
returned black on this machine (asleep display or no Screen Recording grant). Look at them before
building anything on top.

Two traps cost an hour each and are written down so they do not again:

- **A `List` is a `collectionView`,** not an `otherElement`. Querying the wrong type reports a page
  as absent on a build where a screenshot shows it working.
- **Scrolling past a cell removes it from the accessibility tree.** Swiping a fixed number of times
  to the bottom of a long record recycled the section under test out of existence and reported its
  button as missing. Scroll *until* the element is hittable; never a fixed count.

---

## 1. The case this plan is measured against

A real conversation, on 5 August 2026, in a meeting that was already on the calendar:

> He has a son and a daughter. The son is going to be a senior in high school; the daughter is going
> into 8th grade. They go to South High because of where they live — the older school, but the better
> one, and they bought the house specifically for it.

Nine facts about three people, learned in one sitting, with a calendar event sitting right there that
knows who was in the room and when. The app should take all of it in under a minute, from either
platform, and should still be right next August without anybody going back to edit it — "going into
9th grade", by itself, on the daughter's card.

Today: on the Mac it takes four separate sheets and still cannot hold half of it. On the phone it
cannot be recorded at all.

**This is not a modelling problem.** Almost everything needed already exists and is tested. It is an
entry-path problem, and two small honest gaps in the model. That distinction decides the whole shape
of the work below: §2 is the list of things not to rebuild.

---

## 2. What already exists

Read this section before writing any code. Every item here is built, tested, and load-bearing.

| Capability | Where | Notes |
|---|---|---|
| Dated facts with history | `PersonObservationRecord`, `PersonObservation` | supersede chains, correction notes, per-attribute staleness |
| Confidence and sensitivity | `FactConfidence`, `FactSensitivity` | stated / inferred / uncertain; normal / sensitive / restricted |
| **Age that ages** | `AgeEstimator` | "6 on 18 July 2026" → "approximately 7–8 years old" two years on. The window *widens*, correctly. |
| **Grades that roll forward** | `GradeEstimator`, `SchoolYear`, `SchoolGrade` | `schoolYearStart` travels with the observation; advancing is addition |
| Reciprocal relationships | `PersonRelationship`, `RelationshipKind` | every kind has a total inverse; the pair is written in one save |
| The user's own word | `PersonRelationship.customLabel` | "son", not "child". The app never infers gender. |
| Lightweight people | `PersonRepository.resolveOrCreatePlaceholder` + `PersonProfile.isPlaceholder` | placeholders are excluded from People lists already |
| Provenance *field* | `PersonObservation.sourceItemID` | stored, rendered in the brief — and never written. See G5. |
| The brief | `MeetingBrief`, `PersonWorkspaceService.brief(for:)` | assembled, never maintained; shown in the Mac's event inspector |
| Typed capture | `DeterministicPersonCommandParser` | `Dave son Jack age 6 entering second grade` already parses and executes, Mac only |

**The estimators are the feature the user asked for and they are already finished.** What is missing
is a way to give them their input.

---

## 3. What is actually missing

Eight gaps, each with the evidence.

### G1 — A relative must have a name

`AddRelationshipSheet` disables its Link button on an empty name
([PersonSheets.swift:686](../Packages/ElephruitKit/Sources/ElephruitFeatures/PersonSheets.swift:686)),
and underneath, `resolveOrCreatePlaceholder` throws `.emptyPersonName` on a blank string
([PersonRepository.swift:636](../Packages/ElephruitKit/Sources/ElephruitPersistence/PersonRepository.swift:636)).

So the single most common shape of a fact learned about somebody's family — *he has a son and a
daughter*, no names given — is the one shape the app refuses. The user's options today are to invent
a name, to type "son" as a name, or to record nothing. All three are worse than the truth.

### G2 — Grade cannot be captured where a relative is created

`AddRelationshipSheet` offers an age field and nothing else
([PersonSheets.swift:614](../Packages/ElephruitKit/Sources/ElephruitFeatures/PersonSheets.swift:614)).
The worked example has no ages in it at all — nobody says "my son is 17", they say "he's a senior".
Recording the grade means linking the child, opening their page, opening a second sheet, and picking
the School category by hand.

Two sub-gaps behind it:

- **`SchoolGrade.parse` cannot read American school words.** It handles `"2"`, `"second"`, `"2nd"`,
  `"kindergarten"`, `"pre-k"` — and returns `nil` for `"senior"`, `"junior"`, `"sophomore"`,
  `"freshman"` ([TemporalEstimate.swift:178](../Packages/ElephruitKit/Sources/ElephruitCore/TemporalEstimate.swift:178)).
  A grade the app cannot read stays as the user's text and *never advances*, which is exactly the
  failure the user described.
- **No sheet can say "next year".** `PersonRepository.schoolYear(for:observedOn:calendar:)` bumps to
  the following school year only when `draft.effective != nil`, and `effective` is set only by the
  command parser ([PersonRepository.swift:490](../Packages/ElephruitKit/Sources/ElephruitPersistence/PersonRepository.swift:490)).
  Said in mid-July, "going into 8th grade" is filed against 2025–26 and reads a full year behind for
  six weeks — the six weeks in which people say it. `ObservationDraft.schoolYearStart` exists and the
  repository already prefers it; nothing in the interface sets it.

### G3 — One relative per trip

Two children means two full passes through a modal sheet, then two more to add their grades, then
more still for the school. Six sheets for one sentence.

### G4 — There is no attribute for a school

`FactAttribute` has `.schoolGrade` but nothing for *which school*
([PersonObservation.swift:47](../Packages/ElephruitKit/Sources/ElephruitCore/PersonObservation.swift:47)).
"South High" has to go in `.quickFact`, where it is unstructured, unsupersedable when the kid changes
school, and invisible to the brief's Family section.

### G5 — Provenance is stored and never written

Every production call site passes `source: nil`:
[PersonWorkspaceView.swift:355](../Packages/ElephruitKit/Sources/ElephruitFeatures/PersonWorkspaceView.swift:355),
[PersonPortraitViews.swift:606](../Packages/ElephruitKit/Sources/ElephruitFeatures/PersonPortraitViews.swift:606),
[RecordsCommandBar.swift:359](../Packages/ElephruitKit/Sources/ElephruitFeatures/RecordsCommandBar.swift:359)
and :373, [PersonIdentityService.swift:151](../Packages/ElephruitKit/Sources/ElephruitPersistence/PersonIdentityService.swift:151).

`BriefEntry.sourceItemID` is documented as "tappable, always". It is always nil. The model made a
promise — *where did I get this?* — that the interface has never kept.

### G6 — A meeting cannot update a record

The Mac's event inspector has a debrief field, and it writes free text onto the event annotation
([EventInspectorView.swift:656](../Packages/ElephruitKit/Sources/ElephruitFeatures/EventInspectorView.swift:656)).
That text becomes nothing. It creates no observations, links no people, and the next brief is no
better for it having been written.

Linking an attendee to a person record is manual — `linkedPeople` is whatever somebody added by hand
([EventInspectorView.swift:180](../Packages/ElephruitKit/Sources/ElephruitFeatures/EventInspectorView.swift:180));
`EventAttendee` and the identity resolver never meet. So the one moment when the app knows *who you
were with and when* is the moment it does least.

### G7 — iOS is read-only about people

`PersonScreen` loads a portrait, a timeline and a context and draws them
([PersonScreen.swift:329](../ElephruitiOS/Screens/PersonScreen.swift:329)). It writes nothing. There
is no add-fact, no add-relative, no log-interaction, no correction. `EventScreen` offers a link to
meeting notes and a list of already-linked people
([EventScreen.swift:162](../ElephruitiOS/Screens/EventScreen.swift:162)) — no brief, no debrief, no
way to link anybody. There is no command bar on the phone.

The phone is where you are standing when the conversation happens. It is the platform that can record
none of it.

### G8 — Nothing ever asks you to fill in the blank

Placeholders exist and are correctly hidden from the People list. Nothing surfaces them. When you
learn the son's name next month there is no "you know of two unnamed children" anywhere, and no
one-field way to supply it.

---

## 4. The decisions

Six, each with the argument, because these are the parts a later thread will be tempted to undo.

### D1 — An unnamed relative is a first-class record

Create it with `isPlaceholder: true` and a new `PersonProfile.hasStatedName: Bool` defaulting to
`true`. When false, the title is a phrase the repository derives from the relationship —
`"Dave's son"` — and the interface draws a quiet **Add name** affordance next to it wherever the
record appears.

The phrase is *stored in `Item.title`* rather than derived at render time, because `displayTitle`
feeds search, sort, links, export and both apps' every row, and threading a relationship-aware
fallback through all of it to serve one case is the wrong trade. The cost of storing it is that the
phrase goes stale if the parent is renamed; the fix is one query in `PersonRepository.rename`, which
refreshes the titles of unnamed relatives pointing at that person in the same save. Contained, and
honest about what it is doing.

`hasStatedName == false` is also the query behind G8's queue, which is why it is a flag rather than
an inference from the title's shape.

*Schema: additive attribute on an existing entity. `SchemaV18`, version 0.0.18, lightweight.*

### D2 — Grade is captured where the relative is, with the school year said out loud

The capture control is two states, not a date picker: **"in 8th grade now"** / **"going into 8th
grade"**. It sets `ObservationDraft.schoolYearStart` explicitly — `SchoolYear.containing(now)` or
that plus one — so the July problem cannot happen and the repository's fallback is never reached for
a fact typed by a human.

`SchoolGrade.parse` gains `freshman`/`sophomore`/`junior`/`senior` → 9/10/11/12, and the `"th grade"`
/ `"grade"` stripping already there covers the rest. Anything still unreadable stays as the user's own
text and is *not* advanced — the existing rule, and the right one.

### D3 — A school is a fact, not an organization record

Add `FactAttribute.school`, single-valued (you attend one at a time), curated next to `.schoolGrade`,
displayed as "School". A record would cost a page nobody opens and would not supersede when the child
changes school; a dated single-valued fact does both and lands in the brief's Family section for free.

*Why the house is not a fact about the child:* "they bought the house for the South district" is a
fact about **Dave** — his priorities, his reasoning — and belongs on his record as `.significance` or
`.quickFact`. Filing it under the daughter would put a statement about a parent's decision on a
child's page, where nobody would look for it and where it would outlive the reason it was said.

### D4 — Every capture path carries its source

Thread `source:` through all of them. The brief already renders provenance; the estimators already
produce the sentence (`EstimateProvenance.sentence(observedOn:)`). This is wiring, not design, and it
turns "approximately 17–18 years old" from a number of unclear origin into one with a tappable meeting
behind it.

### D5 — One capture value type, both platforms

A `Sendable` value in Core:

```swift
public struct RelativeCapture: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var kind: RelationshipKind          // .child
    public var label: String?                  // "son" — the user's word
    public var name: String?                   // nil is legal, and ordinary
    public var age: Int?
    public var grade: SchoolGrade?
    public var schoolYearStart: Int?           // set by the now/next control
    public var school: String?
    public var note: String?
}

public struct PersonUpdate: Sendable, Hashable {
    public var subjectID: UUID
    public var observations: [ObservationDraft]   // facts about the subject
    public var relatives: [RelativeCapture]       // facts about people around them
}
```

and one repository method that applies it atomically:

```swift
func apply(_ update: PersonUpdate, source: Item?, observedOn: Date) throws(AppError) -> [Item]
```

Every entry path — Mac sheet, phone sheet, meeting debrief, command bar — builds a `PersonUpdate` and
hands it over. Nothing about superseding, reciprocals, placeholder resolution or school years is
implemented twice, which is what keeps the two apps from drifting the way their people screens
already have.

### D6 — The meeting is the entry point, on both platforms

After a meeting, one action — **Log this meeting** — opens one composer that does four things in one
save:

1. resolves the event's attendees against person records (existing email/name matching), offering
   links rather than making them silently;
2. writes the meeting note as an `Item`, linked to those people;
3. captures facts and relatives against each linked person, through the same `PersonUpdate`;
4. sets `source` on every observation to that note.

Reachable from the event (both platforms), from the Today row for that meeting, and retroactively
from the person's timeline — because the conversation is often logged the next morning.

### D7 — There is a queue of things to fill in

One section, **To fill in**, listing unnamed relatives (`hasStatedName == false`) and stale facts
(`FactLedger.stale(asOf:calendar:)`, already built and already unused by any view). Adding a name is
one field and one tap; confirming a stale fact is one tap. On the person's page, and as a Today card
when it is non-empty.

---

## 5. The work

Seven phases. Each ends at a commit boundary with a clean build; §6 says how each is verified.

### Phase 1 — Core, no interface (`ElephruitCore`)

1.1 `SchoolGrade.parse` reads `freshman`, `sophomore`, `junior`, `senior`. Tests in
`TemporalEstimateTests`, including that an unreadable word still returns `nil`.

1.2 `FactAttribute.school` — declared, curated, named, symbol (`building.columns`), single-valued.
`SchemaComplianceTests` and the portrait's card ordering follow.

1.3 `RelativeCapture` and `PersonUpdate` as above, with a `summarySentence` used by every preview
line — one sentence builder, so the Mac's sheet footer and the phone's confirmation cannot disagree.

1.4 `SchoolYearIntent` — a two-case enum (`.current`, `.starting`) with one method resolving to a
`schoolYearStart` against a clock. This is the thing that makes the July bug unrepresentable.

*Commit: "Read the grades people actually say, and say which year they meant".*

### Phase 2 — Persistence (`ElephruitPersistence`)

2.1 `PersonProfile.hasStatedName`, `SchemaV18`, migration stage declared and tested per
[05](05-cloudkit-and-migrations.md).

2.2 `PersonRepository.createUnnamedRelative(of:kind:label:)` — derives the title phrase, sets
`isPlaceholder` and `hasStatedName: false`.

2.3 `PersonRepository.rename` refreshes dependent unnamed titles.

2.4 `PersonRepository.apply(_:source:observedOn:)` — the one method from D5. It resolves or creates
each relative, writes the reciprocal pair, records every observation with the source attached, and
saves once. Tests: two children in one call; a nameless child; a child who already exists by name and
must not be duplicated; a re-application that supersedes rather than duplicating a grade.

2.5 `PersonRepository.unnamedRelatives()` and the existing `FactLedger.stale` become one
`PersonWorkspaceService.thingsToFillIn(for:)`.

*Commit: "Let somebody be recorded before you know their name".*

### Phase 3 — Provenance (G5)

Thread `source:` through every call site listed in §3. Where there is genuinely no source — the
identity-merge conflict path — leave it nil and say so in a comment, because that one is a fact the
app derived rather than heard.

*Commit: "Say where a fact came from, everywhere one is written".*

### Phase 4 — macOS capture

4.1 Replace `AddRelationshipSheet` with a **Family** editor: rows, not a modal per person. Each row is
relationship, the user's word, an optional name, and — for a child — age *or* grade with the
now/next control, plus school. Add-row is one click; the name field is genuinely optional and says so.

4.2 `AddFactSheet` gains the school category and the grade control; the School category's value field
uses `SchoolGrade.parse` for live feedback ("reads as 12th grade") rather than accepting anything.

4.3 The command grammar gains the two shapes the worked example needs:
`Dave son senior at South High` and `Dave daughter entering 8th grade at South High`. The parser
already reaches `consumeTrailingObservations`; this is `at <school>` and the four school words.

*Commit boundary per sub-phase. Screenshot each, per §6.*

### Phase 5 — The meeting debrief (G6), macOS first

5.1 Attendee resolution: `EventAttendee` → person records by normalized email, then by name, offered
as suggestions with a Link button. Never automatic — a wrong link writes facts onto a stranger.

5.2 **Log this meeting** replaces the inspector's inert debrief box: the note body, plus a per-person
strip that builds a `PersonUpdate`. Saving writes note, links, observations and relatives in one go,
with `source` set.

5.3 The same action on the Today meeting row.

*Commit: "Let a meeting change what you know about the people in it".*

### Phase 6 — iOS parity (G7)

The phone gets the same three capabilities, built on the Phase 1–2 core, in this order — each is
independently useful and independently shippable:

6.1 `PersonScreen`: **Add a fact** and **Add a relative** sheets. Phone-shaped (a form in a
`NavigationStack`, not a 620×650 panel), same value types, same preview sentence.

6.2 `PersonScreen`: **Log an interaction**, matching the Mac's `LogInteractionSheet` bundle.

6.3 `EventScreen`: the brief above the fold, and **Log this meeting** below it.

**Before deleting or renaming anything in `ElephruitiOS/`, check `ElephruitiOS/Pad/` in up-to-date
`main`** — `git grep <name> origin/main`. The Pad reuses phone views and has broken twice on exactly
this. See `AGENTS.md`.

*Commit per sub-phase.*

### Phase 7 — The update loop (G8)

7.1 **To fill in** section on the person page, both platforms: unnamed relatives with a one-field name
box, stale facts with a confirm button.

7.2 A Today card when it is non-empty, behind the existing person-context switch, so a user who has
turned people off on Today does not get it back through a side door.

*Commit: "Ask for the name you did not have yet".*

---

## 6. Verification

Per `AGENTS.md` and the house rules:

- **Never call `xcodebuild` directly.** `Scripts/xctest.sh build` and `Scripts/xctest.sh test`.
- `swift test` in `Packages/ElephruitKit` for Phases 1–3, which need no simulator.
- **Screenshot every visible step, one screen at a time.** Launch with
  `-ElephruitUseTemporaryStore` — without it a dev launch writes into real data — and capture
  headlessly. Never take control of the screen to do it.
- `Scripts/premerge.sh` before opening the PR, and again before merging if `main` has moved.

The acceptance test is the worked example, run end to end on both platforms and timed:

1. From the calendar meeting, log it: notes, plus a son (senior, South High) and a daughter
   (going into 8th, South High), neither named, plus the house/district note on the father.
2. Both children appear on his page with a school and a grade, each labelled with its provenance.
3. Set the clock to August 2027. The daughter reads *likely in 9th grade*; the son reads *likely
   finished school*. Nobody edited anything.
4. Supply the son's name in one field from **To fill in**; his card keeps every fact and its source.

Step 3 is the whole point and it is the one that already works — it just has never had an input.

---

## 7. Out of scope

- **Contacts write-back.** Children and family facts stay in Elephruit. The existing promise on the
  relationship sheet ("Nothing here is written to your Apple Contacts") holds, and this plan widens
  what is recorded without widening what leaves.
- **An AI parser.** `PersonCommandParsing` is a protocol with one deterministic conformance precisely
  so a model-backed one can be added later against the same preview and confirmation rules. Not now,
  and not as a shortcut around Phase 4.
- **Transcription or automatic fact extraction from meeting notes.** The composer captures what the
  user chooses to structure. Guessing facts from prose and writing them to a person's record is the
  one thing this module has been careful never to do.
- **A relationship kind for schools or employers.** D3's argument.

---

## 8. Risks

| Risk | Why it bites | Mitigation |
|---|---|---|
| Stale derived titles | "Dave's son" survives Dave being renamed to "David Marsh" | Refresh in `rename`, in the same save; the To-fill-in queue catches the rest |
| A wrong attendee link writes facts onto a stranger | Attendee matching by name is fuzzy | Links are always offered, never automatic (D6.1) |
| Two apps drifting again | Exactly how iOS ended up read-only | One value type, one repository method (D5). A platform-specific write path is a review failure. |
| A grade that silently never advances | An unreadable word is stored as text | `SchoolGrade.parse` feedback at capture time (4.2), so the user sees "reads as 12th grade" — or does not — before saving |
| Placeholder people polluting lists | Every list query | Already handled: `allPeople(includingPlaceholders: false)`. Verify the new ones inherit it. |
