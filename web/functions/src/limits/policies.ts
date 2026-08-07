/// Every limit in one place, server-enforced. The user pays the provider for
/// tokens, but invocations, Firestore writes, and KMS calls bill this
/// project — and a stolen session should not get an unmetered credential
/// oracle either way.

import type { RatePolicy } from './rateLimiter.js'

export const RATE_POLICIES = {
  /// Adds and replacements share a bucket: both cost a provider verification.
  credentialWrite: { limit: 5, windowSeconds: 3600 } satisfies RatePolicy,
  credentialVerify: { limit: 10, windowSeconds: 3600 } satisfies RatePolicy,
  streamStart: { limit: 60, windowSeconds: 60 } satisfies RatePolicy,
} as const

export const MAX_CONCURRENT_STREAMS = 3
