# ADR 0005 — When the old model types have to be frozen

- **Status:** Accepted
- **Date:** 2026-07-30
- **Revised:** 2026-07-30, after the claim below was tested rather than reasoned about.

## Decision

The first change that needs a **custom migration stage** — a rename, a type change, or a value that
has to be computed from old data — must first replace the live model types in `SchemaV1` and
`SchemaV2` with **frozen snapshots**: nested model types describing the shape those versions had on
disk.

Until such a change is proposed, **additive changes ship as they always have**: one version declared
in `schemas`, an empty `stages`, and lightweight migration inferred by Core Data. Adding an
attribute, an index, or a whole new entity does not require the freeze.

Every schema change, additive or not, still **bumps the version identifier**.

## What this ADR originally said, and why it was wrong

The first draft of this decision said no stored property could be added to any `@Model` until the
freeze landed, and called that the critical path for the whole expansion. That was inferred from
`SchemaV1.swift:79-95` — which records that live shared types give `SchemaV1` and `SchemaV2` the
same Core Data checksum, and that a plan holding both throws — and it over-read that note.

The checksum collision is real, and it only bites when the plan holds **more than one version**.
A plan holding one version never compares two checksums. So the constraint is not "no stored
property may change"; it is "no *stage* may be declared", and a stage is only needed when inference
cannot do the work.

The evidence is in this repository, and it is now a test rather than an argument. `TimeEntry` — an
entire new entity plus a relationship on `Item` — shipped under a single declared version with an
empty `stages`, by inference. `RealStoreMigrationTests` migrates a store written by a build that
**predates `TimeEntry`**, and it passes: five items, their tags, containment and links all readable
afterwards, with an empty time table rather than an invented one. That test existed and had never
been run, because it needs a genuine legacy store and none had been produced. One now has been.

Adding `Item.estimateMinutes` and an index on `Item.createdAt` was then verified the same way, on
the same legacy bytes, through both version steps.

Getting this wrong in the cautious direction had a real cost attached: it would have put a large,
delicate refactor — roughly twenty duplicated model types — in front of four capabilities that
never needed it.

## When the freeze becomes mandatory

The trigger is a change inference cannot perform:

- renaming an attribute or an entity, where the old and new names must be related;
- changing an attribute's type;
- deriving a value in the new shape from data in the old one;
- splitting or merging entities.

Any of these needs a `.custom` stage. A stage needs at least two versions in `schemas`. Two versions
need distinct checksums. Live shared types cannot provide them, because SwiftData resolves each
version's full entity graph from the same classes — which is exactly how `SchemaV1` ended up
containing `TimeEntry` without ever mentioning it.

## The procedure, when that day comes

1. Snapshot each prior version's models as nested types inside its `VersionedSchema`, carrying
   **stored properties and relationships only** — no computed properties, no helpers.
2. Verify the entity names still match; the snapshot is identified by name, not by position.
3. Declare every version in `schemas`, oldest first, and the stages between them.
4. Prove it against a real legacy store, not a synthetic fixture. A fixture built from today's
   types already has the shape the old version never had, needs no migration, and so exercises
   none — "it looked covered and was not."
5. Ship it alone.

A legacy store can be generated from any historical commit with a git worktree and a throwaway test
that populates a store at a known path; `ELEPHRUIT_LEGACY_STORE` then points
`RealStoreMigrationTests` at it. That is how the store used above was made, and doing it again is
cheap.

## Consequences

1. Every released version stays in source forever, per `SchemaV1.swift:75-78`.
2. Every schema change bumps the version identifier — including additive ones. The identifier is
   what the `.schema-version` stamp is compared against, and the stamp is what triggers the backup.
   A change that kept the old number would migrate real user data with no backup taken, which is
   the bug already fixed once when the trigger was `stages.isEmpty` and it "silently switched the
   backup off on exactly the launch that needed it most."
3. Frozen snapshots, once written, are immutable. Editing one rewrites history.
4. The four capabilities that were thought blocked on this are not: `ContactIdentity`,
   `Relationship`, `Observation` and a rich-document payload are all additive.
