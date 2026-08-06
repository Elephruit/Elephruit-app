// Attacks the BYOK surface the way a stranger would, against the live
// emulators with the fake adapter on (functions/.env.local AI_FAKE_ADAPTER=1):
// steal another user's credential id, forge metadata, read key material, ask
// for models off the list, oversend. Every attack must die with the right
// public code, and the happy path must stream schema-valid JSON tagged
// adapter:'fake' — proof no real provider was contacted.
//
// Run with the suite up: `npm run emulators` in one terminal, then
// `npm run smoke:byok`.

import { initializeApp } from 'firebase/app'
import { connectAuthEmulator, createUserWithEmailAndPassword, getAuth, signInWithEmailAndPassword } from 'firebase/auth'
import { connectFirestoreEmulator, collection, doc, getDoc, getDocs, getFirestore, setDoc } from 'firebase/firestore'
import { connectFunctionsEmulator, getFunctions, httpsCallable } from 'firebase/functions'

const app = initializeApp({ apiKey: 'demo-api-key', projectId: 'demo-elephruit' })
const auth = getAuth(app)
const db = getFirestore(app)
const functions = getFunctions(app, 'us-central1')
connectAuthEmulator(auth, 'http://127.0.0.1:9099', { disableWarnings: true })
connectFirestoreEmulator(db, '127.0.0.1', 8080)
connectFunctionsEmulator(functions, '127.0.0.1', 5001)

const VALID_KEY = 'sk-ant-test-valid-smoke-0000000000007XqP'

let failures = 0
function check(condition, label) {
  if (condition) {
    console.log(`  ok — ${label}`)
  } else {
    failures += 1
    console.error(`  FAIL — ${label}`)
  }
}

function publicCode(error) {
  return error?.details?.code ?? error?.code ?? String(error)
}

async function expectCode(promise, code, label) {
  try {
    await promise
    check(false, `${label} (expected ${code}, got success)`)
  } catch (error) {
    check(publicCode(error) === code, `${label} (${publicCode(error)})`)
  }
}

async function callableError(name, payload) {
  return httpsCallable(functions, name)(payload)
}

async function runStream(request) {
  const callable = httpsCallable(functions, 'streamAiResponse')
  const { stream, data } = await callable.stream(request)
  // On failure both the iterable and the data promise reject; surfacing the
  // iterable's error must not leave the data rejection unhandled.
  data.catch(() => {})
  let text = ''
  let chunks = 0
  for await (const chunk of stream) {
    if (chunk?.type === 'text_delta') {
      text += chunk.text
      chunks += 1
    }
  }
  return { text, chunks, final: await data }
}

const stamp = Date.now()

// ————— User A: the legitimate owner —————
const alice = await createUserWithEmailAndPassword(auth, `alice-${stamp}@example.com`, 'password-1')
const aliceUID = alice.user.uid

console.log('adding a credential as its owner')
const added = await httpsCallable(functions, 'addAiCredential')({ provider: 'anthropic', apiKey: VALID_KEY })
const summary = added.data
check(summary.status === 'active', `credential verified and active (${summary.status})`)
check(summary.keyHint === '7XqP', `hint is the last four (${summary.keyHint})`)
check(!JSON.stringify(summary).includes(VALID_KEY), 'raw key never echoed in the response')
const credentialId = summary.id

const metadataSnapshot = await getDoc(doc(db, 'users', aliceUID, 'aiCredentials', credentialId))
check(metadataSnapshot.exists(), 'owner can read their metadata')
const metadataJSON = JSON.stringify(metadataSnapshot.data())
check(!metadataJSON.includes(VALID_KEY) && !metadataJSON.includes('ciphertext'), 'metadata holds no key material')

console.log('attacking the storage layer directly')
await expectCode(
  setDoc(doc(db, 'users', aliceUID, 'aiCredentials', 'forged'), { status: 'active', provider: 'anthropic' }),
  'permission-denied',
  'owner cannot forge credential metadata',
)
await expectCode(
  getDoc(doc(db, 'privateAiCredentials', aliceUID, 'keys', credentialId)),
  'permission-denied',
  'owner cannot read their own encrypted key',
)

