# Communication tracking — record

What was built, what it claims, what it refuses to claim, and the three defects found while building
it.

Decisions are in `docs/25-communication-tracking-scope.md`.

---

## 1. Which channel uses what

| Channel | Mechanism | Reports back? | Strongest state reachable |
|---|---|---|---|
| Email | `NSSharingService.composeEmail`, falling back to `mailto:` | Yes — `didShareItems` / `didFailToShareItems` | `providerVerifiedSent`, if a provider is ever configured; `userConfirmedSent` otherwise |
| Message | `NSSharingService.composeMessage`, falling back to `sms:` | Yes, same two callbacks | `userConfirmedSent` |
| Call | `tel:` | **No** | `userConfirmedSent`, plus a manual `CallOutcome` |
| FaceTime video | `facetime:` | **No** | `userConfirmedSent`, plus a manual `CallOutcome` |
| FaceTime audio | `facetime-audio:` | **No** | `userConfirmedSent`, plus a manual `CallOutcome` |

The fallback is not hypothetical: `SystemCommunicationLauncher` uses the URL scheme whenever the
sharing service reports itself unavailable or declines the items, and the record's mechanism is
corrected from what the launcher *did* rather than what was asked for — because the mechanism decides
whether a callback is coming, which decides whether the user is asked.

## 2. What each callback is taken to mean

| Signal | Recorded as | Evidence | What it does **not** establish |
|---|---|---|---|
| `launch` returned | `composerOpened` | `systemCallback` | That anything was typed or sent |
| `sharingService(_:didShareItems:)` | `shareCompleted` | `systemCallback` | That a server accepted it, that the recipients or body are the ones supplied, that anybody received it |
| `didFailToShareItems` with `NSUserCancelledError` | `canceled` | `systemCallback` | — |
| `didFailToShareItems`, anything else | `failed` | `systemCallback` | — |
| `NSWorkspace.open` returned `false` | `failed` | `systemCallback` | — |
| URL opened | `composerOpened` | `systemCallback` | Anything at all after that instant |
| User answers "Sent" | `userConfirmedSent` | `userConfirmation` | Delivery |
| Provider returns a sent record | `providerVerifiedSent` | `providerAPI` | Delivery |

`willShareItems` is implemented and records nothing: the composer-opened state was already written
when `launch` returned, and a second identical state would put two rows in the event log describing
one thing.

## 3. User-confirmed versus provider-verified

**User-confirmed** — `userConfirmedSent`, and every `CallOutcome`. This is the ceiling for Messages,
calls, and FaceTime, and for email on any machine without a provider configured. The timeline says
*confirmed by you* or *confirmed manually*, never anything that implies observation.

**Provider-verified** — `providerVerifiedSent`, email only, and unreachable in every shipping build.
The timeline would say *verified by Gmail*.

**Delivered** — unreachable everywhere. `CommunicationChannel.canReportDelivery` is `false` for every
channel, a test asserts it for all five, and a source scan asserts that nothing assigns the state.

## 4. MailKit

**Not implemented.** What exists is the seam a compose-session handler would use: a correlation
header name, a token generated per intent, validation of a token arriving from outside, and a
reconciler rule that treats a valid token as an exact identity.

The token is a bare UUID naming an intent and nothing else — no person, no address, no subject —
because a header that leaked who a message was about would be visible to every server the mail passed
through. Without an extension the header is never written, the reconciler falls through to its other
rules, and nothing about ordinary use depends on it.

## 5. Provider integrations

**None.** `NoProviderMessageService` is what every build runs. Elephruit has no network entitlement,
so adding a real one means adding the entitlement in the same commit under standing rule R3 — which
is a decision about the app's no-network posture, not an implementation detail of this module.

## 6. Privacy defaults

Default is `metadataOnly`: channel, recipients, subject, timestamp, source context, status, and the
evidence behind each status. No body, no digest.

`fingerprintForMatching` adds a SHA-256 digest of the normalised subject and body, used only to tell
two similar messages apart when reconciling. `retainContent` adds the drafted body.

The setting is recorded on each record as it stood when the record was written. An unreadable stored
value reads as `metadataOnly` — the strictest — so an unknown setting is never permission to keep
more. The same rule applies to states: an unreadable `stateRaw` reads as `unknown`, never upward into
a claim that the message was sent.

## 7. Duplicate reconciliation

One message produces up to five signals: the intent, a share callback, a user confirmation, a
provider record, an imported sent-message record. They update **one** `CommunicationIntentRecord`
and, at most, **one** interaction `Item`.

Matching, in order, stopping at the first that resolves:

