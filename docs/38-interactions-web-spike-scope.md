# 38 — The interactions spike, on the web

Written to be handed to a fresh thread. Self-contained: the app this repo builds
grew into an everything-app, and the daily gap stayed unserved — logging an
interaction from wherever the conversation happened, noting who people are to
each other, keeping what was learned, and tracking what is owed. The Mac app is
desk-bound; the phone rebuild is in flight. This spike is a deliberately narrow
web companion that does the core loop and nothing else, so the loop can be
lived with before anything larger is decided.

Branch: `claude/interactions-feature-spike-6b39a8`. Everything lives in a new
top-level `web/` directory — Vite, React, TypeScript, Firebase (emulator-first)
— and touches no Swift code, no Xcode target, and no existing document. How to
run it is `web/README.md`; this document is what it is and why.

## 1. What it does

Four surfaces behind Google sign-in (or a popup-free local dev account against
the emulators), phone-first:

- **Feed** — every interaction, newest first, drawn with the Timeline
  framework's geometry: one continuous rail, badges ringed in page background,
  day boundaries as a rule plus a larger day name. No cards.
- **People** — a roster with monogram avatars and last-contact lines; a person
  page with fact cards, relationships, open follow-ups, and a month-grouped
  history with the Everything/Conversations/Notes/Reminders filters.
- **Follow-ups** — the five buckets in reading order, absent when empty, with
  the start-versus-deadline distinction kept intact.
- **Quick capture** — a text box (the phone keyboard's mic button makes it
  dictation) that either parses via the user's own Anthropic API key into a
  reviewable proposal, or hands the text to the manual composer unchanged.

## 2. What it deliberately does not do

- No projects, calendar, notes editor, time tracking, tags, search, or sync
  with the Mac app's store. The spike validates one loop.
- No editing or deleting of interactions. Append-only is what keeps the
  last-contact cache honest (§4, D3) — if editing is ever added, the cache
  must be recomputed in the same transaction.
- No importer. It starts empty, capture-first. The Mac app's ArchiveFormat and
  this spike's client-generated UUIDs were kept compatible so an importer stays
  a straightforward later step, not a re-keying project.
- No AI transcription and no silent fact extraction. The composer captures what
  the user chooses to structure; the AI path proposes and the user confirms —
  the one thing the people module has always refused to do is guess facts from
  prose and write them unreviewed (§4, D5).

## 3. The rules that made the trip

The point of porting rather than starting fresh. Each of these is enforced in
`web/src/domain/` as pure TypeScript with vitest coverage, and a hygiene test
fails the moment that layer imports Firebase or the Anthropic SDK:

- **Facts are append-only observations.** Dated, confidence-carrying,
  sensitivity-scoped rows; the current answer is derived at read time —
  newest current observation wins per single-valued attribute — never trusted
  from the supersede chain. Confirm bumps one field; correct appends and
  leaves the note on the old row.
- **The attribute registry is open with curated folding.** Typed or dictated
  "school" lands on the School card; a genuinely new category round-trips
  untouched. Shelf lives are copied verbatim, including the two deliberate
  absences (observedAge, schoolGrade — estimator inputs, not claims to nag
  about), and staleness decays only the *displayed* confidence.
- **Relationships are reciprocal pairs.** A total inverse map (the involution
  is a test), pairs written and deleted as a unit, the user's word kept as a
  one-directional label, gender never inferred from a name, and unnamed
  relatives as first-class phrase-titled records feeding a to-fill-in queue.
  Renaming refreshes dependent phrase titles in the same save.
- **Only a logged interaction counts as contact.** Provenance stays a
  three-valued fact (logged / initiated / detected) even though the spike only
  writes `logged`; reminders and observations about a person never move their
  last-contact date. Follow-up suggestions keep the 42-day threshold, never
  fire for zero recorded contact, never write anything, and stay off by
  default.
- **Deadline and start date are different things.** Only a deadline can make
  work late; a past start with no deadline means available (Anytime); the
  quick-reschedule planner structurally cannot write a deadline.
- **One write path.** Every surface — composer, fact editor, relationship
  sheet, AI review — builds a `WritePlan` in the domain layer, and
  `applyPlan()` commits it as a single atomic batch. A second write path is a
  review failure here for the same reason it is on the Mac (37, D5).
- **Feeds are projections.** The feed and the person timeline are computed
  from what already points at a person; nothing stores a second copy of
  history.

