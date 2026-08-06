/// The two documents a credential lives in, and the summary shape the client
/// is allowed to see. The metadata document is the server's testimony about
/// the key; the private document is the key itself, encrypted, in a
/// collection no client rule can ever reach.

import type { ProviderId } from '../providers/types.js'

export type CredentialStatus = 'active' | 'invalid' | 'unverified' | 'revoked'

/// users/{uid}/aiCredentials/{credentialId} — owner-readable.
export interface CredentialMetadataDoc {
  provider: ProviderId
  label: string | null
  /// Last four characters of the key. Enough to tell two keys apart in the
  /// UI, useless to an attacker.
  keyHint: string
  status: CredentialStatus
  verificationErrorCode: string | null
  createdAt: Date
  updatedAt: Date
  lastVerifiedAt: Date | null
  lastUsedAt: Date | null
}

/// privateAiCredentials/{uid}/keys/{credentialId} — no client access, ever.
/// The path carries the owner; ownerUid is belt-and-braces against a lookup
/// that somehow bypassed the uid-keyed path.
export interface PrivateCredentialDoc {
  ownerUid: string
  provider: ProviderId
  ciphertext: string
  kmsKeyName: string
  createdAt: Date
  rotatedAt: Date | null
}

/// What callables return and the metadata subscription mirrors.
export interface CredentialSummary {
  id: string
  provider: ProviderId
  label: string | null
  keyHint: string
  status: CredentialStatus
  verificationErrorCode: string | null
}

export type AuditEventType =
  | 'credential_added'
  | 'credential_verified'
  | 'credential_verification_failed'
  | 'credential_replaced'
  | 'credential_deleted'
  | 'credential_used'

export interface AuditEvent {
  type: AuditEventType
  credentialId: string
  provider: ProviderId
  requestId: string
}

export type AuditWriter = (uid: string, event: AuditEvent) => Promise<void>
