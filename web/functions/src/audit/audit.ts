/// Owner-readable audit trail of credential lifecycle events. Never prompts,
/// never outputs, never key material — only which action touched which
/// credential, when, under which request id. credential_used is sampled by
/// the caller, not here; lifecycle events always land.

import type { Firestore } from 'firebase-admin/firestore'
import type { AuditEvent, AuditWriter } from '../credentials/types.js'

export function firestoreAuditWriter(db: Firestore, now: () => Date = () => new Date()): AuditWriter {
  return async (uid: string, event: AuditEvent) => {
    await db.collection(`users/${uid}/aiCredentialAudit`).add({
      type: event.type,
      credentialId: event.credentialId,
      provider: event.provider,
      requestId: event.requestId,
      occurredAt: now(),
    })
  }
}
