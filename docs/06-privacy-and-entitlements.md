# Privacy and entitlement plan

## Privacy posture

The app makes **no network requests of any kind** in v1. Not for analytics, not for
crash reports, not for update checks, not for link previews. This is verifiable: the
app has no `com.apple.security.network.client` entitlement, so an attempted outbound
connection would fail at the sandbox boundary rather than silently succeed.

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

Principle: **an entitlement is added in the same commit as the feature that needs
it, and no earlier.** A shipped binary should not be able to do things the user has
not asked for.

### Purpose strings (`Info.plist`)

Written when the corresponding entitlement is added, in plain language that says
what the app does with the access and that it is optional:

- `NSCalendarsUsageDescription` — "Everything can show your events alongside your
  daily notes and link meetings to projects. Your calendar stays on your Mac and in
  iCloud; Everything never sends it anywhere."
- `NSContactsUsageDescription` — "Everything can link the people in your notes to
  your existing contacts, so you do not have to retype them. Contacts are read on
  demand and never copied out of your Mac."
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
