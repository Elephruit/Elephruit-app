# Privacy and entitlement plan

## Privacy posture

The app made **no network requests of any kind** in v1. Not for analytics, not for
crash reports, not for update checks, not for link previews. That was verifiable rather than
promised: the app had no `com.apple.security.network.client` entitlement, so an attempted
outbound connection would fail at the sandbox boundary rather than silently succeed.

**Since then the Mac has grown two endpoints, and the posture is now a list rather than a
denial.** Kept in the past tense above because the sentence is worth having on the record —
losing the kernel-enforced version of a guarantee is a thing that should be visible in the
document, not quietly overwritten.

| Endpoint | Reached when | Carries |
|---|---|---|
| Apple's CloudKit | Sync is on, which it is not until somebody turns it on | The user's own library, in the user's own private database |
| Apple Maps (`MKLocalSearch`) | Somebody is typing into a record's place field, and at no other moment | The typed words, and nothing else — never a note, never who the record is about |

Everything else in the table below is unchanged: no analytics, no telemetry, no crash reporting,
no third-party service, and no `URLSession` of our own anywhere in the sources.

The Maps search has **no switch**, unlike every integration in `docs/19`, because it is not a
standing permission — it is a thing that happens while somebody is doing it. That is a defensible
position and it is also the reason it went uncounted in every place that lists what this app talks
to: a feature with no toggle appears on no settings screen, so nothing ever prompted anybody to
write it down, and the copy went on claiming a number that had already changed. A
third endpoint changes this table, `Configuration/Elephruit.entitlements`, the Sync footer in
`Elephruit/SyncSettingsSection.swift`, and the Privacy tab in `Elephruit/ElephruitApp.swift`, in
one commit.

| Practice | Position |
|---|---|
| Analytics / telemetry | None. No SDK, no counters, no "anonymous usage data". |
| Crash reporting | None bundled. Users may opt into Apple's own reporting at the OS level. |
| Third-party services | None. |
| Diagnostics | `OSLog` only, on-device, never written to a file by us. |
| User content in logs | Never. Log statements use IDs, counts, and durations. Any interpolation of user text uses `privacy: .private` explicitly, and a test greps the sources for unannotated interpolation in log calls. |
| Secrets | Keychain only, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Never in SwiftData, `UserDefaults`, source, or logs. v1 stores no secrets at all — the facility exists for future integrations. |
| Encryption | The store relies on FileVault and the sandbox container. No custom crypto. If per-note encryption is added later it will be an explicit, documented feature, not a silent default. |

## Entitlements

### v1 (milestone 1)

| Entitlement | Value | Why |
|---|---|---|
| `com.apple.security.app-sandbox` | `true` | Required for the App Store; required by principle. |
| `com.apple.security.files.user-selected.read-write` | `true` | Open/save panels for import, export, and attaching files. |
| `com.apple.security.files.bookmarks.app-scope` | `true` | Security-scoped bookmarks for referenced external files. |

Deliberately **absent** in v1: network client, network server, iCloud, EventKit,
Contacts, Photos, Camera, Microphone, Location, Address Book, Bluetooth, USB,
downloads folder, Apple Events, JIT, and any `com.apple.security.temporary-exception`.

### Added later, each gated on a real feature

| Entitlement | Arrives with | User-facing gate |
|---|---|---|
| `com.apple.developer.icloud-container-identifiers`, `com.apple.developer.icloud-services` (`CloudKit`), `com.apple.security.network.client` | Phase 4 sync | Sync is **off by default**; a settings toggle turns it on, and the first enable explains what leaves the device (the private database only) and what does not. |
| `com.apple.security.personal-information.calendars` | Phase 3 EventKit | Off by default. The system prompt is only triggered by the user pressing "Connect Calendar", never at launch. |
| `com.apple.security.personal-information.addressbook` | Phase 3 Contacts | Same pattern. |
| `com.apple.security.application-groups` | Widget / share extension | No user-visible permission. |

