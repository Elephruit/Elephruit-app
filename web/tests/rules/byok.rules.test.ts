/// The rules under test draw one line: the user's own graph stays owner-
/// read-write, while the BYOK collections are owner-READ at most — every
/// write path belongs to the Admin SDK. Each case here is an attack that
/// must stay dead: forging credential metadata, forging audit events,
/// reading another user's credentials, or touching key material at all.

import { readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
  type RulesTestContext,
  type RulesTestEnvironment,
} from '@firebase/rules-unit-testing'
import { deleteDoc, doc, getDoc, setDoc, updateDoc, type Firestore } from 'firebase/firestore'
import { afterAll, beforeAll, describe, it } from 'vitest'

const here = dirname(fileURLToPath(import.meta.url))
let env: RulesTestEnvironment

const db = (ctx: RulesTestContext) => ctx.firestore() as unknown as Firestore

beforeAll(async () => {
  env = await initializeTestEnvironment({
    projectId: 'demo-elephruit-rules',
    firestore: {
      host: '127.0.0.1',
      port: 8080,
      rules: readFileSync(resolve(here, '../../firestore.rules'), 'utf8'),
    },
  })
  await env.clearFirestore()
  // Server-written fixtures land with rules disabled, the way the Admin SDK
  // writes them in production.
  await env.withSecurityRulesDisabled(async (ctx) => {
    const admin = db(ctx)
    await setDoc(doc(admin, 'users/alice/aiCredentials/cred-1'), {
      provider: 'anthropic',
      keyHint: '7XqP',
      status: 'active',
    })
    await setDoc(doc(admin, 'users/alice/aiCredentialAudit/evt-1'), {
      type: 'credential_added',
      credentialId: 'cred-1',
    })
    await setDoc(doc(admin, 'privateAiCredentials/alice/keys/cred-1'), {
      ownerUid: 'alice',
      ciphertext: 'AAAA',
      kmsKeyName: 'local-dev',
    })
    await setDoc(doc(admin, 'aiRateLimits/c_alice_stream_0'), { count: 1 })
  })
})

afterAll(async () => {
  await env.cleanup()
})

describe('credential metadata', () => {
  it('lets the owner read their credential metadata', async () => {
    const alice = db(env.authenticatedContext('alice'))
    await assertSucceeds(getDoc(doc(alice, 'users/alice/aiCredentials/cred-1')))
  })

  it('refuses another authenticated user', async () => {
    const bob = db(env.authenticatedContext('bob'))
    await assertFails(getDoc(doc(bob, 'users/alice/aiCredentials/cred-1')))
  })

  it('refuses unauthenticated reads', async () => {
    const anon = db(env.unauthenticatedContext())
    await assertFails(getDoc(doc(anon, 'users/alice/aiCredentials/cred-1')))
  })

  it('refuses the owner creating credential metadata', async () => {
    const alice = db(env.authenticatedContext('alice'))
    await assertFails(
      setDoc(doc(alice, 'users/alice/aiCredentials/forged'), { provider: 'anthropic', status: 'active' }),
    )
  })

  it('refuses the owner updating credential metadata', async () => {
    const alice = db(env.authenticatedContext('alice'))
    await assertFails(updateDoc(doc(alice, 'users/alice/aiCredentials/cred-1'), { status: 'active' }))
  })

  it('refuses the owner deleting credential metadata', async () => {
    const alice = db(env.authenticatedContext('alice'))
    await assertFails(deleteDoc(doc(alice, 'users/alice/aiCredentials/cred-1')))
  })
})

describe('audit trail', () => {
  it('lets the owner read their audit events', async () => {
    const alice = db(env.authenticatedContext('alice'))
    await assertSucceeds(getDoc(doc(alice, 'users/alice/aiCredentialAudit/evt-1')))
  })

  it('refuses another user reading audit events', async () => {
    const bob = db(env.authenticatedContext('bob'))
    await assertFails(getDoc(doc(bob, 'users/alice/aiCredentialAudit/evt-1')))
  })

  it('refuses the owner forging audit events', async () => {
    const alice = db(env.authenticatedContext('alice'))
    await assertFails(setDoc(doc(alice, 'users/alice/aiCredentialAudit/forged'), { type: 'credential_added' }))
  })
})

describe('private key material', () => {
  it('refuses even the owner reading their private credential', async () => {
    const alice = db(env.authenticatedContext('alice'))
    await assertFails(getDoc(doc(alice, 'privateAiCredentials/alice/keys/cred-1')))
  })

  it('refuses the owner writing private credentials', async () => {
    const alice = db(env.authenticatedContext('alice'))
    await assertFails(setDoc(doc(alice, 'privateAiCredentials/alice/keys/planted'), { ciphertext: 'BBBB' }))
  })

  it('refuses other users and the unauthenticated alike', async () => {
    const bob = db(env.authenticatedContext('bob'))
    const anon = db(env.unauthenticatedContext())
    await assertFails(getDoc(doc(bob, 'privateAiCredentials/alice/keys/cred-1')))
    await assertFails(getDoc(doc(anon, 'privateAiCredentials/alice/keys/cred-1')))
  })
})

describe('rate-limit records', () => {
  it('refuses reads and writes from any client', async () => {
    const alice = db(env.authenticatedContext('alice'))
    await assertFails(getDoc(doc(alice, 'aiRateLimits/c_alice_stream_0')))
    await assertFails(setDoc(doc(alice, 'aiRateLimits/c_alice_stream_0'), { count: 0 }))
  })
})

describe('the rest of the graph is unchanged', () => {
  it('still lets the owner round-trip ordinary app data', async () => {
    const alice = db(env.authenticatedContext('alice'))
    await assertSucceeds(setDoc(doc(alice, 'users/alice/people/p-1'), { displayName: 'Ana Torres' }))
    await assertSucceeds(getDoc(doc(alice, 'users/alice/people/p-1')))
  })

  it('still refuses strangers ordinary app data', async () => {
    const bob = db(env.authenticatedContext('bob'))
    await assertFails(getDoc(doc(bob, 'users/alice/people/p-1')))
  })
})
