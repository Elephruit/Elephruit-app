/// Key verification against the provider, at zero generation cost: the
/// models-list endpoint authenticates the key without producing a billable
/// token. 401/403 is the only verdict that condemns a key; everything else —
/// 429, 5xx, network trouble — is inconclusive and must not flip status.
///
/// The fake verifier serves the emulator (AI_FAKE_ADAPTER): deterministic
/// verdicts keyed off test key names, no network, so the whole credential
/// lifecycle runs offline.

import Anthropic from '@anthropic-ai/sdk'
import type { RuntimeConfig } from '../config.js'
import type { KeyVerification, KeyVerifier } from './types.js'

const VERIFY_TIMEOUT_MS = 10_000

export const verifyAnthropicKey = async (apiKey: string): Promise<KeyVerification> => {
  const client = new Anthropic({ apiKey, maxRetries: 0, timeout: VERIFY_TIMEOUT_MS })
  try {
    await client.models.list()
    return { outcome: 'valid' }
  } catch (error) {
    if (error instanceof Anthropic.AuthenticationError || error instanceof Anthropic.PermissionDeniedError) {
      return { outcome: 'invalid', reason: 'unauthorized' }
    }
    if (error instanceof Anthropic.RateLimitError) {
      return { outcome: 'inconclusive', reason: 'rate_limited' }
    }
    if (error instanceof Anthropic.APIConnectionError) {
      return { outcome: 'inconclusive', reason: 'network' }
    }
    return { outcome: 'inconclusive', reason: 'provider_unavailable' }
  }
}

/// Test keys the fake recognizes; anything else it accepts, so a stray real
/// key pasted into the emulator is never sent anywhere.
export const fakeVerifyKey = async (apiKey: string): Promise<KeyVerification> => {
  if (apiKey.includes('-invalid')) return { outcome: 'invalid', reason: 'unauthorized' }
  if (apiKey.includes('-flaky')) return { outcome: 'inconclusive', reason: 'provider_unavailable' }
  return { outcome: 'valid' }
}

export function buildKeyVerifier(config: RuntimeConfig): KeyVerifier {
  const useFake = config.useFakeAdapter && config.isEmulator
  return async (provider, apiKey) => {
    switch (provider) {
      case 'anthropic':
        return useFake ? fakeVerifyKey(apiKey) : verifyAnthropicKey(apiKey)
    }
  }
}
