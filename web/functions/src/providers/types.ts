/// Provider vocabulary shared by verification (credential lifecycle) and
/// streaming (the gateway). One provider today; the types already speak in
/// the plural so OpenAI/Google slot in without reshaping callers.

export const PROVIDERS = ['anthropic', 'openai', 'google'] as const
export type ProviderId = (typeof PROVIDERS)[number]

/// Verification is deliberately tri-state. Only a definite authentication or
/// permission failure marks a key invalid; provider downtime, rate limits,
/// and network trouble are inconclusive — the key may be fine, so nothing
/// destructive may happen on their account.
export type KeyVerification =
  | { outcome: 'valid' }
  | { outcome: 'invalid'; reason: 'unauthorized' }
  | { outcome: 'inconclusive'; reason: 'rate_limited' | 'provider_unavailable' | 'network' }

export type KeyVerifier = (provider: ProviderId, apiKey: string) => Promise<KeyVerification>
