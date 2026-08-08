/// Every branch of the credential lifecycle against fakes: an in-memory
/// store, a recording encryption service whose ciphertext embeds the
/// context (so binding mistakes surface as decrypt failures), and a
/// scriptable verifier. The recurring assertions: raw keys never appear in
/// stored metadata or returned values, invalid keys are never stored, and
/// another user's credential id behaves exactly like a missing one.

import { describe, expect, it } from 'vitest'
import { PublicError } from '../log/errors.js'
import type { KeyVerification } from '../providers/types.js'
import { MemoryStore, fakeEncryption, silentLog } from '../testing/fakes.js'
import {
  handleAddCredential,
  handleDeleteCredential,
  handleReplaceCredential,
  handleVerifyCredential,
  type CredentialDeps,
} from './handlers.js'
import type { AuditEvent } from './types.js'

const RAW_KEY = 'sk-ant-test-valid-00000000007XqP'

interface Overrides {
  verdict?: KeyVerification
  rateLimited?: boolean
}

function makeDeps(overrides: Overrides = {}) {
  const store = new MemoryStore()
  const auditEvents: Array<{ uid: string; event: AuditEvent }> = []
  let idCounter = 0
  const deps: CredentialDeps = {
    store,
    encryption: fakeEncryption,
    verifyKey: async () => overrides.verdict ?? { outcome: 'valid' },
    rateLimiter: { consume: async () => !(overrides.rateLimited ?? false) },
    audit: async (uid, event) => {
      auditEvents.push({ uid, event })
    },
    log: silentLog,
    now: () => new Date('2026-08-06T12:00:00Z'),
    newId: () => `cred-${++idCounter}`,
    newRequestId: () => 'req-1',
  }
  return { deps, store, auditEvents }
}

async function expectPublicError(promise: Promise<unknown>, code: string) {
  try {
    await promise
    expect.unreachable(`expected PublicError ${code}`)
  } catch (error) {
    expect(error).toBeInstanceOf(PublicError)
    expect((error as PublicError).code).toBe(code)
  }
}

describe('handleAddCredential', () => {
  it('verifies, encrypts, stores both documents, and returns a sanitized summary', async () => {
    const { deps, store, auditEvents } = makeDeps()
    const summary = await handleAddCredential(deps, 'alice', {
      provider: 'anthropic',
      apiKey: RAW_KEY,
      label: 'My key',
    })

    expect(summary).toEqual({
      id: 'cred-1',
      provider: 'anthropic',
      label: 'My key',
      keyHint: '7XqP',
      status: 'active',
      verificationErrorCode: null,
    })
    const record = store.records.get('alice/cred-1')
    expect(record).toBeDefined()
    expect(record?.privateDoc.ownerUid).toBe('alice')
    expect(record?.privateDoc.ciphertext).not.toContain(RAW_KEY)
    expect(JSON.stringify(record?.metadata)).not.toContain(RAW_KEY)
    expect(JSON.stringify(summary)).not.toContain(RAW_KEY)
    expect(auditEvents).toEqual([
      {
        uid: 'alice',
        event: { type: 'credential_added', credentialId: 'cred-1', provider: 'anthropic', requestId: 'req-1' },
      },
    ])
  })

  it('binds the ciphertext to uid, credential id, and provider', async () => {
    const { deps } = makeDeps()
    await handleAddCredential(deps, 'alice', { provider: 'anthropic', apiKey: RAW_KEY })
    const stored = await deps.store.loadPrivate('alice', 'cred-1')
    await expect(
      fakeEncryption.decrypt(
        { ciphertext: stored!.ciphertext, kmsKeyName: stored!.kmsKeyName },
        { uid: 'alice', credentialId: 'cred-1', provider: 'anthropic' },
      ),
    ).resolves.toBe(RAW_KEY)
    await expect(
      fakeEncryption.decrypt(
        { ciphertext: stored!.ciphertext, kmsKeyName: stored!.kmsKeyName },
        { uid: 'bob', credentialId: 'cred-1', provider: 'anthropic' },
      ),
    ).rejects.toThrow()
  })

  it('stores nothing when the provider rejects the key', async () => {
    const { deps, store, auditEvents } = makeDeps({ verdict: { outcome: 'invalid', reason: 'unauthorized' } })
    await expectPublicError(
      handleAddCredential(deps, 'alice', { provider: 'anthropic', apiKey: RAW_KEY }),
      'CREDENTIAL_INVALID',
    )
    expect(store.records.size).toBe(0)
    expect(auditEvents).toEqual([])
  })

  it('stores an unverified credential when the provider is unreachable', async () => {
    const { deps, store } = makeDeps({ verdict: { outcome: 'inconclusive', reason: 'provider_unavailable' } })
    const summary = await handleAddCredential(deps, 'alice', { provider: 'anthropic', apiKey: RAW_KEY })
    expect(summary.status).toBe('unverified')
    expect(summary.verificationErrorCode).toBe('provider_unavailable')
    expect(store.records.get('alice/cred-1')?.metadata.lastVerifiedAt).toBeNull()
  })

  it('honors the rate limit', async () => {
    const { deps } = makeDeps({ rateLimited: true })
    await expectPublicError(
      handleAddCredential(deps, 'alice', { provider: 'anthropic', apiKey: RAW_KEY }),
      'RATE_LIMITED',
    )
  })

  it('rejects malformed input: unknown fields, short keys, wrong provider', async () => {
    const { deps } = makeDeps()
    await expectPublicError(
      handleAddCredential(deps, 'alice', { provider: 'anthropic', apiKey: RAW_KEY, extra: 1 }),
      'INVALID_REQUEST',
    )
    await expectPublicError(
      handleAddCredential(deps, 'alice', { provider: 'anthropic', apiKey: 'short' }),
      'INVALID_REQUEST',
    )
    await expectPublicError(handleAddCredential(deps, 'alice', { provider: 'mistral', apiKey: RAW_KEY }), 'INVALID_REQUEST')
  })
})

