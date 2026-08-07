/// Structured logging with an allowlist instead of a redaction list: fields
/// not explicitly known-safe never reach the log, so a future caller cannot
/// leak a key by logging one argument too many. Nothing here ever logs
/// request bodies, headers, prompts, plaintext, or ciphertext.

import { logger as functionsLogger } from 'firebase-functions'

const SAFE_FIELDS = [
  'requestId',
  'uid',
  'credentialId',
  'provider',
  'model',
  'operation',
  'durationMs',
  'status',
  'outcome',
  'normalizedErrorCode',
  // Upstream diagnostics from PublicError: HTTP status and the provider's
  // truncated complaint about request shape — never prompts, never keys.
  'providerStatus',
  'providerNote',
] as const

type SafeField = (typeof SAFE_FIELDS)[number]
export type LogFields = Partial<Record<SafeField, string | number>> & Record<string, unknown>

export interface Logger {
  info(operation: string, fields?: LogFields): void
  warn(operation: string, fields?: LogFields): void
  error(operation: string, fields?: LogFields): void
}

/// Exported for tests: everything outside the allowlist is dropped, not
/// masked — absent beats redacted.
export function pickSafeFields(fields: LogFields = {}): Record<string, string | number> {
  const safe: Record<string, string | number> = {}
  for (const field of SAFE_FIELDS) {
    const value = fields[field]
    if (typeof value === 'string' || typeof value === 'number') {
      safe[field] = value
    }
  }
  return safe
}

export function createLogger(sink: Pick<Logger, 'info' | 'warn' | 'error'> = functionsLogger): Logger {
  return {
    info: (operation, fields) => sink.info(operation, pickSafeFields(fields)),
    warn: (operation, fields) => sink.warn(operation, pickSafeFields(fields)),
    error: (operation, fields) => sink.error(operation, pickSafeFields(fields)),
  }
}
