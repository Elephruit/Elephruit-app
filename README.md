# Elephruit

A private, local-first macOS app that holds one person's entire working memory —
notes, tasks, projects, people, and reference material — in a single linked graph.

Built with Swift 6, SwiftUI, SwiftData, and no third-party dependencies.

## Status

**Milestone 1 (Foundation) — implemented.** See [docs/07-roadmap.md](docs/07-roadmap.md) for the
phase plan and its definition of done.

| Check | Result |
|---|---|
| `xcodebuild` Debug and Release | Succeeds, zero warnings |
| `swift build` (all eight modules) | Succeeds, zero warnings |
| `swift test` | All tests passing |
| Sandboxed, five entitlements only | Verified against the signed binary |
| Store opens on disk, all seventeen entities materialise | Verified against the running app |
| Light visual review | Done — People workspace, estimates, groups, duplicates. **Not** the calendar |
| Dark visual review | **Not done** — see below |

The People module has been reviewed on screen in light mode. **The calendar module has not been
reviewed on screen at all, in either appearance**, and dark mode has never been checked — switching it means changing a system setting, which the session that built the People
module could not do. What is enforced instead is that no view names a literal colour
(`SourceHygieneTests.coloursComeFromTheDesignSystem`), so every colour resolves through AppKit's
semantic palette in light, dark, Increase Contrast, and under a non-default accent. That is the part
that stays true; it is not a substitute for looking.

The same applies to **selected** rows, which are their own appearance and were their own bug: naming
a colour opts a row out of the selected-content colour a focused `List` sets, so every row in the app
was dark text on the accent fill. Rows now ask for a `Theme.Emphasis` instead of a colour and
`RowEmphasisTests` pins the rule down. To check any of this yourself:

```bash
xcodebuild -project Elephruit.xcodeproj -scheme Elephruit -configuration Debug build
```

Then run the app with sample data and a throwaway library, so nothing real is touched:

```bash
open -n "$(xcodebuild -project Elephruit.xcodeproj -scheme Elephruit -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}' | head -1)/Elephruit.app" --args -ElephruitDevelopmentMode -ElephruitUseTemporaryStore
```

Sample data then appears under **Settings ▸ Advanced ▸ Load Sample Data**. Switch appearance in
System Settings ▸ Appearance, and turn on Reduce Motion and Increase Contrast in
Accessibility ▸ Display to exercise those paths.

### Reviewing the calendar without using your own calendar

Add `-ElephruitUseFixtureCalendar` to the launch arguments above. The app then reads a **synthetic**
calendar of invented events on fictional calendars, and `EKEventStore` is never constructed.

It deliberately contains the cases worth looking at rather than the ones that are typical: a morning
where three meetings clash, a four-day trip spanning the all-day band, a recurring standup, an
invitation that was declined, a meeting that was cancelled and is still visible, a call pinned to
another time zone, and a subscribed calendar that refuses an edit and says why. A calendar of tidy
one-hour meetings demonstrates nothing.

The whole module is then reachable from **Calendar** in the sidebar, or `⌘6`. The flag is ignored
outside development mode, so a release build can never be talked into showing fiction where somebody
expects their own calendar.

**To use your real calendar instead**, launch without that flag and turn it on in Settings ▸ General
▸ Calendar. Unlike Contacts, Elephruit *does* write here — creating and changing the events you ask
it to. What it never writes is anything you record *about* a meeting: linked people, your own notes,
what you promised. Those stay in Elephruit, and `EventDraft` has nowhere to put them —
`CalendarWriteSafetyTests` fails if a field is added that could.

### Reviewing the Contacts import without using your own contacts

Add `-ElephruitUseFixtureContacts` to the launch arguments above. The app then reads a **synthetic**
address book of ten invented people — `example.com` addresses, 555 numbers — that deliberately
contains the awkward cases: a record matching somebody already in the CRM, two different people
sharing a surname, a housemate sharing a phone number, a row with no name at all, a birthday with no
year, and a custom phone label. `CNContactStore` is never constructed.

The whole flow is then reachable from **People ▸ + ▸ Import from Contacts…**, and again from
**Settings ▸ People**. The flag is ignored outside development mode, so a release build can never be
talked into showing fiction where somebody expects their own address book.

**To use your real contacts instead**, launch without that flag and turn the integration on in
Settings ▸ People. Elephruit reads them and never writes: `ContactsProviding` has no write method,
and `ContactsWriteSafetyTests` fails if the adapter ever reaches past it.

### Reviewing the Tasks module, and its Reminders link

Sample data includes one of every state Tasks can be in — a planned Today with a manual order, Later
Today, an overdue deadline, a future start date, a reminder that is not a deadline, a project with
sections, a list, Someday, waiting on a person, both kinds of repeat, steps, subtasks, a promise, a
task made from a note, completed and cancelled history, and all four Reminders states. **None of it
touches your Reminders**: the linked rows are written directly, so no permission is requested.

