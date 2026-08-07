# 40 — BYOK cloud runbook: taking key custody to a real project

Everything in [docs/39](39-byok-scope.md) runs on the emulators today. This
is the ordered list of console and CLI work for a real deployment. Nothing
here has been executed; the fictional `demo-elephruit` project has no cloud
footprint. Commands assume the Firebase CLI is signed in and `gcloud` is
installed. Run everything from `web/`.

## 1. Project bootstrap

1. Create the Firebase project; upgrade to **Blaze** (Cloud Functions and
   KMS require it). Enable Firestore and Google sign-in.
2. Create the web app in the console; put its config in `web/.env` as the
   `VITE_FIREBASE_*` values (`.env.example` is the template) with
   `VITE_USE_EMULATORS=false`.
3. Enable the APIs:

   ```bash
   gcloud services enable cloudfunctions.googleapis.com cloudkms.googleapis.com \
     run.googleapis.com eventarc.googleapis.com --project <project-id>
   ```

## 2. Firebase CLI targeting

```bash
npx firebase login
npx firebase use <project-id>
```

## 3. Cloud KMS

Region should match the functions region (`us-central1` unless
`functions/src/index.ts` changes).

```bash
gcloud kms keyrings create ai-credentials \
  --location us-central1 --project <project-id>

gcloud kms keys create provider-api-keys \
  --location us-central1 --keyring ai-credentials \
  --purpose encryption \
  --rotation-period 90d \
  --next-rotation-time $(date -v+90d +%Y-%m-%dT%H:%M:%SZ) \
  --project <project-id>
```

IAM — grant the **functions runtime service account** (2nd gen defaults to
the compute SA, `<project-number>-compute@developer.gserviceaccount.com`,
unless a dedicated SA is configured — prefer creating one) encrypt/decrypt
**on the key only**, nothing project-wide:

```bash
gcloud kms keys add-iam-policy-binding provider-api-keys \
  --location us-central1 --keyring ai-credentials \
  --member serviceAccount:<runtime-sa> \
  --role roles/cloudkms.cryptoKeyEncrypterDecrypter \
  --project <project-id>
```

Nobody else gets decrypt: not the frontend, not developers by default, not
CI. The key name is configuration, not a secret — put it in
`web/functions/.env.<project-id>` (committed is acceptable, uncommitted is
fine too, but **never** in `.env.local`):

```text
KMS_KEY_NAME=projects/<project-id>/locations/us-central1/keyRings/ai-credentials/cryptoKeys/provider-api-keys
```

**Rotation semantics:** rotation only affects new encryptions. KMS decrypt
resolves the version from the ciphertext, so **never destroy old key
versions** while any `privateAiCredentials` record exists that was
encrypted under them. If a version must die, re-encrypt first (decrypt +
encrypt each record — a small admin script; none exists yet).

The startup invariants refuse a production runtime without `KMS_KEY_NAME`,
or with `DEV_ENCRYPTION_KEY` / `AI_FAKE_ADAPTER` present — a deploy
misconfigured as a dev machine fails at cold start, not at first request.

## 4. App Check

1. Register the web app for App Check with **reCAPTCHA Enterprise** — not
   classic v3. Google's admin flow creates Enterprise keys for org accounts,
   and the key's kind must match everywhere or the token mint fails
   silently and every callable is refused with a bare `Unauthenticated`.
   Three pieces have to agree, all learned the hard way on first deploy:
   - The Enterprise key's **allowed domains** must list the exact hosts
     (`<project>.web.app`, `<project>.firebaseapp.com` — watch for typos;
     `.web.com` cost an hour).
   - The App Check registration carries the **site key** (Enterprise keys
     have no classic secret). Registering via API instead of console:
     `PATCH …/apps/<appId>/recaptchaEnterpriseConfig?updateMask=siteKey`.
   - The App Check **service agent**
     (`service-<project-number>@gcp-sa-firebaseappcheck.iam.gserviceaccount.com`)
     needs `roles/recaptchaenterprise.agent` on the project — the console
     registration grants it; the API path does not.
   The client init in `web/src/data/firebase.ts` uses
   `ReCaptchaEnterpriseProvider` with `VITE_APPCHECK_SITE_KEY`.
