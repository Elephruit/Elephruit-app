/// Firebase bootstrap. With no .env, dev runs fully offline against the local
/// emulators under the fictional "demo-elephruit" project; a real project's web
/// config drops in via VITE_FIREBASE_* without touching code.
///
/// Offline persistence stays off: the default in-memory cache forgets on reload,
/// which is exactly right next to emulators whose data resets between runs —
/// IndexedDB would outlive the emulator and serve ghost documents.

import { initializeApp } from 'firebase/app'
import { initializeAppCheck, ReCaptchaEnterpriseProvider } from 'firebase/app-check'
import { connectAuthEmulator, getAuth } from 'firebase/auth'
import { connectFirestoreEmulator, getFirestore } from 'firebase/firestore'
import { connectFunctionsEmulator, getFunctions } from 'firebase/functions'

const env = import.meta.env

export const usingEmulators: boolean = env.DEV && env.VITE_USE_EMULATORS !== 'false'

const app = initializeApp({
  apiKey: env.VITE_FIREBASE_API_KEY || 'demo-api-key',
  authDomain: env.VITE_FIREBASE_AUTH_DOMAIN || 'demo-elephruit.firebaseapp.com',
  projectId: env.VITE_FIREBASE_PROJECT_ID || 'demo-elephruit',
  appId: env.VITE_FIREBASE_APP_ID || 'demo-app-id',
})

// App Check proves requests come from this app. Emulator runs skip it (there
// is no App Check emulator); a production build without a configured site key
// simply doesn't initialize it — the server side enforces regardless. For
// local dev against the real project, a debug token from the App Check
// console goes in .env as VITE_APPCHECK_DEBUG_TOKEN, never in code.
const appCheckSiteKey = env.VITE_APPCHECK_SITE_KEY
if (!usingEmulators && appCheckSiteKey) {
  if (env.VITE_APPCHECK_DEBUG_TOKEN) {
    ;(globalThis as { FIREBASE_APPCHECK_DEBUG_TOKEN?: string }).FIREBASE_APPCHECK_DEBUG_TOKEN =
      env.VITE_APPCHECK_DEBUG_TOKEN
  }
  initializeAppCheck(app, {
    // Enterprise, not classic v3: Google's admin routes org accounts into
    // Enterprise keys, and the provider must match the key's kind or the
    // token mint fails silently and every callable is refused.
    provider: new ReCaptchaEnterpriseProvider(appCheckSiteKey),
    isTokenAutoRefreshEnabled: true,
  })
}

export const auth = getAuth(app)
export const db = getFirestore(app)
export const functions = getFunctions(app, 'us-central1')

if (usingEmulators) {
  connectAuthEmulator(auth, 'http://127.0.0.1:9099', { disableWarnings: true })
  connectFirestoreEmulator(db, '127.0.0.1', 8080)
  connectFunctionsEmulator(functions, '127.0.0.1', 5001)
}
