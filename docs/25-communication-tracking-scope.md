# Communication tracking — scope

The six decisions behind recording that the user reached out to somebody, without ever claiming
more than the platform actually reports.

Companion to `docs/26-communication-tracking-record.md`, which says what was built and what was
found while building it.

---

## The problem

Pressing **Email** on somebody's page wrote an interaction into their timeline — `Email started` —
on the evidence that macOS had opened a compose window. The provenance was honest and the row's
existence was not: a message the user then abandoned left a permanent entry saying they had been in
touch, distinguishable from a real one only by a word in the subtitle. The same held for Message,
Call, and both FaceTime actions, from the person page, the command bar, and the batch-email bar
alike.

The app cannot see whether a message was written, whether the recipients were changed, whether Send
was pressed, whether a server accepted it, or whether anybody received it. Those are five different
facts. Collapsing them into "Sent" produces a timeline that reads as evidence and is not.

---

## D1 — An intent exists before anything is launched, and it is not a claim

A `CommunicationIntent` records what the user *set out to do*: channel, linked people, intended
recipients, intended subject, source context, launch mechanism, and what is currently known about
the outcome. It is not an assertion that anything happened, so writing one costs nothing in
truthfulness.

An interaction — the thing that appears on a person's page and moves their last-contact line —
is written only when something says the message went. The condition is one expression,
`CommunicationState.countsAsReachingOut`, and it admits three states: the user said so, a provider
verified it, or a provider reported delivery.

**Rejected:** writing the interaction immediately and correcting it later. Correcting a row nobody
looked at is fine; correcting one somebody read last week is not, and the failure is silent in the
meantime.

## D2 — Ten states, ordered, and certainty only ever increases

The states are `draftPrepared`, `composerOpened`, `shareCompleted`, `submitted`,
`userConfirmedSent`, `providerVerifiedSent`, `delivered`, `failed`, `canceled`, `unknown`.

Four independent sources can report on one message — a framework callback, the user, a provider API,
an imported sent-mail record — and they arrive in no guaranteed order. `CommunicationTransitionPolicy`
lets a claim be *raised* by anything and *lowered* only by a source with more authority than the one
that made it. That single rule is what lets a provider upgrade a record the user already confirmed
without also letting a late share callback rewrite "Email sent" back to "handed off".

`delivered` is modelled and unreachable. Nothing in the deployment SDK reports that a message
arrived, so the state exists to make the absence of delivery evidence a named absence rather than an
unnamed gap, and a source scan asserts that no code path assigns it.

## D3 — Prefer the native composer, and read its callback narrowly

`NSSharingService` is used for email and Messages, because it addresses a *named* service, carries
attachments as items, survives characters a URL cannot, and — the part that matters — calls back.

`sharingService(_:didShareItems:)` means the sharing service finished. The delegate receives the
items *this app supplied*, not the message the user sent, so it proves nothing about the server, the
recipients, the final body, or the recipient. It is recorded as `shareCompleted` and shown as
**handed off**.

Calls and FaceTime have no sharing service and never will. They are URL schemes, they can only ever
be recorded as *initiated*, and the only way to learn more is to ask.

## D4 — Ask once, and stop when told

A URL-scheme handoff has no completion callback of any kind, so the outcome is unknowable unless the
user says. The app asks when it comes back to the front, and the bounds live on the record rather
than in memory so they survive a relaunch: a dismissal is permanent, a deferral buys exactly one more
ask, nothing is asked twice within five minutes, and a launch that *did* report back is never
questioned at all.

Five answers: Sent, Not sent, Still working on it, Edit interaction, Dismiss. Two of them —
deferring and dismissing — change no state, because neither is a statement about whether the message
went.

## D5 — Metadata by default; content is a separate, explained decision

The default keeps channel, recipient, subject, timestamp, source context, and status. That answers
the question the module exists for. A message body answers no additional question the user asked for
and is the most sensitive thing the app could hold.

Three levels, and the setting says what it means before it takes effect. The middle one keeps a
one-way digest for reconciliation without the text — offered separately because a digest of a short
message can be checked against a guess, which the interface says.

The setting is stored **on each record** as it was when the record was written, so turning retention
off later does not make an already-stored body look unauthorised, and turning it on does not
retroactively imply a body exists for records that have none.

**Never stored, under any setting:** passwords, OAuth tokens outside the Keychain, authentication
headers, unrelated messages, private message databases, or content from conversations the user did
not explicitly connect.

## D6 — The provider seam is designed, and nothing implements it

`ProviderMessageService` exists so that `providerVerifiedSent` is an implementable state rather than
a decorative one: the reconciler, the transition policy, the timeline labels, and the
duplicate-prevention rules are all written against it and all tested against a fake conforming to it.

**No implementation ships, and none can.** Elephruit has no network entitlement, so a Gmail or
Microsoft Graph conformance requires adding one in the same commit under standing rule R3. Until
then `NoProviderMessageService` is what every build runs, and it is a real code path rather than a
`nil` branch.

The rules any implementation must keep are on the protocol: OAuth only, tokens in the Keychain,
bounded sent-mail queries that read nothing else, and a send that cannot be performed without a
preview. The last is enforced by the type system — `ConfirmedSendRequest` requires a
`SendConfirmation`, whose initialiser is private and whose only factory is called by the send sheet.

---

## What is deliberately not here

**A MailKit extension.** A compose-session handler would be the only thing able to correlate a
specific outgoing mail with a specific intent, and the seam it would use — the correlation header
and its token — is built and tested. The extension itself needs its own target, its own entitlements,
and a provisioning story, and it must never be required for ordinary use. It is a candidate for a
later slice, not part of this one.

**Mail scripting.** AppleScript and ScriptingBridge are permitted as an optional power-user feature
behind an explicit Automation permission, and are not permitted as the architecture. Nothing here
uses them, and `CommunicationSafetyTests` fails if that changes.

**Anything that reads Messages.** There is no supported general-purpose API for a normal macOS app
to read sent iMessage content or message history. Every unsupported route is a private framework, a
protected database, or screen scraping, and an app that took one would be trading the user's entire
conversation history for a status label.

**A lenient phone-number match.** `+15125550192` and `5125550192` do not reconcile, because making
them do so means deciding a leading `1` is a dialling code — true in North America, false elsewhere.
Email is the only channel with a provider that reports sends and email addresses normalise cleanly,
so the strictness costs nothing real.
