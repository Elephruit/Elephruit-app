/// The credential lifecycle, as plain functions over injected dependencies —
/// the onCall wrappers in index.ts stay thin, and every branch here is unit
/// tested against fakes. Common shape: validate, rate-limit, resolve the
/// caller's own record (never anyone else's — the store is addressed by the
/// verified uid), act, audit, return a sanitized summary.
///
/// The raw key exists in this file between validation and encryption, and is
/// never returned, logged, or stored in the clear.

import type { EncryptionService } from '../crypto/encryption.js'
import type { RatePolicy, RateLimiter } from '../limits/rateLimiter.js'
import { RATE_POLICIES } from '../limits/policies.js'
import { PublicError } from '../log/errors.js'
import type { Logger } from '../log/logger.js'
import type { KeyVerifier } from '../providers/types.js'
import {
  AddCredentialInputSchema,
  DeleteCredentialInputSchema,
  ReplaceCredentialInputSchema,
  VerifyCredentialInputSchema,
  keyHintFor,
} from './schemas.js'
import { summaryOf, type CredentialStore } from './store.js'
import type { AuditWriter, CredentialMetadataDoc, CredentialSummary } from './types.js'

export interface CredentialDeps {
  store: CredentialStore
  encryption: EncryptionService
  verifyKey: KeyVerifier
  rateLimiter: RateLimiter
  audit: AuditWriter
  log: Logger
  now: () => Date
  newId: () => string
  newRequestId: () => string
}

const INVALID_KEY_MESSAGE = 'The provider rejected this key. Check it, or create a fresh one in the provider console.'
const INCONCLUSIVE_MESSAGE = 'The provider could not be reached to check this key. Try again in a moment.'

async function consumeOrThrow(deps: CredentialDeps, uid: string, operation: string, policy: RatePolicy) {
  if (!(await deps.rateLimiter.consume(uid, operation, policy))) {
    throw new PublicError('RATE_LIMITED', 'Too many attempts for now. Try again later.')
  }
}

function parsed<T>(schema: { safeParse(input: unknown): { success: boolean; data?: T } }, input: unknown): T {
  const result = schema.safeParse(input)
  if (!result.success || result.data === undefined) {
    throw new PublicError('INVALID_REQUEST', 'The request was not shaped the way this endpoint expects.')
  }
  return result.data
}

export async function handleAddCredential(
  deps: CredentialDeps,
  uid: string,
  rawInput: unknown,
): Promise<CredentialSummary> {
  const input = parsed(AddCredentialInputSchema, rawInput)
  await consumeOrThrow(deps, uid, 'credential_write', RATE_POLICIES.credentialWrite)

  const requestId = deps.newRequestId()
  const verification = await deps.verifyKey(input.provider, input.apiKey)
  if (verification.outcome === 'invalid') {
    // Nothing is stored for a key the provider definitively rejected.
    deps.log.info('credential_add_rejected', { uid, provider: input.provider, requestId, outcome: 'invalid' })
    throw new PublicError('CREDENTIAL_INVALID', INVALID_KEY_MESSAGE)
  }

  const credentialId = deps.newId()
  const encrypted = await deps.encryption.encrypt(input.apiKey, { uid, credentialId, provider: input.provider })
  const now = deps.now()
  const verifiedNow = verification.outcome === 'valid'
  const metadata: CredentialMetadataDoc = {
    provider: input.provider,
    label: input.label ?? null,
    keyHint: keyHintFor(input.apiKey),
    status: verifiedNow ? 'active' : 'unverified',
    verificationErrorCode: verifiedNow ? null : verification.reason,
    createdAt: now,
    updatedAt: now,
    lastVerifiedAt: verifiedNow ? now : null,
    lastUsedAt: null,
  }
  await deps.store.create(uid, credentialId, {
    metadata,
    privateDoc: {
      ownerUid: uid,
      provider: input.provider,
      ciphertext: encrypted.ciphertext,
      kmsKeyName: encrypted.kmsKeyName,
      createdAt: now,
      rotatedAt: null,
    },
  })
  await deps.audit(uid, { type: 'credential_added', credentialId, provider: input.provider, requestId })
  deps.log.info('credential_added', { uid, credentialId, provider: input.provider, requestId, status: metadata.status })
  return summaryOf(credentialId, metadata)
}