2. **Stage the rollout:** deploy with enforcement ON for the callables (the
   code always enforces outside the emulator) only after monitoring the
   App Check metrics page shows legitimate traffic passing. If unverified
   traffic must be tolerated during rollout, temporarily flip
   `enforceAppCheck` to a monitored soft mode in code — do not ship that
   state longer than the rollout takes.
3. Local development against a real project uses an App Check **debug
   token** registered in the console; it lives in the developer's browser,
   never in the repo.

## 5. Deploy order

```bash
npm run build                                  # web typecheck + bundle
npx firebase deploy --only firestore           # rules + composite index FIRST
npx firebase deploy --only functions           # predeploy builds functions
npx firebase deploy --only hosting
```

Rules must precede functions: the carve-out is what keeps clients out of
the credential collections. The SPA rewrite in `firebase.json` is
irrelevant to the gateway — callables talk to the functions origin
directly, never through Hosting (whose proxy would buffer streams).

## 6. Firestore TTL

One policy, so rate-limit counters and stream leases reap themselves:

```bash
gcloud firestore fields ttls update expireAt \
  --collection-group aiRateLimits --enable-ttl --project <project-id>
```

The emulator ignores TTL, which is harmless — emulator data is disposable.

## 7. Production smoke (with a burner key)

1. Create a fresh Anthropic API key you are willing to revoke.
2. Settings → link it → expect `active` and the last-four hint.
3. Run a capture parse and a day brief; confirm streaming (tokens arrive
   incrementally, not at once).
4. Browser dev tools: the key appears in exactly one request
   (`addAiCredential`); generation requests carry `credentialId` and no
   `sk-ant` anywhere; localStorage/sessionStorage/IndexedDB/cookies hold no
   key material.
5. Second account: attempt to use the first account's credential id —
   expect `CREDENTIAL_NOT_FOUND`; direct Firestore reads of metadata and
   `privateAiCredentials` — expect permission denied.
6. Cloud Logging: search for the burner key and for `sk-ant` across the
   function logs — zero hits expected. Then revoke the burner key at
   Anthropic and confirm the credential flips to invalid on next use.

## 8. Operations

- **User key compromise:** the user deletes the credential (removes our
  ciphertext) and revokes at Anthropic — Settings copy already says
  deletion here does not revoke there.
- **Account deletion (obligation, not yet built):** deleting a user must
  purge `privateAiCredentials/{uid}` recursively plus
  `users/{uid}/aiCredentials` and `…/aiCredentialAudit`. No auth-delete
  trigger exists in this codebase yet; until one does, this is a manual
  step in whatever account-deletion procedure emerges.
- **KMS outage:** generation fails closed with `INTERNAL`/`PROVIDER_*`
  codes; keys never fall back to any other cipher.
- **Monitoring worth having:** decrypt-call volume vs. request volume
  (divergence signals abuse), provider auth-failure rate, App Check
  rejection rate, function instance counts, rate-limit hits.

## 9. Cost posture

Users pay Anthropic for tokens; **the project owner pays** for function
invocations and instance-time during streams, Firestore writes (metadata,
counters, sampled audit), and KMS operations (~$0.03 per 10k). The guards
are `maxInstances` (10 gateway / 5 credential), the per-user rate limits,
and the 3-stream concurrency cap. Watch the billing page during week one.

## 10. Rollback

`firebase deploy --only functions` redeploys the previous build from its
commit; rules revert the same way (`git checkout <sha> -- firestore.rules`
+ deploy). Ciphertext is forward-compatible: nothing in a rollback changes
`kmsKeyName` labels or AAD, so stored credentials keep decrypting. The one
irreversible act in this whole system is destroying a KMS key version — see
§3, and don't.
