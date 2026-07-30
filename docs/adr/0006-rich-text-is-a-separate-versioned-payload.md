# ADR 0006 — Rich text is a separate versioned payload; `Item.body` stays the projection

- **Status:** Accepted
- **Date:** 2026-07-30

## Decision

Rich text is stored as a **versioned, `Codable` run-list document** — an explicit list of text
runs with an explicit, allow-listed attribute set — held in its own payload, not in `Item.body`.

`Item.body` remains a `String` and remains the **plain-text projection**: what the FTS index
receives, what Markdown export writes, and what wiki-link reconciliation parses. It is derived
from the rich document and regenerated on every write.

Rejected: **RTFD**, and **`NSKeyedArchiver`**. Both were prototyped; see below.
`NSAttributedString` remains the in-memory editing representation, and the conversion to and
from it is the format's only job.

## Rationale

A throwaway prototype ran both candidates against everything the expansion asks a note to hold.
The decisive result:

| Property | RTFD | `NSKeyedArchiver` |
|---|---|---|
| Custom attribute (wiki link target UUID) | **lost** | kept, exact |
| Custom attribute (semantic paragraph style) | **lost** | kept |
| Stable ID alongside an attachment | **lost** | kept, exact |
| `.link` with a custom URL scheme | kept | kept |
| Table structure (`NSTextTable`) | kept | kept |
| Three-level list nesting | kept | kept |
| Attachment bytes and filename | kept | kept |
| Encode 100,000 characters | 2.2 ms, 135 KB | 0.8 ms, 137 KB |

**RTFD is disqualified.** Elephruit's wiki links are not decoration — they are modelled
relationships with stable targets and a first-class unresolved state (`ItemLink.swift:11-16`),
and creating a note auto-resolves every link waiting on that title. A format that silently drops
the attribute carrying the target ID cannot store them. The `.link` workaround — encoding
`elephruit://item/<uuid>` — does survive, but it only covers links; attachment identity and
semantic styles have no equivalent slot, and both were measured lost.

**`NSKeyedArchiver` carries everything and is still the wrong choice.** It serializes whatever
AppKit objects happen to be attached, with no allow-list, so sanitising an unsupported attribute
is a pass over the decoded graph rather than a property of the format. It needed
`requiringSecureCoding: false` to round-trip at all. It is opaque, undiffable, and its layout is
Apple's to change between releases — which is exactly the property that makes a stored format
expensive.

An explicit run-list gives what neither does: unsupported attributes cannot be represented, so
sanitisation is structural rather than remembered; the format has its own version number
independent of any framework; and it is diffable, which is the same reason `ArchiveDocument` is
pretty-printed with sorted keys and ISO 8601 dates (`ArchiveFormat.swift:387-392`).

Keeping `body` as the projection is the second half of the decision. Making `body` attributed
would break the FTS projection, the roughly thirty-five round-trip tests, and index-backed
wiki-link reconciliation simultaneously — three systems that currently work, to gain nothing the
projection does not already give.

## Consequences

1. Two representations exist and one is authoritative. The rich document is the source of truth;
   `body` is derived and rebuildable, exactly as `searchText`, `titleMatchKey` and `dueSortKey`
   already are (`Item.swift:300-309`).
2. **The projection must strip `U+FFFC`.** An attachment appears in `NSAttributedString.string`
   as the object-replacement character; measured, present. Left in, every note with an image
   gains a junk character in the search index and in Markdown export.
3. **Checklists need a custom attribute.** `NSTextList.MarkerFormat` has no checkbox case;
   measured. This is a further reason the format must be able to express attributes AppKit has
   no native slot for.
4. **Pasted content must be sanitised, not trusted.** Foreign RTF was measured arriving with a
   hard-coded red foreground colour. Stored unsanitised, it is unreadable in dark mode — the
   plan's "never hard-code black text" rule generalised. The allow-list is where this is
   enforced.
5. Migration of existing notes is literal: today's `body` becomes a single unstyled run with an
   automatic, appearance-adaptive text style. Verified by exact character equality of the
   regenerated projection against the original string, per the plan's migration gate.
6. The legacy `body` read path stays until the migration has been validated and a rollback
   window has passed.
7. Performance is not a differentiator between the candidates and did not inform this decision.
   Both encode a 100,000-character document in under three milliseconds.
