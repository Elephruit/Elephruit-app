/// The public error vocabulary — the only failure shapes the browser ever
/// sees. Everything upstream (provider bodies, KMS details, stack traces,
/// which user owns what) is flattened into one of these codes plus a short
/// human sentence. Ownership failures deliberately share CREDENTIAL_NOT_FOUND
/// with nonexistence, so probing another user's credential ids learns nothing.

import { HttpsError, type FunctionsErrorCode } from 'firebase-functions/v2/https'

export type PublicAiErrorCode =
  | 'AUTH_REQUIRED'
  | 'INVALID_REQUEST'
  | 'CREDENTIAL_NOT_FOUND'
  | 'CREDENTIAL_INVALID'
  | 'CREDENTIAL_NOT_ACTIVE'
  | 'UNSUPPORTED_PROVIDER'
  | 'UNSUPPORTED_MODEL'
  | 'RATE_LIMITED'
  | 'TOO_MANY_CONCURRENT_STREAMS'
  | 'PROVIDER_AUTH_FAILED'
  | 'PROVIDER_RATE_LIMITED'
  | 'PROVIDER_UNAVAILABLE'
  | 'INTERNAL'

export class PublicError extends Error {
  /// Server-log-only diagnostics (upstream HTTP status, truncated upstream
  /// complaint). Never serialized to the client — toHttpsError ignores them.
  providerStatus?: number
  providerNote?: string

  constructor(
    readonly code: PublicAiErrorCode,
    message: string,
  ) {
    super(message)
  }
}

const HTTPS_CODE: Record<PublicAiErrorCode, FunctionsErrorCode> = {
  AUTH_REQUIRED: 'unauthenticated',
  INVALID_REQUEST: 'invalid-argument',
  CREDENTIAL_NOT_FOUND: 'not-found',
  CREDENTIAL_INVALID: 'failed-precondition',
  CREDENTIAL_NOT_ACTIVE: 'failed-precondition',
  UNSUPPORTED_PROVIDER: 'invalid-argument',
  UNSUPPORTED_MODEL: 'invalid-argument',
  RATE_LIMITED: 'resource-exhausted',
  TOO_MANY_CONCURRENT_STREAMS: 'resource-exhausted',
  PROVIDER_AUTH_FAILED: 'failed-precondition',
  PROVIDER_RATE_LIMITED: 'resource-exhausted',
  PROVIDER_UNAVAILABLE: 'unavailable',
  INTERNAL: 'internal',
}

/// Everything unexpected becomes INTERNAL with a fixed message; only
/// deliberate PublicErrors carry their own words to the client.
export function toHttpsError(error: unknown): HttpsError {
  if (error instanceof HttpsError) return error
  const publicError =
    error instanceof PublicError ? error : new PublicError('INTERNAL', 'Something went wrong on our side.')
  return new HttpsError(HTTPS_CODE[publicError.code], publicError.message, { code: publicError.code })
}