## 4. Where it diverges from the Mac app, and why

**D1 — Separate collections, not the single Item entity.** ADR 0002's one-table
design serves a universal link graph the spike does not have. Firestore's unit
of query is the collection, and `people` / `interactions` / `relationships` /
`observations` / `reminders` map one-to-one onto the security rule (everything
under `users/{uid}`, owner-only) and onto the queries the surfaces make. The
one composite index — interactions by participant and date — is the person
timeline.

**D2 — Interaction metadata is real fields.** On the Mac, kind rides a
namespaced tag and provenance a shared column because adding columns to the
shared table is expensive. Firestore fields are cheap, so `kind`, `provenance`,
and (eventually) `channel` are honest columns. The semantics carried over
unchanged — especially `countsAsContact`.

**D3 — `lastContactAt` is a named cache.** The Mac app refuses to store
derived contact recency; Firestore cannot cheaply sort a roster by a derived
value. The compromise is explicit: the person document carries `lastContactAt`
as a cache, written only inside the same batch that logs an interaction and
only ever forward; the person page shows the live derivation and the roster
may lean on the cache. Append-only interactions (§2) are what make this
honest without Cloud Functions.

**D4 — Dates are client-set Timestamps.** No `serverTimestamp()` — a
single-user capture tool gains nothing from server clocks and loses
null-pending snapshots. Converters map Date↔Timestamp at the storage boundary;
millisecond precision round-trips ISO-8601 for a future importer.

**D5 — The model-backed parser arrived, in the slot 37 reserved for it.**
Doc 37 kept `PersonCommandParsing` a protocol precisely so a model-backed
conformance could be added "against the same preview and confirmation rules."
That is what this is. The LLM's only output is a schema-validated
`CaptureProposal`; pure code resolves names (case- and diacritic-insensitive,
unknown names created once and shared, ambiguity warned about and shown,
never silently guessed), folds attributes, and builds the same plan manual
capture builds — but only after a review screen where every item shows the
person it landed on and unchecking removes it. AI-observed facts default to
the confidence the speaker earned: `stated` only for what they asserted.

The privacy shape, stated plainly: the dictated text and the names of people
on record are sent to `api.anthropic.com` under the **user's own key**. The
key is pasted in Settings, lives in `localStorage` only — never Firestore
(it would sync), never `.env` (it would be built in), never logged — and is
forgotten with one tap. localStorage is readable by any script on the origin;
every script on this origin is first-party, which is an acceptable posture
for a personal spike and a stated non-posture for anything multi-user.
Captures parsed by AI stamp `occurredAt` as now; back-dating a dictated
memory is a known simplification.

**D6 — Emulator-first, with a popup-free door.** The whole loop runs against
the Firebase emulators under the fictional `demo-elephruit` project, offline
by construction. `signInWithPopup` dies in embedded panes and on phones with
popup blockers, so the sign-in page grows an emulator-only email/password dev
account; Google remains the real-project path (switch to `signInWithRedirect`
when deploying for phones). The composite index ships in
`firestore.indexes.json` from day one because the emulator never complains
about a missing index and production does.

## 5. Verification

- `npm test` in `web/` — 64 tests over the domain rules above, the proposal
  resolution, the request shape, and the canonical dictation fixture run end
  to end through resolution; plus the no-SDK-imports hygiene test.
- `npm run smoke` — headless proof against the emulators that an owner can
  round-trip a document and a second account is refused it.
- Browser walks recorded in the phase commits: the manual loop (create,
  log, feed, timeline, facts correct/history, unnamed son, rename refresh,
  bucket walk), and the AI loop with the API stubbed at the fetch layer.
- The live-key run — paste a real key in Settings, dictate, review, save —
  is performed by the owner; the implementer never handles a real key.

## 6. Open edges, so nobody trips on them

- The Files timeline filter exists in the domain (kept total with the Mac
  app's) and has no chip; nothing can match it yet.
- AI captures cannot yet set `occurredAt` or pick among same-named people in
  the review screen; both are review-screen affordances away, not model
  changes.
- Reminders subscribe as a whole collection and bucket client-side — right at
  spike scale, revisit before thousands of rows.
- `web/` introduces the repo's first Node toolchain; the lockfile is
  committed. The native apps' dependencies-none stance is about what ships in
  the sandboxed apps and still holds there.
