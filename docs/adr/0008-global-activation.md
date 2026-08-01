# ADR 0008 — App Intent is the mechanism; a native hotkey is the convenience

- **Status:** Accepted
- **Date:** 2026-07-30

## Decision

Quick capture keeps the **App Intent** as its permission-free global mechanism, and gains a
**native hotkey** through a central shortcut registry built on Carbon `RegisterEventHotKey`.

The registry owns default bindings, user customisation and disablement, collision detection,
clean unregister/re-register, and one owner per command. `⌘⇧J` is the **proposed** default for
Quick Jot. Registration failure is non-fatal: the command is left unbound, and the reason is
surfaced in Settings.

No Accessibility permission is requested. No entitlement is added.

## Rationale

This continues a decision already recorded rather than reversing one.
`docs/10-phase-a-scope.md:38-49` — "Capture verification (decision 2)" — already establishes both
halves:

> **Carbon `RegisterEventHotKey` works in a sandboxed Mac App Store app with zero entitlements.**
> […] Phase F ships the intent and the Services entry; **the built-in hotkey picker becomes a
> convenience rather than the mechanism.**

Phase F shipped the first half. `CaptureIntent.swift:7-21` and `docs/15 §1` read as a refusal of
hotkeys, but they are arguing against a hotkey as *the mechanism* — which would either cost the
Accessibility permission, or ship a Carbon registration that "collides silently with whatever else
claimed the combination." Both objections are correct, and neither applies to a hotkey that is a
convenience layered over an intent that already works.

The silent-collision objection is answered directly by the registry.
`RegisterEventHotKey` returns an error when the combination is already claimed, so a collision is
**detectable at registration time**. The failure mode being argued against — a shortcut that
appears bound and does nothing — is precisely what a detected failure plus a Settings status
message prevents.

Shipping a default binding is the one place worth being careful. A default in global input space
is a compatibility claim made on the user's behalf, and `⌘⇧J` is not ours. Proposing it while
treating failure as an expected, reported outcome is the honest version: the user gets the
shortcut when it is free, and gets told when it is not.

## Consequences

1. The registry is the single source of truth for keyboard bindings. Today there are 40
   `.keyboardShortcut` literals, 20 of them in `ElephruitApp.swift`, and the command palette
   carries **cosmetic glyph arrays** (`RootView.swift:222-247`, e.g. `["⌘","⇧","N"]`) with no link
   to the real binding — two representations that can silently drift. The palette reads real
   bindings, and a test asserts no command has two owners.
2. The intent remains the mechanism, so capture still works from a cold start with no
   configuration, and still arrives in Spotlight, Shortcuts and the Services menu for free.
3. `openAppWhenRun` stays `false` for the intent. The hotkey path is different: it presents the
   panel, which is the point of it.
4. **Verify the modifier constraint against the deployment target.** `docs/10 §0` records that
   macOS 15 required a registration to include a modifier other than Shift or Option, and that
   15.2 relaxed it. `⌘⇧J` includes Command, so it satisfies even the stricter rule — but this must
   be checked against 26.0 rather than assumed.
5. **Verification happens in a signed, sandboxed release build.** Debug behaviour under Xcode is
   not representative of hotkey registration, and this is the one requirement here that a unit
   test cannot discharge.

## Amendment — 2026-08-01: which commands get one

Three commands are now offered to the whole system: Quick Jot at `⌘⇧J`, **Quick Log at `⌘⇧L`**, and
New Event at `⌘⇧E`. The mechanism, the failure handling and the Settings reporting are unchanged;
this records the rule for what may join them, because "one more shortcut" is the decision that goes
wrong by accretion rather than by any single step.

A command earns a global binding only when **the moment it is wanted is a moment you are looking at
something else**. Capturing a thought qualifies: the thought arrives during the work, not during the
note-taking. Starting a timer qualifies more strongly than either of the other two — the clock is
wrong from the instant work begins, and the whole reason people abandon time tracking is that the
cost of starting exceeds the value of the number. Putting a meeting in the calendar qualifies
because it is usually said out loud by somebody else while you are mid-conversation.

Almost nothing else does. Navigating to a module, toggling an inspector, or completing a task are all
things you do *with the app in front of you*, and a global binding for one of them would be a claim
staked in the user's input space for no gain — see `ShortcutSettingsSection.globalCommands`, which is
the list, and is deliberately short.

`⌘⇧L` inherits §4 and §5 unchanged: it includes Command, so it satisfies even the stricter
pre-15.2 modifier rule, and it has **not** yet been pressed in a signed sandboxed build.
