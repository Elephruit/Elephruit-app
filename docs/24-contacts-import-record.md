# 24 — Contacts import record

Slice **S17**. `docs/17` **P11** moves from *Met on a technicality* to genuinely met: the address
book is now the CRM's starting population, and it stays current afterwards.

## What was built

| Layer | Added |
|---|---|
| **Core** | `SystemContact`, `ContactLabelledValue`/`ContactAccount` (moved down from Integrations), `ContactIdentitySignature`, `ContactSyncState`, `ContactValueOrigin`, `ContactSyncConflict`, `ContactImportPlan` + proposals + outcomes + report + progress |
| **Integrations** | Widened `ContactsProviding` — enumeration, containers, unified contacts, change tokens; rewritten `SystemContactsProvider`; `FixtureContactsProvider` + `ContactFixtures` |
| **Model** | `SystemContactLink`, `ImportedContactValue`, `ContactImportSession`, `ContactField`, `SchemaV5` |
| **Persistence** | `ContactImportService` + `ContactMatcher`, `ContactSyncService` |
| **Features** | `ContactImportModel` (11 phases), onboarding, review, duplicate resolution, `ContactRefreshCoordinator`, `LinkedContactSection`, relink sheet, source badge, rewritten Contacts settings, `.fromContacts` scope |
| **App shell** | People tab in Settings, `-ElephruitUseFixtureContacts` |

## Permission behaviour

The explanation comes **before** the prompt, always. `prepare()` reads the current authorisation
without asking; the system dialogue only follows a deliberate press of *Continue*. That ordering is
the single most consequential thing on the screen, because a macOS denial is permanent and only
System Settings can undo it.

Denied and restricted are separate states with different sentences and different buttons — denied
offers *Open System Settings*, restricted explains it is not the user's to change. Nothing re-prompts:
once macOS has recorded an answer, a "try again" button would show no dialogue and read as broken.

## Data ownership

**The profile is the current value. The ledger is where it came from.** `PersonProfile` keeps holding
the effective emails and phones every existing view already reads; `ImportedContactValue` records per
field and label which contact supplied it, when it was first and last seen, and whether it was
imported, typed here, or overridden. Two homes for one email would be a bug — a value plus its
provenance is not.

A refresh may replace a value the app imported and nobody has touched. That is all it may do. An
overridden value stands, and the newer system value is recorded beside it as a conflict the user
resolves. Superseded rows are kept, so *what did this used to say* is a query.

The CRM owns everything Contacts has no concept of: why somebody matters, private reflections, the
timeline, interactions, promises, tags, groups, relationships, observations, confidence, sensitivity,
briefs, and linked notes. A test asserts all of it survives a refresh untouched.

## Identity

The identifier is a signal, not the identity. Every link stores a normalized signature — folded name,
lower-cased emails, last-ten-digit phones — and reconciliation tries the identifier, then the
signature. Unified contacts are requested from the framework, so macOS's own knowledge that two
account records are one person is inherited rather than re-derived.

A link proposes automatically only on a shared email or phone **and** an agreeing name. Everything
weaker goes to a review screen showing its evidence in words. Two people sharing only a name are
never linked.

## Bugs the tests caught

1. **A person created with a profile was not findable** — carried over from the previous slice's
   pattern and re-verified here.
2. **`add`-style partial name matching** — pinned by an earlier slice, unchanged.
3. **The recovery path re-linked somebody to their housemate.** Maya and her housemate share a
   landline. When Maya's contact was deleted, the signature fallback searched by phone number and
   returned *him* — a silent identity swap in the one code path that exists to be careful. The lookup
   still narrows by contact detail; it now verifies the candidate with
   `ContactIdentitySignature.stronglyMatches` before accepting it. `ContactRefreshTests` pins it.
4. **My own key-hygiene rule failed**, correctly. Dates and relations left the forbidden list because
   they are now genuinely displayed; the notes key stays forbidden permanently, and a new check pins
   the thumbnail key to the on-demand path.

## Two SDK facts, checked against the macOS 27 headers

