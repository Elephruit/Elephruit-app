# ADR 0002 — A single `Item` entity discriminated by `kind`

- **Status:** Accepted
- **Date:** 2026-07-29

## Context

The product premise is that anything links to, tags, and searches alongside anything
else. SwiftData relationships must name a concrete `PersistentModel` — there is no
polymorphism and no abstract entity.

## Options considered

| Option | Verdict |
|---|---|
| One entity per kind (`Note`, `Task`, …) | **Rejected.** A link entity would need one optional endpoint field per kind (≈14 × 2), tags would need the same fan-out, search becomes a union of N queries with N mappings, and Trash becomes N restore paths. |
| `ContentItem` protocol over separate entities | **Rejected as storage.** A protocol cannot be the target of a SwiftData relationship, so the fan-out problem is unchanged. Kept as a *read-only view protocol* for the design system and export codecs. |
| Shared "spine" entity + per-kind 1:1 detail entities | **Rejected for v1.** Correct in theory, but it doubles the object count and adds a join to every read for kinds whose extra fields number in the single digits. Retained *selectively* for `PersonProfile` and `EventReference`, where the detail is substantial. |
| **Single `Item` entity + `kind` discriminator** | **Accepted.** |

## Decision

One `Item` entity is the graph node. `PersonProfile` and `EventReference` are 1:1
satellites where kind-specific detail is large enough to justify a join.

## Consequences

- **Positive:** links, tags, search, favourites, archive, Trash, sort order, export,
  and undo each have exactly one implementation.
- **Negative:** a wide, sparse row; a note carries a nullable `dueAt`.
- **Mitigation for the negative:** `ItemKind.supportedFields` is the single
  declaration of which kinds use which fields; `ItemValidator` enforces it on every
  save; a test fails if a field is added without declaring its owning kinds. Views
  read kind-appropriate projections from feature models, never the raw wide row.

`NULL` columns cost about a byte in SQLite, so this is a modelling trade-off, not a
performance one.
