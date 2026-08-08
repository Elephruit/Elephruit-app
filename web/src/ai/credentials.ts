/// Credential lifecycle from the browser's side: thin wrappers over the
/// server callables. A raw key passes through exactly once — from the
/// password field into addAiCredential or replaceAiCredential over HTTPS —
/// and never comes back; everything the UI shows afterwards comes from the
/// server-written metadata the owner may read.

import { httpsCallable } from 'firebase/functions'
import { functions } from '../data/firebase'
import { toGatewayError, type AIProvider } from './gateway'

export type AiCredentialStatus = 'active' | 'invalid' | 'unverified' | 'revoked'

/// Mirror of the server-written metadata document (dates deserialized).
export interface AiCredential {
  id: string
  provider: AIProvider
  label: string | null
  keyHint: string
  status: AiCredentialStatus
  verificationErrorCode: string | null
  createdAt: Date
  lastVerifiedAt: Date | null
  lastUsedAt: Date | null
}

/// What the callables return — the subscription refreshes the full record.
export type AiCredentialSummary = Pick<
  AiCredential,
  'id' | 'provider' | 'label' | 'keyHint' | 'status' | 'verificationErrorCode'
>

async function call<Request, Response>(name: string, payload: Request): Promise<Response> {
  try {
    const result = await httpsCallable<Request, Response>(functions, name)(payload)
    return result.data
  } catch (error) {
    throw toGatewayError(error)
  }
}

export function addAiCredential(provider: AIProvider, apiKey: string, label?: string): Promise<AiCredentialSummary> {
  return call('addAiCredential', { provider, apiKey, ...(label ? { label } : {}) })
}

export function verifyAiCredential(
  credentialId: string,
): Promise<{ status: AiCredentialStatus; outcome: 'valid' | 'invalid' | 'inconclusive' }> {
  return call('verifyAiCredential', { credentialId })
}

export function replaceAiCredential(credentialId: string, apiKey: string): Promise<AiCredentialSummary> {
  return call('replaceAiCredential', { credentialId, apiKey })
}

export function deleteAiCredential(credentialId: string): Promise<{ deleted: boolean }> {
  return call('deleteAiCredential', { credentialId })
}

/// The credential AI features run under: an active one if any, else an
/// unverified one (added while the provider was unreachable — using it is
/// effectively the retry). invalid and revoked never auto-selected.
export function activeCredential(credentials: AiCredential[] | undefined, provider: AIProvider): AiCredential | null {
  if (!credentials) return null
  return (
    credentials.find((credential) => credential.provider === provider && credential.status === 'active') ??
    credentials.find((credential) => credential.provider === provider && credential.status === 'unverified') ??
    null
  )
}
