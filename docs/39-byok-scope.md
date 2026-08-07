# 39 — Bring-your-own-key custody moves server-side

- **Status:** Landed on `claude/interactions-feature-spike-6b39a8` (2026-08-06)
- **Decision record:** [ADR 0010](adr/0010-server-side-ai-key-custody.md)
- **Going real:** [docs/40-byok-cloud-runbook.md](40-byok-cloud-runbook.md)

Doc 38 §D5 stored the user's Anthropic key in localStorage and called that
posture what it was: acceptable for a personal spike, "a stated non-posture
for anything multi-user." This slice is the graduation. The key now lives
server-side, encrypted, and the browser holds only a credential id.

## Architecture

```text
Browser
  │  Firebase Auth ID token (+ App Check when deployed)
  │  credentialId, provider, model, messages, bounded settings
  ▼
Cloud Functions (2nd gen, streaming callables)
  │  authenticate → validate strictly → model allowlist → rate limits
  │  → resolve the CALLER's credential (uid-keyed path) → concurrency lease
  │  → decrypt (Cloud KMS in production, AES-256-GCM dev cipher in emulator)
  │  → fixed provider adapter → normalized text deltas + normalized outcome
  ├─ Anthropic Messages API
  ├─ OpenAI Responses API (`store: false`)
  └─ Google Gemini Interactions API (`store: false`)
```

Everything is a **callable**: credential lifecycle (`addAiCredential`,
`verifyAiCredential`, `replaceAiCredential`, `deleteAiCredential`) as plain
calls, generation as a **streaming callable** (`streamAiResponse`,
`response.sendChunk`) — chosen over a hand-rolled `onRequest` + SSE endpoint
because the framework then owns auth, App Check enforcement, and CORS, and
because a spike proved the emulator delivers chunks unbuffered (300ms server
spacing arrived as 300ms/301ms gaps). `CallableResponse.signal` aborts the
upstream generation when the browser disconnects.

The browser can never choose transport: no URLs, no headers, no raw provider
bodies. The one opaque field is `outputFormat` — the JSON-schema object the
client already derives from its zod schemas — bounded at 32KB and a
`json_schema` shape, forwarded only into the adapter's typed
`output_config`. Under BYOK it shapes the user's own generation on their own
key, which is why it earns no deeper inspection; it is what lets the two
structured-output features ride a generic gateway without losing their
schema guarantees. Replies are re-validated client-side against the same zod
schema before anything reaches a write plan. Each adapter translates that
provider-neutral format into its provider's structured-output vocabulary.

## Data model

| Path | Access | Contents |
|---|---|---|
| `users/{uid}/aiCredentials/{id}` | owner read, server write | provider, label, `keyHint` (last 4), status `active·invalid·unverified·revoked`, timestamps, `verificationErrorCode` |
| `privateAiCredentials/{uid}/keys/{id}` | no client, ever | `ownerUid`, base64 ciphertext, `kmsKeyName` label, timestamps |
| `users/{uid}/aiCredentialAudit/{eventId}` | owner read, server write | lifecycle events; `credential_used` sampled at 5%; never prompts, outputs, or key material |
| `aiRateLimits/{docId}` | no client | fixed-window counters + per-user stream-lease doc, `expireAt` for TTL |

The private path is **keyed by uid**: the server always addresses the
caller's own subtree, so another user's credential id resolves to a path
that cannot exist for them — ownership is structural, with an `ownerUid`
field-compare as belt-and-braces. Account deletion, when it exists, purges
one subtree (runbook §Operations).

The rules carve `aiCredentials` and `aiCredentialAudit` out of the app's
owner-read-write wildcard — without the carve-out a client could vouch for
its own key. Fifteen rules tests (`npm run test:rules`) pin every attack.

## Encryption

One seam (`EncryptionService`), two ciphers with symmetric suspicion:

- **CloudKmsEncryptionService** — symmetric encrypt/decrypt against one
  crypto key; refuses ciphertext labeled `local-dev`.
- **DevelopmentEncryptionService** — AES-256-GCM from an uncommitted
  `functions/.env.local` key; constructor throws outside the emulator;
  labels everything `local-dev`; refuses real-KMS-labeled ciphertext.

Both bind **AAD `uid|credentialId|provider`** on encrypt and decrypt, so
ciphertext copied between documents, users, or providers fails
authentication instead of decrypting somewhere it should not. Startup
invariants refuse a production runtime with no `KMS_KEY_NAME`, or carrying
`DEV_ENCRYPTION_KEY` or `AI_FAKE_ADAPTER`. KMS decrypt names the key, not a
version — which is why rotated-away key versions must never be destroyed
(runbook).

## Verification is tri-state

