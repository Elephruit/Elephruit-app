# Permissions and entitlements matrix

Living document. Amends `docs/06-privacy-and-entitlements.md` for the expansion; `docs/06` is a
shipped record and is not edited.

The rule from `docs/06` stands: **an entitlement lands in the same commit as the feature that
needs it.** Honoured once already — `com.apple.security.personal-information.calendars` went in
with the calendar feature, not before it.

---

## 1. What ships today

### Entitlements — exactly four

`Configuration/Elephruit.entitlements`

| Entitlement | For |
|---|---|
| `com.apple.security.app-sandbox` | Everything |
| `com.apple.security.files.user-selected.read-write` | Import, export, attachment picker |
| `com.apple.security.files.bookmarks.app-scope` | Referenced attachments surviving relaunch |
| `com.apple.security.personal-information.calendars` | EventKit read |

**There is no network entitlement.** Without it the sandbox refuses outbound connections at the
kernel boundary, which makes "this app makes no network requests" *verifiable* rather than
promised. No `URLSession`, `NWConnection` or CFNetwork call exists anywhere in the sources.

Deliberately absent: network client and server, iCloud, CloudKit, Contacts, Reminders, Photos,
Camera, Microphone, Location, Bluetooth, USB, Downloads folder, Apple Events, JIT, and every
temporary exception.

### Usage descriptions — exactly one

`Configuration/Info.plist`

| Key | String |
|---|---|
| `NSCalendarsFullAccessUsageDescription` | "Elephruit shows your events alongside your tasks and notes. It only reads your calendar and never changes it." |

The deprecated `NSCalendarsUsageDescription` is deliberately not used, and the file says so inline.

### Other privacy-relevant settings

| Key | Value | Why |
|---|---|---|
| `NSSupportsSuddenTermination` | `false` | The editor's writes are debounced. Bug 7 in `docs/16 §6` is the other half of this and is not yet fixed |
| `NSApplicationSupportsSecureRestorableState` | `true` | — |

---

## 2. Per-capability matrix

| Capability | Entitlement | Usage string | Default | Gate | If denied | Test that proves the negative |
|---|---|---|---|---|---|---|
| **Calendar read** | `personal-information.calendars` | `NSCalendarsFullAccessUsageDescription` | **Off** | Settings toggle, `calendar.isEnabled` | Explained state with "Open System Settings"; Today and Upcoming still work | `CalendarWriteSafetyTests` bans 11 write symbols in source; `.writeOnly` maps to `.denied` |
| **Calendar write** | — | — | — | — | — | **Never.** The protocol has no write method and `EKEventStore` never escapes the actor |
| **Global hotkey** | **none** | **none** | Proposed ⌘⇧J, unbound on collision | Settings | Command left unbound, reason shown | Registration failure is surfaced, not swallowed. ADR 0008 |
| **App Intent capture** | none | none | On | — | — | `openAppWhenRun = false` — never steals focus |
| **Attachments** | `files.user-selected.read-write`, `files.bookmarks.app-scope` | none | On | User picks the file | Lost reference is a state with "Locate…" | `removingReferenceKeepsTheFile` |
| **Contacts read** | `personal-information.addressbook` | `NSContactsUsageDescription` | **Off** | Settings toggle, `contacts.isEnabled` | People remain fully usable — internal `Person` is the durable identity | `ContactsWriteSafetyTests` bans create/delete symbols and caps the fetched key list |
| **Contacts write** | *(same — Contacts has one access tier)* | *(same)* | **Off** | Per-edit confirmation in `ContactWriteBackSheet` | Refusal is reported; the local record keeps the edit either way | Name, nickname, birthday, emails, phones, sites, job title, department, organisation — and nothing else, enforced by `ContactWrite` having no other field and a test asserting the exclusions stay excluded; `CNSaveRequest`, `store.execute`, and `CNMutableContact` asserted to appear once each; **never** creates or deletes |
| **Notifications** | none needed; `UNUserNotificationCenter` requires authorization | none | Would be **off** | Per-reminder opt-in | Reminders silently unavailable, never a nag | — |
| **Camera / Continuity Camera** (business-card scan) | `device.camera` *(not present)* | `NSCameraUsageDescription` *(not present)* | Would be **off** | Invoked only from "Scan a card" | Feature hidden, not broken | To be written: scan never creates a contact silently |
| **Idle detection** | none — `IOKit` idle time needs no entitlement | none | Would be **off** | Settings | Timer behaves exactly as today | Must never delete time silently |
| **Activity suggestions** | would need Accessibility | — | **Rejected for now** | — | — | Requires a separate privacy review before it is even designed |
| **Network** | **none, ever** | — | — | — | — | Absence of the entitlement is the proof |

---

## 3. Rules for the capabilities not yet built

1. **Contacts is read-first and link-only.** The internal `Person` is the durable identity; a
   system contact is something a person *links to*, not something they are. Writes to a system
   contact require an explicit user action every time.
2. **What stays local and never leaves Elephruit:** private reflections, observations, confidence
   and provenance, timeline entries, and app-only links. Sharing exposes only chosen standard
   contact fields.
3. **The app must be fully usable with Contacts and Calendar both denied.** This is already true
   for Calendar and must stay true.
4. **The camera is invoked only from the scan action**, and the scan presents extracted fields for
   review. It never creates a contact silently.
5. **Activity suggestions stay off by default, local, inspectable, excludable, retention-limited
   and fully deletable**, and capture no screenshots, keystrokes, clipboard or document content.
   They are not designed until ordinary tracking is valuable on its own.
6. **No analytics, telemetry, or crash reporting.** The only occurrence of those words in the
   sources today is the Settings copy stating there is none. That stays true.

---

## 4. What a permissions centre must show

Not built. When it is, it distinguishes five states per capability — the vocabulary already exists
as `IntegrationAuthorization` (`CalendarEvent.swift:192-223`) and should be reused rather than
reinvented:

`notRequested` · `authorized` · `denied` · `restricted` · `unavailable`

with `canRead`, `isWorthAsking`, and a one-sentence `explanation` per refused state. Read-only is
represented honestly: EventKit's `.writeOnly` maps to `.denied`, on the grounds that "the app
cannot see anything" is the truthful reading for a feature that only reads.
