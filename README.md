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
| `swift test` | 183 tests, all passing |
| Sandboxed, three entitlements only | Verified against the signed binary |
| Store opens on disk, all nine entities materialise | Verified against the running app |
| Light / dark visual review | **Not done** — see below |

The interface has not been reviewed on screen in light and dark mode. Screen-recording access was
declined, so this is unverified rather than verified. To check it yourself:

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

Phase records: [10 — A scope](docs/10-phase-a-scope.md) ·
[11 — B](docs/11-phase-b-record.md) · [12 — C](docs/12-phase-c-record.md) ·
[13 — D](docs/13-phase-d-record.md) · [14 — E](docs/14-phase-e-record.md) ·
[15 — F](docs/15-phase-f-record.md)

Architecture decision records live in [docs/adr/](docs/adr/).

## Non-negotiables

- No network requests. The app has no network entitlement.
- No analytics, telemetry, or crash-reporting SDKs.
- Secrets in the Keychain only — never in SwiftData, `UserDefaults`, logs, or source.
- No force unwraps, no `try!`, no `fatalError` on a recoverable path.
- Builds without warnings.
- Full-fidelity export ships in v1.
