# ADR 0009 — What an archive must contain to be a backup

- **Status:** Accepted
- **Date:** 2026-07-30

## Decision

A full Elephruit archive carries:

- **Attachment bytes** for every managed copy, at the `bundlePath` the archive already names.
- **Attachment references** recorded as references — filename, type, last known path — and
  deliberately *not* copied, because Elephruit does not own those bytes.
- **`TimeEntry` records**, with exact intervals, identifiers, links, tags and sources.

The archive format version bumps **forward-only**: a newer version is refused before anything is
written, and every older version always imports.

An archive that omits any of these is a **data-loss defect**, not a documented limitation.

## Rationale

Two things are missing today, and both are silent.

**Attachments are named but not written.** `Exporter.record(for:)` emits an `ArchiveAttachment`
carrying `bundlePath: attachment.exportRelativePath` (`Exporter.swift:221-234`). No code copies
the bytes — `MarkdownBundle.swift:176` still marks the slot `← Phase 2` — and `Importer` never
reads `archive.attachments` at all. So every archive ever written contains a path to a file that
is not in the bundle, and every import silently drops every attachment. `RoundTripTests` has zero
occurrences of the word, which is why roughly thirty-five otherwise-thorough tests did not catch it.

**Time history is absent entirely.** `TimeEntry` appears nowhere in `Sources/ElephruitTransfer`.
An export/import round trip destroys every tracked interval.

This is worse than a gap because of what the repo already says about exports. `Exporter.swift:93-94`
records that trashed and archived items are included deliberately, because "an export is a backup."
That is the promise. Two capabilities' data is currently outside it.

The reference/copy asymmetry follows from ADR 0003 and from the rule Phase F already asserts:
"Removing a referenced attachment never deletes the file. Elephruit does not own it." An archive
that copied referenced bytes would be claiming ownership the app explicitly disclaims. Recording
the reference — and letting the import surface it as a lost reference if the file is gone, which
is already a modelled state — is the honest behaviour.

## Consequences

1. The format version bumps. The existing guard already refuses a newer `formatVersion` before
   writing anything (`ArchiveFormat.swift:420-429`); the new obligation is the other direction —
   **v1 archives must still import**, and a test must say so.
2. Round-trip tests gain: a managed attachment whose bytes come back with a **matching SHA-256**;
   a reference that round-trips *without* its bytes being copied; and a running timer that exports
   and re-imports as running. `contentHash` is currently computed, stored, and read by nothing —
   this is its first real use.
3. Archive size grows by the size of the attachments, which is the point of it being a backup.
4. This ships as its **own slice**, not folded into a bug-fix slice. Folding a format version bump
   into a correctness commit makes the correctness fix un-revertable.
5. CSV export is unaffected and stays explicitly not-a-backup: no bodies, no links, no bytes.
