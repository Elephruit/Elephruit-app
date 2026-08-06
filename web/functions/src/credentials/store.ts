/// Credential persistence behind an interface, so the handlers stay pure
/// enough to unit test against an in-memory fake while the real
/// implementation speaks Admin-SDK Firestore. The private document is always
/// addressed by the caller's verified uid — a lookup for another user's
/// credential id lands on a path that cannot exist for them.

import type { Firestore } from 'firebase-admin/firestore'
import type { CredentialMetadataDoc, CredentialSummary, PrivateCredentialDoc } from './types.js'

export interface CredentialRecord {
  credentialId: string
  metadata: CredentialMetadataDoc
  privateDoc: PrivateCredentialDoc
}

export interface CredentialStore {
  loadPrivate(uid: string, credentialId: string): Promise<PrivateCredentialDoc | null>
  loadMetadata(uid: string, credentialId: string): Promise<CredentialMetadataDoc | null>
  create(uid: string, credentialId: string, record: Omit<CredentialRecord, 'credentialId'>): Promise<void>
  /// Atomically updates both documents on replace.
  replace(
    uid: string,
    credentialId: string,
    privatePatch: Pick<PrivateCredentialDoc, 'ciphertext' | 'kmsKeyName' | 'rotatedAt'>,
    metadataPatch: Partial<CredentialMetadataDoc>,
  ): Promise<void>
  updateMetadata(uid: string, credentialId: string, patch: Partial<CredentialMetadataDoc>): Promise<void>
  /// Deletes both documents; harmless when they are already gone.
  delete(uid: string, credentialId: string): Promise<void>
}

export function metadataPath(uid: string, credentialId: string): string {
  return `users/${uid}/aiCredentials/${credentialId}`
}

export function privatePath(uid: string, credentialId: string): string {
  return `privateAiCredentials/${uid}/keys/${credentialId}`
}

export class FirestoreCredentialStore implements CredentialStore {
  constructor(private readonly db: Firestore) {}

  async loadPrivate(uid: string, credentialId: string): Promise<PrivateCredentialDoc | null> {
    const snapshot = await this.db.doc(privatePath(uid, credentialId)).get()
    if (!snapshot.exists) return null
    const data = snapshot.data() as Record<string, unknown>
    return {
      ...(data as unknown as PrivateCredentialDoc),
      createdAt: toDate(data.createdAt) ?? new Date(0),
      rotatedAt: toDate(data.rotatedAt),
    }
  }

  async loadMetadata(uid: string, credentialId: string): Promise<CredentialMetadataDoc | null> {
    const snapshot = await this.db.doc(metadataPath(uid, credentialId)).get()
    if (!snapshot.exists) return null
    const data = snapshot.data() as Record<string, unknown>
    return {
      ...(data as unknown as CredentialMetadataDoc),
      createdAt: toDate(data.createdAt) ?? new Date(0),
      updatedAt: toDate(data.updatedAt) ?? new Date(0),
      lastVerifiedAt: toDate(data.lastVerifiedAt),
      lastUsedAt: toDate(data.lastUsedAt),
    }
  }

  async create(uid: string, credentialId: string, record: Omit<CredentialRecord, 'credentialId'>): Promise<void> {
    const batch = this.db.batch()
    batch.set(this.db.doc(privatePath(uid, credentialId)), record.privateDoc)
    batch.set(this.db.doc(metadataPath(uid, credentialId)), record.metadata)
    await batch.commit()
  }

  async replace(
    uid: string,
    credentialId: string,
    privatePatch: Pick<PrivateCredentialDoc, 'ciphertext' | 'kmsKeyName' | 'rotatedAt'>,
    metadataPatch: Partial<CredentialMetadataDoc>,
  ): Promise<void> {
    const batch = this.db.batch()
    batch.update(this.db.doc(privatePath(uid, credentialId)), { ...privatePatch })
    batch.update(this.db.doc(metadataPath(uid, credentialId)), { ...metadataPatch })
    await batch.commit()
  }

  async updateMetadata(uid: string, credentialId: string, patch: Partial<CredentialMetadataDoc>): Promise<void> {
    await this.db.doc(metadataPath(uid, credentialId)).update({ ...patch })
  }

  async delete(uid: string, credentialId: string): Promise<void> {
    const batch = this.db.batch()
    batch.delete(this.db.doc(privatePath(uid, credentialId)))
    batch.delete(this.db.doc(metadataPath(uid, credentialId)))
    await batch.commit()
  }
}

export function summaryOf(credentialId: string, metadata: CredentialMetadataDoc): CredentialSummary {
  return {
    id: credentialId,
    provider: metadata.provider,
    label: metadata.label,
    keyHint: metadata.keyHint,
    status: metadata.status,
    verificationErrorCode: metadata.verificationErrorCode,
  }
}

function toDate(value: unknown): Date | null {
  if (value == null) return null
  if (value instanceof Date) return value
  if (typeof value === 'object' && 'toDate' in value) return (value as { toDate(): Date }).toDate()
  return null
}
