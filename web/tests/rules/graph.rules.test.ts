/// The owner-only wildcard on `users/{uid}/{collectionName}/{docID}` covers
/// every collection the graph adds, including ones that did not exist when the
/// rule was written. That is convenient and slightly dangerous: a new
/// collection is protected by default, so nothing fails loudly if one is ever
/// added in the wrong place, and nobody finds out until a stranger reads it.
///
/// So every collection gets a case here, and the new ones get theirs in the
/// same commit that creates them.

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
import { deleteDoc, doc, getDoc, setDoc, type Firestore } from 'firebase/firestore'
import { afterAll, beforeAll, describe, it } from 'vitest'

const here = dirname(fileURLToPath(import.meta.url))
let env: RulesTestEnvironment

const db = (ctx: RulesTestContext) => ctx.firestore() as unknown as Firestore

/// Every collection in COLLECTIONS. Kept as a literal rather than imported so
/// that adding a collection to the domain does not silently add a passing case
/// here — the list is the assertion.
const OWNED_COLLECTIONS = [
  'people',
  'interactions',
  'relationships',
  'observations',
  'reminders',
  'containers',
  'sources',
  'memories',
] as const

beforeAll(async () => {
  env = await initializeTestEnvironment({
    projectId: 'demo-elephruit-graph-rules',
    firestore: {
      host: '127.0.0.1',
      port: Number(process.env.FIRESTORE_EMULATOR_PORT ?? 8080),
      rules: readFileSync(resolve(here, '../../firestore.rules'), 'utf8'),
    },
  })
  await env.clearFirestore()
})

afterAll(async () => {
  await env.cleanup()
})

describe('the user’s own graph', () => {
  for (const collection of OWNED_COLLECTIONS) {
    it(`lets the owner round-trip a ${collection} document`, async () => {
      const alice = db(env.authenticatedContext('alice'))
      const ref = doc(alice, `users/alice/${collection}/doc-1`)
      await assertSucceeds(setDoc(ref, { title: 'Chicago, October' }))
      await assertSucceeds(getDoc(ref))
      await assertSucceeds(deleteDoc(ref))
    })

    it(`refuses a stranger every operation on ${collection}`, async () => {
      const mallory = db(env.authenticatedContext('mallory'))
      const ref = doc(mallory, `users/alice/${collection}/doc-1`)
      await assertFails(setDoc(ref, { title: 'Not yours' }))
      await assertFails(getDoc(ref))
      await assertFails(deleteDoc(ref))
    })

    it(`refuses an unauthenticated client ${collection}`, async () => {
      const anonymous = db(env.unauthenticatedContext())
      const ref = doc(anonymous, `users/alice/${collection}/doc-1`)
      await assertFails(setDoc(ref, { title: 'Not yours' }))
      await assertFails(getDoc(ref))
    })
  }
})