describe('handleVerifyCredential', () => {
  async function seeded(overrides: Overrides = {}) {
    const made = makeDeps()
    await handleAddCredential(made.deps, 'alice', { provider: 'anthropic', apiKey: RAW_KEY })
    const deps: CredentialDeps = {
      ...made.deps,
      verifyKey: async () => overrides.verdict ?? { outcome: 'valid' },
      rateLimiter: { consume: async () => !(overrides.rateLimited ?? false) },
    }
    return { ...made, deps }
  }

  it('marks a good key active', async () => {
    const { deps, store } = await seeded({ verdict: { outcome: 'valid' } })
    const result = await handleVerifyCredential(deps, 'alice', { credentialId: 'cred-1' })
    expect(result).toEqual({ status: 'active', outcome: 'valid' })
    expect(store.records.get('alice/cred-1')?.metadata.lastVerifiedAt).not.toBeNull()
  })

  it('marks a rejected key invalid and records the failure', async () => {
    const { deps, store, auditEvents } = await seeded({ verdict: { outcome: 'invalid', reason: 'unauthorized' } })
    const result = await handleVerifyCredential(deps, 'alice', { credentialId: 'cred-1' })
    expect(result.outcome).toBe('invalid')
    expect(store.records.get('alice/cred-1')?.metadata.status).toBe('invalid')
    expect(auditEvents.map((entry) => entry.event.type)).toContain('credential_verification_failed')
  })

  it('leaves status untouched when the provider is unreachable', async () => {
    const { deps, store } = await seeded({ verdict: { outcome: 'inconclusive', reason: 'rate_limited' } })
    const before = store.records.get('alice/cred-1')?.metadata.status
    const result = await handleVerifyCredential(deps, 'alice', { credentialId: 'cred-1' })
    expect(result.outcome).toBe('inconclusive')
    expect(store.records.get('alice/cred-1')?.metadata.status).toBe(before)
  })

  it("treats another user's credential id as nonexistent", async () => {
    const { deps } = await seeded()
    await expectPublicError(handleVerifyCredential(deps, 'bob', { credentialId: 'cred-1' }), 'CREDENTIAL_NOT_FOUND')
  })

  it('refuses a record whose ownerUid disagrees with the path', async () => {
    const { deps, store } = await seeded()
    store.records.get('alice/cred-1')!.privateDoc.ownerUid = 'mallory'
    await expectPublicError(handleVerifyCredential(deps, 'alice', { credentialId: 'cred-1' }), 'CREDENTIAL_NOT_FOUND')
  })
})