### Live Activities (iPhone)

`NSSupportsLiveActivities` is a capability declaration rather than an entitlement: it asks for
no permission, opens no prompt, and reaches no network. It is listed here anyway, because what
it does is put app content on a **locked screen** — a surface anybody standing behind the owner
can read — and that deserves the same accounting as an entitlement does.

One activity exists, for a running timer, and what it may contain is bounded by the shape of
`Shared/TimerActivityAttributes.swift`: a title, one line of filing (the project, or the typed
description), a start date, and whether the entry is billable. Deliberately absent, on exactly
the terms the calendar mirror already refuses them in `docs/29`:

- **People.** Who you are with is a fact about them, and a Lock Screen has an audience they
  never agreed to.
- **The note.** Whatever an item says is why it lives in this app rather than in a calendar.

The activity is requested only while an entry is running and ended `.immediate`ly when it
stops, so a clock never outlives the work it was counting. Turning Live Activities off in
Settings is honoured silently — the app keeps timing and says nothing about it.

Principle: **an entitlement is added in the same commit as the feature that needs
it, and no earlier.** A shipped binary should not be able to do things the user has
not asked for.

### Purpose strings (`Info.plist`)

Written when the corresponding entitlement is added, in plain language that says
what the app does with the access and that it is optional:

- `NSCalendarsUsageDescription` — "Elephruit can show your events alongside your
  daily notes and link meetings to projects. Your calendar stays on your Mac and in
  iCloud; Elephruit never sends it anywhere."
- `NSContactsUsageDescription` — "Elephruit can link the people in your notes to
  your existing contacts, so you do not have to retype them. It changes a contact
  only when you edit that person in Elephruit and confirm the change, and only
  their name, nickname, birthday, email addresses, phone numbers, websites, job
  title, department, and company. It never touches their photo, postal address, or
  notes, and it never creates or deletes contacts."

  Contacts has a single access tier, so read access carries write access and the
  user cannot grant less. This string is therefore where the app states the limit
  it holds itself to, and `ContactsWriteSafetyTests` is where that limit is
  enforced against the source rather than against a reviewer's memory.
- `NSRemindersFullAccessUsageDescription` — written only if Reminders import ships.

### App Store privacy declaration

**Data Not Collected** across every category. That answer is only defensible because
of the no-network posture above, so it constrains the roadmap, not just the form.

## Accessibility commitments (v1, not deferred)

- Every control has an accessibility label; every list row exposes a composed label
  ("Task, Draft the launch brief, due tomorrow, project Q3 Launch, incomplete").
- Full keyboard operability: focus order is explicit, focus rings are visible, no
  action is mouse-only, and `Tab`/`⇧Tab` traverse sidebar → list → detail.
- Dynamic type respected via `Font.TextStyle`-relative sizing; no hard-coded point
  sizes in the design system's public API.
- Contrast ≥ 4.5:1 for text in both appearances, verified against the semantic
  palette; **Increase Contrast** honoured.
- **Reduce Motion** honoured — every animation in the design system goes through one
  helper that returns `nil` when the setting is on.
- **Reduce Transparency** honoured — materials fall back to opaque fills.
- VoiceOver rotor support for headings in the note editor.
- Accessibility identifiers on every element a UI test touches, named in one
  `AccessibilityID` namespace so tests and views cannot drift apart.

## Sandbox implications on the implementation

1. Any file the user picks is reachable only through a security-scoped URL.
   `startAccessingSecurityScopedResource()` is always balanced by a `defer`, wrapped
   in one `withSecurityScopedAccess(_:)` helper so it cannot be forgotten.
2. Attachments default to **copy-in** (managed) rather than reference, because a
   referenced file breaks when the user moves it and cannot sync. Reference is
   offered explicitly for large files.
3. Import reads inside the panel's scope and writes into the container; export writes
   only to the user-chosen destination.
4. Quick Look uses the sandbox-safe `QLPreviewPanel` against container-local copies.
