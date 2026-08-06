# ADR 0010 — AI keys are server custody, not browser custody

- **Status:** Accepted
- **Date:** 2026-08-06

## Decision

The user's provider API key is held **server-side, encrypted, write-only
from the browser's point of view**. The browser submits a key exactly once
(add or replace), receives a credential id, and from then on every AI
request carries the id; Cloud Functions decrypt the key per request —
Cloud KMS in production, an emulator-fenced AES-256-GCM cipher in
development, both binding `uid|credentialId|provider` as authenticated data
— call the fixed provider adapter, and stream normalized events back.
Firestore rules make credential metadata owner-read/server-write and deny
the encrypted material to every client, the owner included.

The localStorage key from the doc 38 era migrates only by consent: Settings
offers **Link this key** (upload once, encrypt, clear the local copy) or
**Discard it**. Nothing is uploaded silently.

We do not claim zero-knowledge, end-to-end encryption, or "we can never see
your key" — the backend decrypts it per request, and the product copy says
exactly that.

## Rationale

Doc 38 §D5 was honest about the spike posture: localStorage is readable by
any script on the origin, acceptable for a personal spike and "a stated
non-posture for anything multi-user." Multi-user is where this app is
pointed, and the browser is the wrong custodian for a long-lived billing
credential: any future XSS, malicious dependency, or shared machine reads
it wholesale, and a browser-held key also forces browser-direct provider
calls (`dangerouslyAllowBrowser`), which no server can rate-limit,
allowlist, or audit.

Server custody buys enforcement, not just storage: the model allowlist,
size and token clamps, per-user rate limits, concurrency leases, and the
allowlist logger all live where the client cannot decline them. The
uid-keyed private path makes cross-user credential access structurally
unreachable rather than merely checked. AAD binding makes stolen or
copy-pasted ciphertext worthless outside its own record.

The alternative custodies lose on their own terms. Keeping localStorage
(status quo) fails multi-user, period. Firestore-synced plaintext or
client-side-encrypted keys still transit and rest where every device and
rule mistake can reach them, and client-side encryption would be theater —
the server must see plaintext to call the provider anyway. Per-user
Function secrets misuse a deployment mechanism as a database.

## Consequences

1. The repo grows its first backend (`web/functions/`), and the emulator
   suite grows a functions emulator; dev setup gains one step
   (`functions/.env.local` with a `DEV_ENCRYPTION_KEY`).
2. Going multi-user-for-real acquires a cloud dependency list — Blaze, KMS
   key + scoped IAM, App Check, a TTL policy — all runbook'd in docs/40,
   none executed yet.
3. AI features stop working offline-without-emulators; the fake adapter
   (`AI_FAKE_ADAPTER=1`, emulator-only) restores a fully offline loop for
   development and tests.
4. The user pays Anthropic; the project owner starts paying for function
   time, Firestore writes, and KMS calls — bounded by maxInstances, rate
   limits, and the concurrency cap (docs/40 §9).
5. Account deletion inherits an obligation: purge
   `privateAiCredentials/{uid}` when the account goes (documented, not yet
   built).
6. Old KMS key versions become load-bearing: rotation is routine, version
   destruction is the one irreversible operation in the system.