`models.list` authenticates a key at zero generation cost. Only a definite
401/403 condemns a key; 429/5xx/network are **inconclusive** — a new key
stores as `unverified` rather than being bounced, an existing key keeps its
status, and replace refuses to overwrite. A provider auth failure
mid-generation flips the credential to `invalid` so Settings shows it needs
attention. Nothing about someone else's credentials is ever distinguishable
from `CREDENTIAL_NOT_FOUND`.

## Limits (server-enforced)

messages ≤ 40 × 50k chars, total ≤ 200k · system ≤ 50k · maxTokens clamped
to 16 384 (default 8 192) · outputFormat ≤ 32KB · api key 20–2 048 chars ·
label ≤ 80 · adds/replacements 5/user/hr · verifications 10/user/hr ·
stream starts 60/user/min · concurrent streams 3/user via lease docs whose
TTL outlives the 300s function timeout, so a crashed instance frees its
slot by clock. The Firestore limiter is honest about races under concurrent
bursts (approximate ceilings, exact enough for abuse control) and sits
behind an interface a Redis implementation can replace.

## Logging

An allowlist, not a redaction list: `requestId, uid, credentialId,
provider, model, operation, durationMs, status, outcome,
normalizedErrorCode` — anything else is dropped before the sink. No request
bodies, prompts, headers, plaintext, or ciphertext, ever. The canary test
runs a full stream keyed by `TEST_SECRET_MUST_NEVER_APPEAR_IN_LOGS_12345`
with every sink recorded and asserts the secret absent from logs, chunks,
and result. The web app still carries **zero** analytics/session-replay/
error-reporting — nothing to mask, and keeping it that way is the control.

## The emulator story

`AI_FAKE_ADAPTER=1` (emulator-only, enforced at startup) swaps every
provider adapter for a deterministic fake: canned schema-valid capture
proposals and day briefs (echoing the briefed people by name), test keys
`…-invalid` / `…-flaky` for the failure paths, every outcome tagged
`adapter:'fake'` so the smoke can prove no real provider was contacted. A
stray real key pasted into the emulator is never sent anywhere.

## Testing

| Layer | Command | Needs emulators |
|---|---|---|
| Web unit + parity tripwires | `npm test` | no |
| Functions unit (typechecked first) | `npm run test:functions` | no |
| Firestore rules | `npm run test:rules` | yes |
| BYOK attack smoke (23 checks) | `npm run smoke:byok` | yes, fake adapter |

Two parity tripwires pin the packages together without runtime imports: the
gateway wire types must stay mutually assignable with the server's, and
every model the picker offers must be enabled in the server catalog — both
fail the build, not the user.

## Security checklist

- [x] Auth required on every credential and gateway function
- [x] App Check enforced in production (`enforceAppCheck: !isEmulator` + startup assertion; unverifiable in the emulator — see runbook for staged rollout)
- [x] Private credential documents deny all client access (owner included)
- [x] Metadata documents deny client writes
- [x] Credential lookups addressed by verified uid + ownerUid compare
- [x] Stored provider must match the requested provider
- [x] Model ids checked against a server allowlist
- [x] Provider URLs and headers fixed server-side
- [x] Raw keys never returned, logged, or client-persisted (wire-audited)
- [x] Ciphertext bound to its record via AAD
- [x] Request sizes, output tokens, streams, and rates capped
- [x] Upstream aborts on client disconnect
- [x] Provider errors normalized; ownership failures indistinguishable from absence
- [x] Development cipher and fake adapter cannot run in production
- [x] Cross-user attacks covered by rules tests and the smoke
- [x] No real key anywhere in source, fixtures, or history (audited)
- [ ] KMS permissions scoped + rotation enabled — deploy-time, runbook §3
- [ ] Firestore TTL policy on `aiRateLimits` — deploy-time, runbook §6
- [ ] Production log inspection for secret leakage — deploy-time, runbook §7

## Deliberate deviations from the reviewed plan

- **Streaming callables** instead of a raw HTTPS + SSE endpoint (the plan
  allowed either): framework-owned auth/App Check/CORS beats hand-rolled
  header parsing, and the emulator spike removed the buffering risk.
- **Model catalog as a bundled constant** with server enforcement and a
  build-time parity test, not a catalog callable — three options do not
  warrant a cold-startable function.
- **Inconclusive adds store as `unverified`** instead of being rejected —
  otherwise provider downtime makes users re-paste working secrets and the
  status value would be dead.
- **Migration by consent**: the legacy localStorage key is never uploaded
  silently; Settings offers Link (then clears it) or Discard.

## Deferred, deliberately

Memorystore/Redis rate limiting · account-deletion trigger
(obligation documented) · incremental streaming UI (the client accumulates;
both features are structured-output) · App Check debug-token flows (no real
project yet).
