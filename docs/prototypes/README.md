# Prototypes

Throwaway experiments that decided an ADR. Not part of any build target, not compiled by
`swift test`, and not shipped. Kept so the evidence behind a decision can be re-run rather
than taken on trust.

## `format-gate.swift` — decided ADR 0006

Runs RTFD and `NSKeyedArchiver` against everything the expansion asks a note to hold:
custom attributes, tables, nested lists, attachments with stable identity, the plain-text
projection, a 100,000-character document, and a paste of foreign RTF.

```bash
swiftc -O docs/prototypes/format-gate.swift -o /tmp/formatgate && /tmp/formatgate
```

Three checks are **expected to fail**, and their failure is the finding: RTFD silently drops
custom attributes, which is why it cannot store a wiki-link target or attachment identity.
Results are recorded in `docs/16 §7`.