1. **Intent identifier** — the app started it and said so. An identifier that resolves to nothing is
   `noMatch`, not a cue to fall through: a caller that supplied one believed it knew, and replacing a
   stated identity with a guess is the worst available outcome.
2. **Correlation header**, validated as a UUID before it is trusted.
3. **Provider message identifier** already recorded against a record.
4. **Recipient, subject, and time together**, with fingerprints as corroboration where both sides
   hold one. Every condition or nothing.

Two records satisfying rule 4 equally produce `ambiguous` and **nothing is updated**. The failure
being guarded against is not a missing row — it is writing one message's verification onto another
message's record, which is invisible in a way a duplicate is not.

The single interaction is held by identifier on the record, so promotion is idempotent by
construction rather than by discipline at the call sites.

## 8. Known platform limitations

- **No delivery evidence exists.** Not for iMessage, not for SMS, not from Gmail or Microsoft Graph,
  which report submission. `delivered` is a modelled absence.
- **A URL scheme has no completion callback.** `NSWorkspace.open` returns whether a handler was
  found. Everything after that is unobservable, which is the entire reason the confirmation prompt
  exists.
- **A sharing service reports on itself, not on the message.** The delegate receives the items the
  app supplied. Edits the user made in the composer are not returned by any public API, so the stored
  recipients and subject are labelled *intended* wherever they are shown.
- **Nothing is knowable about a call.** Not that it connected, not its duration, not that it was
  answered. Every call fact is the user's testimony.
- **The reconciliation window is a heuristic.** Thirty minutes, and two messages to the same person
  with the same subject inside it are unresolvable — deliberately, by refusing rather than guessing.
- **A digest is not zero-knowledge.** A short body can be checked against a guess by anybody holding
  the digest. This is why it is opt-in and why the setting says so.

## 9. Three defects found while building this

**A person's row described itself three ways.** `ElephruitFeatures` had not compiled since the
contact-readability merge: `tooltip` still read a `subtitle` the row no longer had. The row, the
tooltip, and the accessibility label were three independent descriptions and the change updated two.
They now share one definition.

**The launch mechanism was corrected in the wrong layer.** `prepare` writes the mechanism it expects;
what happened is known only once the launcher returns. That correction lived in the coordinator, so a
record written through any other call site silently claimed a callback that was never coming — and,
because the mechanism decides whether the user is asked, such a record could never get past *status
unknown*. It moved into the service that owns the record.

**A voicemail counted as a conversation.** A reported call reaches `userConfirmedSent` whether or not
anybody picked up, and that was all that was stored — so the timeline said "Call sent · confirmed by
you" and `isContact` returned true for a call nobody answered. The state and the outcome are two
facts and are now two columns.

The test that should have caught the third was written with an `||` over the thing under test, and
both halves were true of the broken behaviour. Replacing the disjunction with two exact sentences is
what surfaced it.

## 10. Checks that pass

| Check | Result |
|---|---|
| `swift build`, all eight modules | Succeeds, zero warnings |
| `xcodebuild` Debug | Succeeds, zero warnings |
| `swift test` | 1,027 tests, all passing |
| No channel claims delivery evidence | `CommunicationStateTests` |
| No source path assigns `delivered` | `CommunicationSafetyTests` |
| No private Messages framework, database, or screen scraping | `CommunicationSafetyTests`, fourteen symbols |
| No mail scripting | `CommunicationSafetyTests`, five symbols |
| Transition table is total over 2,500 combinations | `CommunicationTransitionTests` |
| No label reads "delivered" for any non-delivered state | `CommunicationStatusLabelTests` |
| Five signals produce one interaction | `CommunicationReconciliationServiceTests` |
| Ambiguity updates nothing | Core and persistence suites |
| Bodies reach the composer and not the store | `CommunicationCoordinatorTests` |
| Every launch path is exercised without opening anything | `InertCommunicationLauncher` |

## 11. Not done

**Not reviewed on screen.** The confirmation bar, the call-outcome sheet, the timeline status line,
and the privacy section have not been looked at in a running app, in either appearance. What is
enforced instead is the same thing that is enforced everywhere else: no view names a literal colour,
so every colour resolves through AppKit's semantic palette. That is the part that stays true; it is
not a substitute for looking.

**No follow-up workflow.** After a confirmed send the user can do everything the interaction already
allows — it is an ordinary `Item` — but there is no prompt offering to add a note, record a promise,
or schedule the next contact. Nothing is created automatically, which is the half that matters for
truthfulness; the affordance is a later slice.

**No sent-mail import.** `ProviderSentQuery` and the reconciler handle it and are tested against a
fake; there is no provider to query.
