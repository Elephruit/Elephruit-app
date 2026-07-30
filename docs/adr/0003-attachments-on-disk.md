# ADR 0003 — Attachment bytes on disk, metadata in the store

- **Status:** Accepted
- **Date:** 2026-07-29

## Decision

Attachment **bytes** live as files under
`Application Support/Everything/Attachments/<attachment-uuid>/<filename>`.
Attachment **metadata** lives in the SwiftData store as an `Attachment` entity.

Rejected: bytes in the store as `Data`, and bytes in the store with
`@Attribute(.externalStorage)`.

## Rationale

- Keeps the store file small, so migrations stay fast and the whole store remains
  cheap to back up before a migration.
- Makes CloudKit record sizes predictable; Phase 4 maps bytes to `CKAsset` in a
  dedicated record rather than inlining them.
- Export is a directory copy with a predictable, inspectable layout — a requirement,
  not a nicety.
- `.externalStorage` would also keep rows small, but it hands file lifecycle to the
  framework, gives no stable path for export, and makes the on-disk layout opaque.

## Consequences

Two stores means two failure modes: a row with no file, and a file with no row.
Handled by:

1. Writes ordered **file first, then row** — a crash leaves an orphan file, which is
   recoverable, rather than a row pointing at nothing, which is not.
2. A startup integrity pass that reports orphans in both directions and offers
   recovery. It never deletes silently.
3. Permanent deletion removes bytes only after the store transaction commits.
4. Trashing an item never touches bytes, so restore is always possible.