**Change history is not reachable from Swift.**
`-[CNContactStore enumeratorForChangeHistoryFetchRequest:error:]` is annotated
**`NS_SWIFT_UNAVAILABLE("")`** — its result is `CNFetchResult<NSEnumerator<CNChangeHistoryEvent *> *>`,
a nested ObjC generic that does not bridge. There is no overlay and no alternative spelling; reaching
it needs an Objective-C shim in the app target.

Rather than pretend, the live provider returns `nil` from both token methods — which is the protocol's
documented signal for *reconcile fully*, the same path an expired or foreign token takes, and one the
sync layer had to handle correctly regardless. **So in production every refresh walks the linked
contacts, not a delta.** That is a few hundred rows, coalesced two seconds behind
`CNContactStoreDidChange`. The incremental branch is written and `FixtureContactsProvider` issues real
tokens, so the logic is tested and ready.

**`CNContact.dates` and `CNContact.birthday` disagree about optionality.** `dates` is
`NSArray<CNLabeledValue<NSDateComponents *> *>` — the class does not value-bridge inside a generic, so
its components are non-optional `Int`s carrying `NSDateComponentUndefined`. `birthday` bridges to
`DateComponents?` and is genuinely optional. Confusing the two gives a contact an anniversary in the
year 2147483647.

## Write-back

**Not supported, deliberately, and the interface says so rather than offering a control that does
nothing.** `ContactsProviding` has no write method, `ContactsWriteSafetyTests` fails if the adapter
reaches past it to `CNSaveRequest`, and the onboarding screen states plainly that contacts are never
changed. Editing a detail in Elephruit marks it *overridden* and leaves Contacts alone.

## Verification

| Check | Result |
|---|---|
| `swift test` | **902 tests pass**, up from 828 |
| `xcodebuild` Debug and Release | Succeed, zero warnings |
| Schema 0.0.5 from a real pre-`TimeEntry` store | Passes — `RealStoreMigrationTests` |
| App launches with the synthetic library, renders, stays up | Verified |
| Denied, restricted, empty, populated, changed, deleted, revoked | Covered by tests |
| Retry and cancel do not duplicate | Covered by tests |
| No contact data leaves the device | No network entitlement; sandbox refuses at the kernel |
| No system contact modified | No code path exists |
| **Screens reviewed visually** | **Not done this session** — see below |

### What was not visually checked

Screen capture was unavailable in this session, so the onboarding, review, and duplicate screens were
**not** looked at on a display. The app was launched with the synthetic library, rendered its shell
including the new People band and menu, and stayed up with no crash report — which rules out a
composition failure but is not the same as reading the screen.

What stands in for it: `ContactOnboardingFlowTests` drives `ContactImportModel` through every one of
its eleven phases exactly as the views do, including that preparing the screen does **not** prompt,
that *Select All* respects a search, and that the primary button cannot resolve an ambiguity. Those
are the behaviours a screenshot would have been checked for. Layout, contrast, and focus order were
not verified and should be before this ships.

## Deliberate limitations

- **Incremental refresh does not run in production.** See above. Full reconciliation over linked
  contacts is the live path.
- **No write-back.** Read-only by construction.
- **Contact photos are not imported.** `hasImage` is read; the thumbnail is fetched on demand for one
  person and is not yet rendered — the avatar is still initials. Fetching a whole library's images to
  draw a list is the thing the key discipline exists to prevent, and per-person display is a small
  follow-up.
- **Contact relations are read but never resolved.** They arrive on `SystemContact.relations` and are
  deliberately not turned into CRM relationships; a relation is a name typed in another app.
- **One container per contact.** A unified contact spans containers by definition; the link records
  the first one seen, which is enough to say where it came from and is not claimed to be more.
- **No UI tests.** The `AccessibilityID`s this slice adds are consumed by nothing, exactly as
  `docs/17` I5 records for the rest of the app. That is slice S15's job.

## Follow-up

1. **An Objective-C shim for change history**, which would turn the incremental path on. Small, and
   the only thing standing between the written logic and production.
2. **Render the thumbnail** on the person header, fetched on demand and cached.
3. **Attendee matching** through `ContactMatcher`, which is now the obvious home for it.
4. **Visual review** of the four new screens in light and dark mode.