console.log('streaming a capture-shaped task through the gateway')
const captureRequest = {
  credentialId,
  provider: 'anthropic',
  model: 'claude-opus-5',
  messages: [{ role: 'user', content: 'Coffee with Ana — her son starts at South High.' }],
  system: 'You turn one spoken update into a structured capture proposal.',
  maxTokens: 8192,
  effort: 'low',
  outputFormat: { type: 'json_schema', schema: { properties: { participantNames: {} } } },
}
const result = await runStream(captureRequest)
check(result.chunks > 1, `stream arrived in chunks (${result.chunks})`)
check(result.final.adapter === 'fake', 'the fake adapter answered — no real provider contacted')
const proposal = JSON.parse(result.text)
check(Array.isArray(proposal.participantNames), 'reply parses as a capture proposal')

console.log('attacking the gateway with bad requests')
await expectCode(runStream({ ...captureRequest, model: 'gpt-4o' }), 'UNSUPPORTED_MODEL', 'off-catalog model refused')
await expectCode(
  runStream({
    ...captureRequest,
    messages: Array.from({ length: 5 }, () => ({ role: 'user', content: 'x'.repeat(50_000) })),
  }),
  'INVALID_REQUEST',
  'oversized prompt refused',
)
await expectCode(
  runStream({ ...captureRequest, upstreamUrl: 'https://evil.example' }),
  'INVALID_REQUEST',
  'unknown fields refused outright',
)

// ————— User B: the stranger —————
console.log('attacking as a second user')
await createUserWithEmailAndPassword(auth, `bob-${stamp}@example.com`, 'password-2')
await expectCode(runStream(captureRequest), 'CREDENTIAL_NOT_FOUND', "stranger cannot stream on A's credential")
await expectCode(
  callableError('verifyAiCredential', { credentialId }),
  'CREDENTIAL_NOT_FOUND',
  "stranger cannot verify A's credential",
)
await expectCode(
  callableError('replaceAiCredential', { credentialId, apiKey: VALID_KEY }),
  'CREDENTIAL_NOT_FOUND',
  "stranger cannot replace A's credential",
)
const strangerDelete = await callableError('deleteAiCredential', { credentialId })
check(strangerDelete.data.deleted === true, "stranger's delete answers success without revealing anything")
await expectCode(
  getDocs(collection(db, 'users', aliceUID, 'aiCredentials')),
  'permission-denied',
  "stranger cannot list A's credentials",
)

console.log('rejected keys are never stored')
await expectCode(
  callableError('addAiCredential', { provider: 'anthropic', apiKey: 'sk-ant-test-invalid-00000000000000' }),
  'CREDENTIAL_INVALID',
  'definitively rejected key refused',
)
const bobUID = auth.currentUser.uid
const bobCredentials = await getDocs(collection(db, 'users', bobUID, 'aiCredentials'))
check(bobCredentials.empty, 'nothing stored for the rejected key')

// ————— Back to A: the stranger's delete changed nothing; A's own delete works —————
await signInWithEmailAndPassword(auth, `alice-${stamp}@example.com`, 'password-1')
const survivor = await getDoc(doc(db, 'users', aliceUID, 'aiCredentials', credentialId))
check(survivor.exists(), "A's credential survived the stranger's delete")
await httpsCallable(functions, 'deleteAiCredential')({ credentialId })
const afterDelete = await getDoc(doc(db, 'users', aliceUID, 'aiCredentials', credentialId))
check(!afterDelete.exists(), 'owner delete removes the metadata')
await expectCode(runStream(captureRequest), 'CREDENTIAL_NOT_FOUND', 'deleted credential cannot be used')

if (failures > 0) {
  console.error(`BYOK SMOKE FAILED: ${failures} check(s)`)
  process.exit(1)
}
console.log('byok smoke ok: owner lifecycle works, every attack died with the right code')
process.exit(0)
