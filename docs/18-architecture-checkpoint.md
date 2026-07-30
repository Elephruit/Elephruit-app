# Architecture checkpoint

Living document. What the expansion demands of the existing architecture, where the architecture
already answers, and the standing rules that constrain every slice.

Evidence is in `docs/16` (frozen at `dfe1846`). Decisions are in `docs/adr/0005`–`0009`.

---

## 1. Standing rules

These bind every slice until an ADR retires them.

### R1 — The schema is frozen shut

**No stored property may be added to, removed from, or changed on any `@Model` type until the
schema-freeze slice lands.** ADR 0005.

`ElephruitMigrationPlan.stages` is empty because live model types make `SchemaV1` and `SchemaV2`
resolve to the same checksum. Adding a property without first snapshotting the old shapes is the
change that breaks migration, not one that merely risks it — and it has already crashed every
migrating launch once (`37337b7`).

This is the critical path for the whole programme and it is not in the expansion plan. Four
capabilities queue behind it:

| Capability | Blocked on |
|---|---|
| Estimate vs actual | `Item.estimateMinutes` |
| Rich documents | note format version + payload reference |
| People CRM | `ContactIdentity`, `Relationship`, `Observation` |
| Index rebuild budget | `@Index` on `Item.createdAt` |

### R2 — Mutations go through the action layer

Views, App Intents, importers and commands call actions. They do not call repository
`create`/`update` directly and do not call `noteChange` by hand. Enforced by a source scan.
ADR 0007.

### R3 — An entitlement lands in the same commit as the feature that needs it

The rule from `docs/06`, already honoured once: the calendar entitlement went in with the calendar
feature. See `docs/19`.

### R4 — Nothing is deleted silently, and a missing thing is a state

Already the pattern in three places, and the template for every new one: `ContainmentRepair` is
offered and dry-runnable; `referenceLostAt` is a state with "Locate…", not an error;
`reconcileConcurrentTimers` closes rather than deletes.

### R5 — A derived cache is the second answer

Before adding a rollup, aggregate table, or memo, prove the underlying query cannot be made fast.
The 200k week-report failure (`docs/16 §8`) is the live example: the cost is a predicate with no
lower bound, and a cache would have hidden that rather than fixed it.

---

## 2. What the expansion demands, and where the architecture already answers

| Demand | Already answered by | Gap |
|---|---|---|
| Parse is side-effect free, save is a separate explicit step | `CaptureParser` is pure and lives in `ElephruitCore`, which cannot see the store | Source ranges and original text (`docs/17` F3) |
| Unknown syntax is never silently discarded | Three re-append branches, one test | None |
| `follow:` is a start date that never becomes overdue | `Item.deferUntil`, plumbed through validator, Today filter, counts, inspector, export, import and the index | Unreachable from `ItemDraft` |
| Stable cross-feature links; archived sources keep history | `ItemLink` with a modelled unresolved state; `TimeEntry.item` is `.nullify` deliberately | None |
| Search is incremental, cancellable, off the main thread | `@ModelActor IndexWorker`, cursor paging, generation-stamped rebuild, `IndexStatus` distinguishing "no results" from "not finished" | `TimeEntry` unindexed; no quotas |
| Index canonical plain text, not serialized control data | `searchText` is already a derived projection recomputed on save | Must strip `U+FFFC` once attachments are inline |
| Timer exclusivity, recovery, never silent | Per-save invariant; one save for a switch; heartbeat; three choices plus defer | None |
| Duration derived, never independently editable | `duration(at:)` computed from `startedAt`/`endedAt` | None |
| Permissions requested only on use, with plain language | Five explicitly-mapped states, per-state explanation, `EKEventStore` never constructed until enabled | No centre; Contacts and Notifications absent |
| Attachments have stable identity and shared-reference safety | UUID directories, relative paths, copy-vs-bookmark, reference removal never deletes the file | No refcount, no staged commit, no orphan sweep |
| Every destructive action is recoverable | `StructuralUndoCoordinator`, `ItemRestorePoint`, soft delete on `TimeEntry` | No create inverse |

---

## 3. The four seams that must exist before capability work

1. **Frozen schema + a real `MigrationStage`** (ADR 0005). Everything with a stored property
   waits here.
2. **The action layer** (ADR 0007). One owner for validate → save → undo → index. Removes the
   class of bug that `CaptureIntent` already hit.
3. **The shortcut registry** (ADR 0008). One source of truth for 40 bindings, replacing the
   literals and the cosmetic glyph arrays that can drift from them.
4. **The archive contract** (ADR 0009). Attachments and time are part of a backup; today neither
   is, silently.

Rich documents (ADR 0006) is a fifth, but it is a capability with its own migration rather than a
shared seam, and it is last.

---

## 4. Boundaries that must not move

- `ElephruitCore` stays framework-free below Foundation. It is what makes the parser and the
  reporting arithmetic testable without a store, a clock, or a window.
- The SwiftData dependency stops at the repository protocols. `Item` is not `Sendable` and does
  not leave the context that owns it; bulk work exchanges `ItemSnapshot` values.
- Search never touches the store on the read path. `searchDoesNotTouchTheStore` asserts a
  `FetchAudit` tally of exactly zero while reading every field of 50 results — a property that a
  new field on a result would quietly break.
- The calendar adapter stays write-free, guaranteed by the protocol shape, the actor boundary, and
  the eleven-symbol source scan.
- Zero third-party dependencies. Six phases, none added.

---

## 5. Deferred architecture decisions

Recorded so they are visibly open rather than forgotten. Each waits for evidence.

| Decision | Waits for |
|---|---|
| Rich-document run-list schema detail | The editor slice; ADR 0006 fixes the format family, not the field list |
| Registry shape — data-driven vs. per-site | Whether SwiftUI `.keyboardShortcut` can be driven from data without breaking menu validation |
| Floating panel vs. sheet | Whether an `NSPanel` hosts the capture view without regressing accessibility. Reversible either way |
| `ContactIdentity` — mirror vs. reference-only | A prototype against a real Contacts store. The entitlement question is settled in `docs/19`; the modelling question is not |
| `TimeEntry` search projection — separate FTS table vs. type column | Measurement after the `entries(in:)` predicate is fixed |
| Timer overlap policy for non-running entries | The time slice |
| Multi-window note editing and revision conflict | The editor slice |
| Person identity resolution; observation vs. derived profile field | The People relationship slice |