export async function handleVerifyCredential(
  deps: CredentialDeps,
  uid: string,
  rawInput: unknown,
): Promise<{ status: CredentialSummary['status']; outcome: 'valid' | 'invalid' | 'inconclusive' }> {
  const input = parsed(VerifyCredentialInputSchema, rawInput)
  await consumeOrThrow(deps, uid, 'credential_verify', RATE_POLICIES.credentialVerify)

  const requestId = deps.newRequestId()
  const record = await deps.store.loadPrivate(uid, input.credentialId)
  if (!record || record.ownerUid !== uid) {
    throw new PublicError('CREDENTIAL_NOT_FOUND', 'No such credential.')
  }

  const apiKey = await deps.encryption.decrypt(
    { ciphertext: record.ciphertext, kmsKeyName: record.kmsKeyName },
    { uid, credentialId: input.credentialId, provider: record.provider },
  )
  const verification = await deps.verifyKey(record.provider, apiKey)
  const now = deps.now()

  if (verification.outcome === 'valid') {
    await deps.store.updateMetadata(uid, input.credentialId, {
      status: 'active',
      verificationErrorCode: null,
      lastVerifiedAt: now,
      updatedAt: now,
    })
    await deps.audit(uid, {
      type: 'credential_verified',
      credentialId: input.credentialId,
      provider: record.provider,
      requestId,
    })
    return { status: 'active', outcome: 'valid' }
  }

  if (verification.outcome === 'invalid') {
    await deps.store.updateMetadata(uid, input.credentialId, {
      status: 'invalid',
      verificationErrorCode: verification.reason,
      updatedAt: now,
    })
    await deps.audit(uid, {
      type: 'credential_verification_failed',
      credentialId: input.credentialId,
      provider: record.provider,
      requestId,
    })
    return { status: 'invalid', outcome: 'invalid' }
  }

  // Inconclusive: the provider was unreachable, which says nothing about the
  // key. Status stays; the client gets a retriable answer.
  deps.log.info('credential_verify_inconclusive', {
    uid,
    credentialId: input.credentialId,
    provider: record.provider,
    requestId,
    normalizedErrorCode: verification.reason,
  })
  return { status: 'unverified', outcome: 'inconclusive' }
}

export async function handleReplaceCredential(
  deps: CredentialDeps,
  uid: string,
  rawInput: unknown,
): Promise<CredentialSummary> {
  const input = parsed(ReplaceCredentialInputSchema, rawInput)
  await consumeOrThrow(deps, uid, 'credential_write', RATE_POLICIES.credentialWrite)

  const requestId = deps.newRequestId()
  const record = await deps.store.loadPrivate(uid, input.credentialId)
  if (!record || record.ownerUid !== uid) {
    throw new PublicError('CREDENTIAL_NOT_FOUND', 'No such credential.')
  }

  // The provider is fixed by the stored credential; the new key is verified
  // before anything is overwritten, so a bad paste never destroys a working
  // key.
  const verification = await deps.verifyKey(record.provider, input.apiKey)
  if (verification.outcome === 'invalid') {
    throw new PublicError('CREDENTIAL_INVALID', INVALID_KEY_MESSAGE)
  }
  if (verification.outcome === 'inconclusive') {
    throw new PublicError('PROVIDER_UNAVAILABLE', INCONCLUSIVE_MESSAGE)
  }

  const encrypted = await deps.encryption.encrypt(input.apiKey, {
    uid,
    credentialId: input.credentialId,
    provider: record.provider,
  })
  const now = deps.now()
  const metadataPatch = {
    keyHint: keyHintFor(input.apiKey),
    status: 'active' as const,
    verificationErrorCode: null,
    lastVerifiedAt: now,
    updatedAt: now,
  }
  await deps.store.replace(
    uid,
    input.credentialId,
    { ciphertext: encrypted.ciphertext, kmsKeyName: encrypted.kmsKeyName, rotatedAt: now },
    metadataPatch,
  )
  await deps.audit(uid, {
    type: 'credential_replaced',
    credentialId: input.credentialId,
    provider: record.provider,
    requestId,
  })
  deps.log.info('credential_replaced', { uid, credentialId: input.credentialId, provider: record.provider, requestId })
  const metadata = await deps.store.loadMetadata(uid, input.credentialId)
  return {
    id: input.credentialId,
    provider: record.provider,
    label: metadata?.label ?? null,
    keyHint: metadataPatch.keyHint,
    status: 'active',
    verificationErrorCode: null,
  }
}

export async function handleDeleteCredential(
  deps: CredentialDeps,
  uid: string,
  rawInput: unknown,
): Promise<{ deleted: boolean }> {
  const input = parsed(DeleteCredentialInputSchema, rawInput)
  const requestId = deps.newRequestId()

  const record = await deps.store.loadPrivate(uid, input.credentialId)
  if (record && record.ownerUid === uid) {
    await deps.store.delete(uid, input.credentialId)
    await deps.audit(uid, {
      type: 'credential_deleted',
      credentialId: input.credentialId,
      provider: record.provider,
      requestId,
    })
    deps.log.info('credential_deleted', { uid, credentialId: input.credentialId, provider: record.provider, requestId })
  }
  // Deleting the nonexistent succeeds: idempotent for the owner, silent about
  // whether anyone else's credential id exists.
  return { deleted: true }
}
