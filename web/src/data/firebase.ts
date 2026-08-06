/// Firebase bootstrap. With no .env, dev runs fully offline against the local
/// emulators under the fictional "demo-elephruit" project; a real project's web
/// config drops in via VITE_FIREBASE_* without touching code.
///
/// Offline persistence stays off: the default in-memory cache forgets on reload,
/// which is exactly right next to emulators whose data resets between runs —
/// IndexedDB would outlive the emulator and serve ghost documents.

import { initializeApp } from 'firebase/app'
import { connectAuthEmulator, getAuth } from 'firebase/auth'
import { connectFirestoreEmulator, getFirestore } from 'firebase/firestore'

const env = import.meta.env

export const usingEmulators: boolean = env.DEV && env.VITE_USE_EMULATORS !== 'false'

const app = initializeApp({
  apiKey: env.VITE_FIREBASE_API_KEY || 'demo-api-key',
  authDomain: env.VITE_FIREBASE_AUTH_DOMAIN || 'demo-elephruit.firebaseapp.com',
  projectId: env.VITE_FIREBASE_PROJECT_ID || 'demo-elephruit',
  appId: env.VITE_FIREBASE_APP_ID || 'demo-app-id',
})

export const auth = getAuth(app)
export const db = getFirestore(app)

if (usingEmulators) {
  connectAuthEmulator(auth, 'http://127.0.0.1:9099', { disableWarnings: true })
  connectFirestoreEmulator(db, '127.0.0.1', 8080)
}
