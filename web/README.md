# Elephruit web spike

The focused core loop — log interactions with people, note relationships, keep
facts, track follow-ups — as a phone-first web app. What it is and why it is
shaped this way: [docs/38-interactions-web-spike-scope.md](../docs/38-interactions-web-spike-scope.md).

## Run it

Requires Node 20+ and a JVM (the Firestore emulator needs one).

```bash
npm install
npm run emulators     # terminal 1 — Auth + Firestore + emulator UI, fully offline
npm run dev           # terminal 2 — Vite dev server on http://localhost:5173
```

Sign in with **Use the local dev account** — it skips the Google popup and goes
straight through the auth emulator. Emulator state survives restarts
(`npm run emulators:resume` re-imports the last export). The emulator UI at
<http://localhost:4000> shows every document.

```bash
npm test              # the domain rules, resolution, and request-shape tests
npm run smoke         # headless rules check against running emulators
npm run build         # typecheck + production bundle
```

## Link an AI key

Settings → **AI capture**: paste your own Anthropic API key and dictated
updates in the capture box ("What happened?" on the Feed) are parsed into
interactions, facts, relationships, and follow-ups — always shown for review
before anything is written. The key stays in this browser's localStorage,
is sent only to `api.anthropic.com`, and one tap forgets it. Without a key
the capture box still works: **Log manually** carries your text into the
composer.

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

For phone browsers on a real deployment, prefer `signInWithRedirect` over the
popup — popup blockers eat `signInWithPopup`.
