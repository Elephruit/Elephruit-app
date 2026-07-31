# 23 — Contacts import scope

Slice **S17**. The People module currently holds a *pointer* into Contacts —
`PersonProfile.contactsIdentifier` — and a search box that finds one contact at a time. This slice
turns the address book into the CRM's starting population, and then keeps it current.

`docs/17` **P11** moved to Met last slice on the strength of read access and a link. That was true
and too small: linking one person at a time is not a starting point for a personal CRM, and a link
that never refreshes is a copy with extra steps.

## The six decisions

**1. The profile is the current value; the ledger is where it came from.**
`PersonProfile` keeps holding the effective emails, phones, and addresses that every existing view
already reads — nothing about the People module changes shape. Beside it, `ImportedContactValue`
records, per field and per label, *which* system contact supplied a value, when it was first and last
seen, and whether it was imported, typed here, or deliberately overridden. This is the same division
the fact model already makes: a current answer, and a history that explains it. Two homes for one
email would be a bug; a current value plus its provenance is not.

**2. A link is an entity, not a column.** `SystemContactLink` replaces the bare identifier. A link has
a state — linked, unavailable, or unreadable — a container, a last-refresh date, and an identity
signature. `contactsIdentifier` stays on the profile as a mirror so nothing that reads it breaks, and
the link is what the sync layer actually works with.

**3. The identifier is a signal, not the identity.** `CNContact.identifier` changes when accounts are
removed and re-added, and disappears when a contact is deleted. So every link also stores a
**normalized identity signature** — folded name plus normalized emails and phones — and reconciliation
falls back to it when the identifier no longer resolves. A link that cannot be resolved by either is
marked *unavailable* and keeps its last known values. It is never deleted, and neither is the person.

**4. Nothing ambiguous is decided automatically.** A shared system identifier, or a shared email *and*
a matching name, proposes a link. Everything weaker goes to a review screen that shows its evidence in
words. Two people sharing only a name are never merged — the existing `IdentityMatcher` already
refuses that, and this slice does not weaken it.

**5. Idempotency comes from the link, not from a session flag.** Re-running an import finds the
existing `SystemContactLink` for a contact and reports *already linked* rather than creating a second
person. That holds for a retry, a cancelled run resumed later, and a refresh — no bookkeeping the user
has to get right.

**6. Read-only, and said out loud.** `ContactsProviding` still has no write method, and
`ContactsWriteSafetyTests` still fails if the adapter reaches past it. Write-back is **not** in this
slice; the interface says so where a user would look for it rather than offering a control that does
nothing.

## What is added

| Layer | Added |
|---|---|
| **Core** | `SystemContact` snapshot, `ContactIdentitySignature`, `ContactImportPlan` + `ContactImportProposal` + outcomes, `ContactSyncState`, `ContactValueOrigin`, `ContactSyncConflict` |
| **Integrations** | Widened `ContactsProviding` — enumeration, containers, change history, unified contacts; `FixtureContactsProvider` for tests and previews |
| **Model** | `SystemContactLink`, `ImportedContactValue`, `ContactImportSession`, `SchemaV5` |
| **Persistence** | `ContactImportService` (plan, apply, resume), `ContactSyncService` (refresh, change history, reconciliation) |
| **Features** | Onboarding, import review, duplicate resolution, Contacts settings, a linked-contact section on a person, sidebar source filter |

Schema goes to **0.0.5**: three new entities, every attribute optional or defaulted. Additive, so
lightweight inference handles it — the path `TimeEntry` and the People entities both took.

## What is deliberately not modelled

**`ContactAccountLink` as an entity.** The container identifier and its system-provided name live on
`SystemContactLink`. A separate entity would carry one string and a name, be joined on every read, and
answer no question the column cannot — R5 asks for proof the simpler shape fails first, and there is
none to offer.

**`ContactSyncConflict` as an entity.** A conflict is not a thing that exists independently: it is the
*relationship* between an overridden local value and a newer system one, and both are already rows.
It is computed from them, which means it cannot go stale or be orphaned.

**The Contacts notes field.** Reading it needs
`com.apple.developer.contacts.notes`, an entitlement Apple grants by request for a purpose this app
does not have. The CRM's own notes are the point of the CRM, and mixing the two would be the exact
flattening this module exists to prevent.