Apple Reminders is the **first integration in this app that writes**. Calendar and Contacts are
read-only by construction — their protocols have no write method — and that is not available for a
task manager that has to be able to tick a reminder off. So the guarantee is different and is
checked rather than compiled: every write is a `ReminderWrite` value that can be shown before it
happens, `apply(_:)` is the only door, and `RemindersWriteSafetyTests` counts the EventKit write
calls in the adapter so that adding one has to be justified.

Nothing private crosses. Areas, projects, sections, Today, Someday, waiting-for, linked people, and
provenance stay here and are never written into a reminder's title or notes — that text would appear
in Apple's own app on every device, and in a shared list to everybody it is shared with. The full
list, with a reason for each, is in Settings ▸ Tasks.

**To connect your real Reminders**, open Settings ▸ Tasks, read the explanation, and press *Connect
Reminders…*. No list participates until you tick it, and disconnecting leaves every existing link
intact.

No automated test can reach a real Reminders database: the test targets never import EventKit, and
`FixtureRemindersProvider` — an in-memory store with a read-only shared list, a timed reminder, an
all-day one, a repeating one, and one already completed — is the only implementation they can
construct.

## Requirements

- macOS 26 or later
- Xcode 27 or later

## Building

```bash
open Elephruit.xcodeproj
```

Or from the command line:

```bash
xcodebuild -project Elephruit.xcodeproj -scheme Elephruit -configuration Debug build
```

The module tests run without Xcode, signing, or a simulator:

```bash
swift test --package-path Packages/ElephruitKit
```

## Design documents

Read these before changing anything structural.

| Document | Contents |
|---|---|
| [01 — Product definition](docs/01-product-definition.md) | Vision, principles, non-goals, the nine primary journeys, command surface |
| [02 — Architecture](docs/02-architecture.md) | Module graph, concurrency and state rules, AppKit policy, multiplatform readiness |
| [03 — Storage matrix](docs/03-storage-matrix.md) | Which technology owns which data, and why |
| [04 — Domain model](docs/04-domain-model.md) | Entities, relationships, invariants |
| [05 — CloudKit & migrations](docs/05-cloudkit-and-migrations.md) | Sync constraints honoured from v1, conflict policy, migration rules |
| [06 — Privacy & entitlements](docs/06-privacy-and-entitlements.md) | No-network posture, entitlement schedule, accessibility commitments |
| [07 — Roadmap](docs/07-roadmap.md) | Phases 1–5 and the milestone-1 implementation plan |
| [08 — Risks](docs/08-risks.md) | Twelve risks with mitigations and documented fallbacks |
| [09 — v2 plan](docs/09-v2-plan.md) | The plan phases A–F were built against |
| [16 — Expansion audit](docs/16-expansion-audit.md) | Stage 0. Frozen state of the codebase against the expansion specification |
| [17 — Coverage matrix](docs/17-expansion-coverage-matrix.md) | Every expansion requirement, its status and its closing slice |
| [18 — Architecture checkpoint](docs/18-architecture-checkpoint.md) | Standing rules, the four seams, deferred decisions |
| [19 — Permissions matrix](docs/19-permissions-matrix.md) | Entitlements and usage strings, per capability |
| [20 — Expansion slices](docs/20-expansion-slices.md) | The ordered slice list |
| [21 — People module scope](docs/21-people-module-scope.md) | The five decisions behind the People module |
| [22 — People module record](docs/22-people-module-record.md) | What was built, the bugs found, what was deliberately left |
| [23 — Contacts import scope](docs/23-contacts-import-scope.md) | The six decisions behind reading the address book |
| [24 — Contacts import record](docs/24-contacts-import-record.md) | Permission, provenance, refresh, and two SDK facts worth knowing |
| [25 — Calendar module scope](docs/25-calendar-module-scope.md) | The nine decisions behind reading *and writing* the calendar |
| [26 — Calendar module record](docs/26-calendar-module-record.md) | What was built, seven bugs found, and three EventKit limits worth knowing |
| [27 — Tasks module record](docs/25-tasks-module-record.md) | The three dates, Today as a plan, the Reminders write guarantee, and what was left |
| [28 — The task-port message](docs/28-task-port-message.md) | Who emits it, why it is not ours, and the one real defect finding out surfaced |
| [30 — Today](docs/30-today-record.md) | Why Home and Upcoming became one destination, the relevance rules, and what was deliberately left |

Phase records: [10 — A scope](docs/10-phase-a-scope.md) ·
[11 — B](docs/11-phase-b-record.md) · [12 — C](docs/12-phase-c-record.md) ·
[13 — D](docs/13-phase-d-record.md) · [14 — E](docs/14-phase-e-record.md) ·
[15 — F](docs/15-phase-f-record.md)

Architecture decision records live in [docs/adr/](docs/adr/).

## Non-negotiables

- No network requests. The app has no network entitlement.
- Nothing recorded *about* a person or a meeting is ever written to a system calendar or contact.
- No analytics, telemetry, or crash-reporting SDKs.
- Secrets in the Keychain only — never in SwiftData, `UserDefaults`, logs, or source.
- No force unwraps, no `try!`, no `fatalError` on a recoverable path.
- Builds without warnings.
- Full-fidelity export ships in v1.
