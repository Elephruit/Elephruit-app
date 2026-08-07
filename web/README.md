# Elephruit web spike

The focused core loop — log interactions with people, note relationships, keep
facts, track follow-ups — as a web-native workspace: a navigation rail, task-
width pages, and context panels on desktop, collapsing to a bottom-tab single
column on phones, in Elephruit's own ivory/ink/azure system with light and dark
appearances (Settings → Appearance). What it is and why it is shaped this way:
[docs/38-interactions-web-spike-scope.md](../docs/38-interactions-web-spike-scope.md).

## Run it

Requires Node 22+ (the functions runtime targets nodejs22) and a JVM (the
Firestore emulator needs one). One-time setup for the AI backend:

```bash
npm install
npm --prefix functions install
cp functions/.env.example functions/.env.local   # then set DEV_ENCRYPTION_KEY
openssl rand -hex 32                             # a good value for it
```

```bash
npm run emulators     # terminal 1 — Auth + Firestore + Functions + emulator UI, fully offline
npm run dev           # terminal 2 — Vite dev server on http://localhost:5173
```

Sign in with **Use the local dev account** — it skips the Google popup and goes
straight through the auth emulator. Emulator state survives restarts
(`npm run emulators:resume` re-imports the last export). The emulator UI at
<http://localhost:4000> shows every document.

```bash
npm test              # the domain rules, resolution, and request-shape tests
npm run test:functions  # the backend: crypto, credential lifecycle, gateway, redaction canary
npm run test:rules    # Firestore rules attacks, against running emulators
npm run smoke         # headless rules check against running emulators
npm run smoke:byok    # attacks the AI gateway like a stranger, against running emulators
npm run seed          # fill fresh emulators with a believable month of demo data
npm run build         # typecheck + production bundle
```

`npm run seed` writes through the real domain planners (ten people, nineteen
interactions, follow-ups in every bucket, corrected and restricted facts), so
every surface has something true to show. It refuses to run on top of existing
data; start the emulators fresh first.

## Link an AI key

Settings → **AI**: choose Anthropic, OpenAI, or Google Gemini, then paste your
own API key and the AI street runs in both directions. Writing: dictated updates in the capture box are parsed into
interactions, facts, relationships, and follow-ups — the review beside the
text shows exactly what will be saved before anything is written. Reading:
**Prepare my day** on the Feed (also ⌘K) briefs you on the people attached to
overdue and today follow-ups, and every person page can produce its own
talking points. Payloads carry current facts (never restricted ones),
relationships, open follow-ups, and recent interactions.

The server allowlist currently offers Claude Opus/Sonnet/Haiku, OpenAI
GPT-5.6 Luna and GPT-5 Nano, and Gemini 3.6 Flash and 3.5 Flash-Lite. Adding
another model requires matching entries in the server catalog and browser
picker; a parity test prevents either side from drifting.

Custody, stated plainly: the key is sent once when you link it, encrypted
server-side (Cloud KMS in production, a local dev cipher under the
emulators), and decrypted only to send requests you start to the selected
provider. It never returns to the browser and cannot be viewed
again — Settings shows the last four characters and the server's verdict on
it. Remove deletes our encrypted copy; revoking the key itself happens in
the provider's console. Under the emulators, `AI_FAKE_ADAPTER=1` (the
`.env.local` default) serves canned responses for every provider so the whole loop runs
offline — test keys behave per their `-invalid` or `-flaky` suffix, and nothing
is ever sent to the real API. Without a credential the capture box still
works: **Log manually** carries your text into the composer. Architecture
and threat model: [docs/39](../docs/39-byok-scope.md).

## Going real

1. Create a Firebase project (Firestore + Google sign-in enabled) and a web
   app in its console.
2. `cp .env.example .env` and fill in the `VITE_FIREBASE_*` values; set
   `VITE_USE_EMULATORS=false` to point dev at the real project.
3. Deploy rules and the composite index **before** relying on person pages —
   the emulator never enforces indexes, production does:

   ```bash
   npx firebase login
   npx firebase use <your-project-id>
   npx firebase deploy --only firestore
   ```

4. `npm run build && npx firebase deploy --only hosting`.

The AI backend needs more than hosting: Blaze, a KMS key with scoped IAM,
App Check, functions deploy, and a Firestore TTL policy — the ordered list
lives in [docs/40-byok-cloud-runbook.md](../docs/40-byok-cloud-runbook.md).

For phone browsers on a real deployment, prefer `signInWithRedirect` over the
popup — popup blockers eat `signInWithPopup`.
