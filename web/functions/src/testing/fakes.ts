/// Shared unit-test fakes: an in-memory credential store and a cipher whose
/// ciphertext embeds the encryption context, so any binding mistake in a
/// handler surfaces as a decrypt failure in the test instead of passing
/// silently. Test-only — excluded from the shipped build.

import type { CredentialRecord, CredentialStore } from '../credentials/store.js'
import type { CredentialMetadataDoc, PrivateCredentialDoc } from '../credentials/types.js'
import type { EncryptedCredential, EncryptionContext, EncryptionService } from '../crypto/encryption.js'
import type { Logger } from '../log/logger.js'

export class MemoryStore implements CredentialStore {
  records = new Map<string, { metadata: CredentialMetadataDoc; privateDoc: PrivateCredentialDoc }>()

  private key(uid: string, credentialId: string) {
    return `${uid}/${credentialId}`
  }

  async loadPrivate(uid: string, credentialId: string) {
    return this.records.get(this.key(uid, credentialId))?.privateDoc ?? null
  }

  async loadMetadata(uid: string, credentialId: string) {
    return this.records.get(this.key(uid, credentialId))?.metadata ?? null
  }

  async create(uid: string, credentialId: string, record: Omit<CredentialRecord, 'credentialId'>) {
    this.records.set(this.key(uid, credentialId), { metadata: record.metadata, privateDoc: record.privateDoc })
  }

  async replace(
    uid: string,
    credentialId: string,
    privatePatch: Pick<PrivateCredentialDoc, 'ciphertext' | 'kmsKeyName' | 'rotatedAt'>,
    metadataPatch: Partial<CredentialMetadataDoc>,
  ) {
    const record = this.records.get(this.key(uid, credentialId))
    if (!record) throw new Error('replace on missing record')
    Object.assign(record.privateDoc, privatePatch)
    Object.assign(record.metadata, metadataPatch)
  }

  async updateMetadata(uid: string, credentialId: string, patch: Partial<CredentialMetadataDoc>) {
    const record = this.records.get(this.key(uid, credentialId))
    if (!record) throw new Error('update on missing record')
    Object.assign(record.metadata, patch)
  }

  async delete(uid: string, credentialId: string) {
    this.records.delete(this.key(uid, credentialId))
  }
}

export const contextTag = (ctx: EncryptionContext) => `${ctx.uid}|${ctx.credentialId}|${ctx.provider}`

export const fakeEncryption: EncryptionService = {
  async encrypt(plaintext, ctx) {
    return {
      ciphertext: Buffer.from(`${plaintext}::${contextTag(ctx)}`, 'utf8').toString('base64'),
      kmsKeyName: 'fake-kms',
    }
  },
  async decrypt(encrypted: EncryptedCredential, ctx) {
    const [plaintext, tag] = Buffer.from(encrypted.ciphertext, 'base64').toString('utf8').split('::')
    if (tag !== contextTag(ctx)) throw new Error('context mismatch — ciphertext bound to a different record')
    return plaintext ?? ''
  },
}

export const silentLog: Logger = { info: () => {}, warn: () => {}, error: () => {} }

export function activeMetadata(overrides: Partial<CredentialMetadataDoc> = {}): CredentialMetadataDoc {
  return {
    provider: 'anthropic',
    label: null,
    keyHint: '7XqP',
    status: 'active',
    verificationErrorCode: null,
    createdAt: new Date('2026-08-01T00:00:00Z'),
    updatedAt: new Date('2026-08-01T00:00:00Z'),
    lastVerifiedAt: new Date('2026-08-01T00:00:00Z'),
    lastUsedAt: null,
    ...overrides,
  }
}
