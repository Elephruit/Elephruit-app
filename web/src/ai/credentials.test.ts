import { describe, expect, it } from 'vitest'
import { activeCredential, type AiCredential } from './credentials'

function credential(provider: AiCredential['provider'], status: AiCredential['status']): AiCredential {
  return {
    id: `${provider}-${status}`,
    provider,
    status,
    label: null,
    keyHint: '1234',
    verificationErrorCode: null,
    createdAt: new Date(0),
    lastVerifiedAt: null,
    lastUsedAt: null,
  }
}

describe('activeCredential', () => {
  it('selects only a usable credential for the chosen provider', () => {
    const credentials = [
      credential('anthropic', 'active'),
      credential('openai', 'unverified'),
      credential('google', 'invalid'),
    ]
    expect(activeCredential(credentials, 'openai')?.id).toBe('openai-unverified')
    expect(activeCredential(credentials, 'google')).toBeNull()
  })
})
