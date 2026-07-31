# 21 — People module scope

The People module closes `docs/17` rows **P1** and **P4** through **P19**, which is slice **S11**
plus most of what sat under *Deferred beyond this list*. It is written as one coherent slice rather
than eight, because the pieces are not separable: a portrait card that cannot say *how sure it is*
is a database form, and a fact that carries confidence needs an entity, a repository, an estimator,
and a place to render — or it is nothing.

## What this is not

Not a sales CRM. `docs/17` **P20** rejects relationship scores, pipelines, and productivity
metrics on product grounds, and that rejection is load-bearing here: every ranking in this module is
explainable in one sentence (recency, an exact string match, an open promise) and none is a number
attached to a human being.

## The five decisions

**1. Facts are observations, not fields.** A person's employer is not a `String` that gets
overwritten. It is a dated statement by someone, with a confidence, a source, and a predecessor.
`PersonObservation` is the entity; `FactLedger` is the pure function that turns a pile of them into
"what is true now, and how sure are we". Correcting a fact appends; it never destroys.

**2. Estimates are computed, never stored.** An age derived from "Jack is six, said in July 2026" is
recomputed from that observation every time it is read. Storing the derived age would produce the
one failure mode this feature exists to prevent — a number that was true once and silently is not
any more. `AgeEstimator` and `GradeEstimator` are pure, in Core, and every claim they make carries
the observation date it came from.

**3. Groups reuse what exists.** A static group is an `ItemCollection` (ordered, explicit
membership, already built) and a smart group is a `SavedSearch` (a query string, durable across
versions, already built). No new entity. `docs/18`'s standing rule R5 — prove the existing shape
cannot do it before adding a stored one — is satisfied by both.

**4. Contacts is a pointer, never a copy.** `PersonProfile.contactsIdentifier` already exists and is
already documented as a soft link. The integration reads through it and refreshes; the app's own
layer — observations, reflections, relationship history, timeline — is never written back into a
`CNContact`, and never leaves the machine.

**5. The parser is a protocol.** `PersonCommandParsing` has one deterministic implementation today.
An AI-backed one is an additional conformance, not a rewrite, and the deterministic one stays as the
offline default. Nothing in the command bar performs an externally visible action without a preview
the user confirms.

## Module placement

| Layer | Added |
|---|---|
| **Core** | `PersonObservation`, `TemporalEstimate`, `RelationshipKind`, `PersonCommand`, `ContactAction`, `IdentityResolution`, `Celebration`, `MeetingBrief`, `ShareProfile`, `PersonFilter` |
| **Model** | `PersonObservationRecord`, `PersonRelationship`, widened `PersonProfile`, `SchemaV4` |
| **Persistence** | `PersonRepository`, `ObservationService`, `IdentityResolver`, `PersonTimeline`, `PersonGroupService`, `MeetingBriefService` |
| **Integrations** | `ContactsProviding` + `SystemContactsProvider`, `TextRecognizing` + `VisionTextRecognizer` |
| **Features** | People workspace, portrait cards, timeline, context sidebar, command bar, relationship charts, celebrations, meeting brief, My Card, card scan |
| **App shell** | People App Intents, Contacts entitlement + usage string |

Schema goes to **0.0.4**: two new entities and a widened `PersonProfile`, every attribute optional or
defaulted. Additive, so lightweight inference handles it — the same path `TimeEntry` took in
`SchemaV2` and `RealStoreMigrationTests` already exercises.

## Acceptance

The 22 existing `PeopleTests` pass unchanged. New tests cover the four things that are genuinely
hard and that a view cannot check: temporal estimation across school-year boundaries, reciprocal
relationship maintenance, identity matching and merge, and command parsing. Every prominent control
does something. Empty, loading, permission-denied, populated, and error states are all real.
