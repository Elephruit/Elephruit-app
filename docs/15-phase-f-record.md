# Phase F — Capture, attachments, drag and drop

---

## 1. Global capture without asking for Accessibility

A real global hotkey needs either the **Accessibility permission** — a large ask for a note-taking
app, and one people are right to be wary of — or Carbon's `RegisterEventHotKey`, which works in a
sandbox but is undiscoverable and collides silently with whatever else claimed the combination.

An **App Intent** gets a user-assigned global shortcut for free through Shortcuts.app. The user picks
the key, macOS owns conflict resolution, and Elephruit needs **no extra entitlement and no permission
prompt at all**. It also arrives in Spotlight and the Shortcuts editor without further work.

The trade is real: the user has to assign the shortcut once. That cost buys not asking for
Accessibility, which is the right side of this trade for this app.

`openAppWhenRun` is `false`. The point of capture is not to interrupt what you were doing; an intent
that stole focus would be a slower way of switching to the app by hand.

The intent opens its own store when the app is not running — capture has to work from a cold start,
which is most of when it is useful — and adopts the app's container when it is.

---

## 2. Attachments: two kinds, and the consequence of each stated

A file is either **copied in** — Elephruit owns the bytes, they live under the container, they export
cleanly and survive the original being deleted — or **referenced** by a security-scoped bookmark,
where the user keeps the file and Elephruit keeps a pointer.

**Copying is the default.** A reference is right for a 2 GB video or a document actively edited
elsewhere, and wrong for a screenshot dragged in from Downloads that will be tidied away next week.
An attachment that evaporates a week later is worse than the disk it would have cost to keep.

Two rules that are asserted rather than assumed:

- **Removing a referenced attachment never deletes the file.** Elephruit does not own it, and
  detaching must not remove someone's document from their Desktop.
- **A missing file is a state, not an error.** `referenceLostAt` is set, the row keeps its filename
  and last known path, and offers "Locate…". Nothing throws and nothing disappears — a gap where
  something used to be is worse than a row saying what is missing.

Bytes land at `Attachments/<uuid>/<filename>`, so two files with the same name cannot collide and
removing one attachment is removing one directory.

A stale bookmark that still resolves is **rewritten**, so the slow resolution does not repeat on
every open until the user happens to relocate the file by hand.

---

## 3. Drag and drop

Dropping a file on a note attaches it. The target highlights while hovering — it says what it will
do before it does it — and the file is **copied, never moved**, so nothing leaves the user's Desktop
because they aimed slightly wrong.

---

## 4. What is verified

| Property | Test |
|---|---|
| A copied file survives the original being deleted | `copiesAreIndependent` |
| Two files with the same name do not collide | `sameNameDifferentAttachments` |
| Identical bytes hash identically | `contentHashing` |
| Removing a copy deletes its bytes | `removingCopyDeletesBytes` |
| **Removing a reference leaves the user's file alone** | `removingReferenceKeepsTheFile` |
| **A missing file is recorded, not thrown** | `missingReferenceIsRecorded` |
| A lost reference can be relocated | `relocating` |
| Attachments survive a relaunch | `attachmentsAreDurable` |
| The file type is recorded for preview | `typeIdentifierIsRecorded` |

Run against a **real store on a real filesystem**. In-memory would prove nothing here: the feature is
bytes on disk, files that move, and bookmarks that go stale.

**521 tests pass. Debug and Release build with zero warnings.**

---

## 5. The product-wide audit

### Entitlements — exactly four

```
com.apple.security.app-sandbox
com.apple.security.files.user-selected.read-write
com.apple.security.files.bookmarks.app-scope
com.apple.security.personal-information.calendars
```

**No network entitlement.** Without it the sandbox refuses outbound connections at the kernel
boundary, which makes "this app makes no network requests" verifiable rather than promised. No
URLSession, NWConnection or CFNetwork call exists anywhere in the sources.

Deliberately absent: network client and server, iCloud, CloudKit, Contacts, Reminders, Photos,
Camera, Microphone, Location, Bluetooth, USB, Downloads folder, Apple Events, JIT, and every
temporary exception. The calendar entitlement went in **in the same commit as the feature that needs
it**, which is the rule from `docs/06`.

### Privacy

- **No analytics, telemetry, or crash reporting.** The only occurrence of those words in the entire
  source is the Settings copy stating there is none.
- **No secrets anywhere.** Nothing is written to SwiftData, UserDefaults, or a log that is a
  credential. Security-scoped bookmarks are stored — they are OS-issued capabilities for files the
  user already chose, not secrets, and the store is their correct home.
- **One usage description**, `NSCalendarsFullAccessUsageDescription`, which says both what is read
  and that nothing is written.

### Dependencies — zero

No third-party package, at any point, across six phases. FTS5 is reached through the system
`sqlite3`; everything else is Apple's.

### Code rules

- Compiles with **warnings as errors** in every target, Debug and Release
- No force unwraps, no ignored errors, no `fatalError` for a recoverable condition
- No `@unchecked Sendable`, no `nonisolated(unsafe)`, no `@preconcurrency` — each enforced by
  `SourceHygieneTests`, and each of which fired at least once during these phases and was right to
- No singletons

---

## 6. Not built

- **CloudKit sync.** Deferred by decision; the schema has carried its requirements from day one —
  every attribute optional or defaulted, no unique constraints on synced entities, inverse
  relationships everywhere.
- **Contacts integration.** The entitlement is absent, which is the point.
- **Notifications of any kind.** No entitlement, no badge, no scheduled alert.
- **A calendar grid view.** Events appear in Today, Upcoming and Home; the `calendar` destination is
  still declared-but-unavailable.
- **Frozen schema model types.** The live-types shortcut has now demonstrably broken once — see
  `docs/12` — and the next non-additive schema change makes freezing mandatory.
