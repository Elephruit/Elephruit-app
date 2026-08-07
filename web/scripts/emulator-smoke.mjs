// Headless proof that the emulator loop and the security rules both work:
// one user round-trips a document; a second user is refused it. Run with the
// emulators up: `npm run emulators` in one terminal, `npm run smoke` in another.

import { initializeApp } from 'firebase/app'
import {
  connectAuthEmulator,
  createUserWithEmailAndPassword,
  getAuth,
} from 'firebase/auth'
import {
  connectFirestoreEmulator,
  doc,
  getDoc,
  getFirestore,
  setDoc,
} from 'firebase/firestore'

const app = initializeApp({ apiKey: 'demo-api-key', projectId: 'demo-elephruit' })
const auth = getAuth(app)
const db = getFirestore(app)
connectAuthEmulator(auth, 'http://127.0.0.1:9099', { disableWarnings: true })
connectFirestoreEmulator(db, '127.0.0.1', 8080)

function fail(message) {
  console.error(`SMOKE FAILED: ${message}`)
  process.exit(1)
}

const stamp = Date.now()

// The auth emulator accepts email/password sign-ups without any project config;
// the app itself uses Google sign-in, but rules only care about request.auth.uid.
const alice = await createUserWithEmailAndPassword(auth, `alice-${stamp}@example.com`, 'password-1')
const aliceUID = alice.user.uid

await setDoc(doc(db, 'users', aliceUID, 'people', 'smoke-person'), {
  displayName: 'Ana Torres',
  createdAt: new Date(),
})
const ownRead = await getDoc(doc(db, 'users', aliceUID, 'people', 'smoke-person'))
if (!ownRead.exists() || ownRead.data().displayName !== 'Ana Torres') {
  fail('owner could not read back the document they just wrote')
}

await createUserWithEmailAndPassword(auth, `bob-${stamp}@example.com`, 'password-2')
try {
  await getDoc(doc(db, 'users', aliceUID, 'people', 'smoke-person'))
  fail("a second account read the first account's data — the rules are broken")
} catch (error) {
  if (error?.code !== 'permission-denied') {
    fail(`expected permission-denied, got: ${error?.code ?? error}`)
  }
}

console.log('smoke ok: owner round-trip succeeded, stranger was refused')
process.exit(0)