describe('handleReplaceCredential', () => {
  const NEW_KEY = 'sk-ant-test-valid-11111111119ZzA'

  async function seeded(overrides: Overrides = {}) {
    const made = makeDeps()
    await handleAddCredential(made.deps, 'alice', { provider: 'anthropic', apiKey: RAW_KEY, label: 'Kept label' })
    const deps: CredentialDeps = {
      ...made.deps,
      verifyKey: async () => overrides.verdict ?? { outcome: 'valid' },
    }
    return { ...made, deps }
  }

  it('verifies the new key before overwriting, updates hint, keeps the label', async () => {
    const { deps, store } = await seeded()
    const before = store.records.get('alice/cred-1')!.privateDoc.ciphertext
    const summary = await handleReplaceCredential(deps, 'alice', { credentialId: 'cred-1', apiKey: NEW_KEY })
    expect(summary.keyHint).toBe('9ZzA')
    expect(summary.label).toBe('Kept label')
    expect(summary.status).toBe('active')
    expect(store.records.get('alice/cred-1')!.privateDoc.ciphertext).not.toBe(before)
    expect(store.records.get('alice/cred-1')!.privateDoc.rotatedAt).not.toBeNull()
  })

  it('leaves the working key untouched when the new one is rejected', async () => {
    const { deps, store } = await seeded({ verdict: { outcome: 'invalid', reason: 'unauthorized' } })
    const before = store.records.get('alice/cred-1')!.privateDoc.ciphertext
    await expectPublicError(
      handleReplaceCredential(deps, 'alice', { credentialId: 'cred-1', apiKey: NEW_KEY }),
      'CREDENTIAL_INVALID',
    )
    expect(store.records.get('alice/cred-1')!.privateDoc.ciphertext).toBe(before)
    expect(store.records.get('alice/cred-1')!.metadata.keyHint).toBe('7XqP')
  })

  it('does not replace on an inconclusive verification either', async () => {
    const { deps, store } = await seeded({ verdict: { outcome: 'inconclusive', reason: 'network' } })
    const before = store.records.get('alice/cred-1')!.privateDoc.ciphertext
    await expectPublicError(
      handleReplaceCredential(deps, 'alice', { credentialId: 'cred-1', apiKey: NEW_KEY }),
      'PROVIDER_UNAVAILABLE',
    )
    expect(store.records.get('alice/cred-1')!.privateDoc.ciphertext).toBe(before)
  })

  it("treats another user's credential as nonexistent", async () => {
    const { deps } = await seeded()
    await expectPublicError(
      handleReplaceCredential(deps, 'bob', { credentialId: 'cred-1', apiKey: NEW_KEY }),
      'CREDENTIAL_NOT_FOUND',
    )
  })
})

describe('handleDeleteCredential', () => {
  it('removes both documents and audits the deletion', async () => {
    const { deps, store, auditEvents } = makeDeps()
    await handleAddCredential(deps, 'alice', { provider: 'anthropic', apiKey: RAW_KEY })
    const result = await handleDeleteCredential(deps, 'alice', { credentialId: 'cred-1' })
    expect(result).toEqual({ deleted: true })
    expect(store.records.size).toBe(0)
    expect(auditEvents.map((entry) => entry.event.type)).toContain('credential_deleted')
  })

  it('succeeds silently for the nonexistent — no enumeration signal, no audit', async () => {
    const { deps, auditEvents } = makeDeps()
    const result = await handleDeleteCredential(deps, 'alice', { credentialId: 'cred-404' })
    expect(result).toEqual({ deleted: true })
    expect(auditEvents).toEqual([])
  })

  it("does not delete another user's credential", async () => {
    const { deps, store } = makeDeps()
    await handleAddCredential(deps, 'alice', { provider: 'anthropic', apiKey: RAW_KEY })
    const result = await handleDeleteCredential(deps, 'bob', { credentialId: 'cred-1' })
    expect(result).toEqual({ deleted: true })
    expect(store.records.has('alice/cred-1')).toBe(true)
  })
})
