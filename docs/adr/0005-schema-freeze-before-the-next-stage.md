# ADR 0005 — Freeze the schema snapshots before the next migration stage

- **Status:** Accepted
- **Date:** 2026-07-30

## Decision

The next `VersionedSchema` that adds, removes, or changes a **stored property** must first
replace the live model types in `SchemaV1` and `SchemaV2` with **frozen snapshots** — nested
model types that describe the shape those versions actually had on disk.

Until that work lands, **no stored property may be added to any `@Model` type.** Adding one
without the freeze is the change that breaks migration, not a change that merely risks it.

Rejected: continuing to declare one version in `schemas` and letting Core Data infer
lightweight migration forever. It works only while every change is purely additive *and*
every version's resolved entity graph stays identical, and the expansion breaks both.

## Rationale

`SchemaV1.swift:79-95` records the failure already paid for. While the versioned schemas
reference **live** model types, SwiftData resolves each one's full entity graph — so
`SchemaV1`, which never mentions `TimeEntry`, has it pulled in through `Item.timeEntries`
and comes out byte-identical to `SchemaV2`. Two versions with the same checksum throw
`"Duplicate version checksums detected"`, and that crashed every launch that needed to
migrate until commit `37337b7` fixed it by declaring one version.

Declaring one version bought time. It did not solve anything: the same docstring already
names the consequence — the first change that needs a custom stage "is also the one that
makes freezing the old model types mandatory rather than optional."

The expansion makes that change unavoidable. Every one of the four capabilities wants a
stored property:

| Capability | Property |
|---|---|
| Time tracking | `Item.estimateMinutes`, for estimate vs. actual |
| Rich documents | A note format version and payload reference |
| People | `ContactIdentity`, `Relationship`, `Observation` |
| Search | `@Index` on `Item.createdAt` — the fix for the one known benchmark miss |

None can land first. The freeze is the critical path for the whole programme, and it is
not in the expansion plan at all.

## Consequences

1. The freeze ships **alone**, in its own slice, with no feature riding on it.
2. Once frozen, a version's snapshot is immutable. Editing one rewrites history and is a
   defect, not a refactor.
3. `ElephruitMigrationPlan.stages` becomes non-empty for the first time, which activates the
   backup path in `PersistenceStack.swift:104-110`. That path is already correct and already
   keyed on the schema version stamp rather than on `stages.isEmpty` — a bug fixed once
   because it "silently switched the backup off on exactly the launch that needed it most."
4. The first real stage must be proven against a **real on-disk V2 store**, not a synthetic
   fixture. `RealStoreMigrationTests` already records why: a synthetic fixture "already ha[s]
   the shape V1 never had, so opening it needs no migration and the migration path is never
   executed — it looked covered and was not." That test is env-gated off by default and must
   be part of the freeze slice's acceptance, not skipped by it.
5. All eight `ContainmentRepair` fixtures must stay green across the stage, including the
   `GraphFingerprint` equality check.
6. Every released version stays in source forever, per the rule already stated at
   `SchemaV1.swift:75-78`.
