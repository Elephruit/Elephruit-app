/// The gateway itself. Order matters and is deliberate: validate the shape,
/// check the model allowlist, spend the rate budget, resolve the caller's
/// own credential, take a concurrency lease — and only then decrypt and
/// call the fixed adapter. The key exists between decryption and the end of
/// the upstream call, is never logged, and never crosses back to the
/// browser; what crosses back are normalized text deltas and a normalized
/// outcome.

import type { EncryptionService } from '../crypto/encryption.js'
import type { StreamLeases } from '../limits/leases.js'
import { MAX_CONCURRENT_STREAMS, RATE_POLICIES } from '../limits/policies.js'
import type { RateLimiter } from '../limits/rateLimiter.js'
import { PublicError } from '../log/errors.js'
import type { Logger } from '../log/logger.js'
import { StreamCancelled, type NormalizedRequest } from '../providers/adapter.js'
import type { AdapterRegistry } from '../providers/registry.js'
import { requireEnabledModel } from '../providers/registry.js'
import type { CredentialStore } from '../credentials/store.js'
import type { AuditWriter } from '../credentials/types.js'
import type { GatewayChunk, GatewayFinal } from './events.js'
import { GATEWAY_LIMITS, GatewayRequestSchema } from './request.js'

/// Leases outlive the function timeout slightly, so a crashed instance frees
/// its slot by expiry rather than pinning it.
export const STREAM_LEASE_TTL_SECONDS = 330

const USED_STAMP_MIN_INTERVAL_MS = 60 * 60 * 1000

export interface GatewayDeps {
  store: CredentialStore
  encryption: EncryptionService
  adapters: AdapterRegistry
  rateLimiter: RateLimiter
  leases: StreamLeases
  audit: AuditWriter
  log: Logger
  now: () => Date
  newRequestId: () => string
  /// Whether this request's credential_used event lands in the audit trail;
  /// sampled so a chatty day does not become a Firestore write per request.
  sampleUsedEvent: () => boolean
}

export interface StreamSink {
  sendChunk(chunk: GatewayChunk): Promise<unknown>
  signal: AbortSignal
}

export async function handleStreamAiResponse(
  deps: GatewayDeps,
  uid: string,
  rawInput: unknown,
  sink: StreamSink,
): Promise<GatewayFinal> {
  const requestId = deps.newRequestId()
  const parsedInput = GatewayRequestSchema.safeParse(rawInput)
  if (!parsedInput.success) {
    throw new PublicError('INVALID_REQUEST', 'The request was not shaped the way this endpoint expects.')
  }
  const request = parsedInput.data

  const model = requireEnabledModel(request.provider, request.model)

  // The media gate: attachment blocks only travel to models the catalog
  // vouches for. Checked before rate spend so a wrong model costs nothing.
  const hasAttachments = request.messages.some(
    (message) => typeof message.content !== 'string' && message.content.some((block) => block.type !== 'text'),
  )
  if (hasAttachments && !model.supportsAttachments) {
    throw new PublicError(
      'UNSUPPORTED_ATTACHMENT',
      'The selected model cannot read attached files. Choose a vision-capable model.',
    )
  }

  if (!(await deps.rateLimiter.consume(uid, 'stream_start', RATE_POLICIES.streamStart))) {
    throw new PublicError('RATE_LIMITED', 'Too many requests for now. Try again in a minute.')
  }

  const privateDoc = await deps.store.loadPrivate(uid, request.credentialId)
  if (!privateDoc || privateDoc.ownerUid !== uid || privateDoc.provider !== request.provider) {
    throw new PublicError('CREDENTIAL_NOT_FOUND', 'No such credential.')
  }
  const metadata = await deps.store.loadMetadata(uid, request.credentialId)
  if (metadata?.status === 'revoked') {
    throw new PublicError('CREDENTIAL_NOT_ACTIVE', 'This credential was revoked. Add a fresh key in Settings.')
  }

  if (!(await deps.leases.acquire(uid, requestId, MAX_CONCURRENT_STREAMS, STREAM_LEASE_TTL_SECONDS))) {
    throw new PublicError('TOO_MANY_CONCURRENT_STREAMS', 'Too many streams running. Let one finish first.')
  }

  const startedAt = Date.now()
  try {
    const apiKey = await deps.encryption.decrypt(
      { ciphertext: privateDoc.ciphertext, kmsKeyName: privateDoc.kmsKeyName },
      { uid, credentialId: request.credentialId, provider: request.provider },
    )

    const normalized: NormalizedRequest = {
      model: request.model,
      system: request.system ?? null,
      messages: request.messages,
      maxTokens: request.maxTokens ?? GATEWAY_LIMITS.defaultMaxTokens,
      effort: request.effort ?? null,
      // Reduced to exactly the two fields the provider accepts. The SDK's
      // zodOutputFormat carries a client-side parse helper that some
      // serialization paths turn into a literal key the API then rejects
      // ("format.parse: Extra inputs are not permitted") — and whatever
      // else a client ever sends, only type and schema go upstream.
      outputFormat: request.outputFormat
        ? { type: request.outputFormat.type, schema: request.outputFormat.schema }
        : null,
    }

    const adapter = deps.adapters[request.provider]
    const outcome = await adapter.streamMessage(apiKey, normalized, sink.signal, async (text) => {
      await sink.sendChunk({ type: 'text_delta', text })
    })

    stampUsage(deps, uid, request.credentialId, metadata?.lastUsedAt ?? null)
    if (deps.sampleUsedEvent()) {
      void deps
        .audit(uid, { type: 'credential_used', credentialId: request.credentialId, provider: request.provider, requestId })
        .catch(() => {})
    }
    deps.log.info('stream', {
      uid,
      credentialId: request.credentialId,
      provider: request.provider,
      model: request.model,
      requestId,
      durationMs: Date.now() - startedAt,
      status: 'ok',
    })
    return { stopReason: outcome.stopReason, usage: outcome.usage, requestId, ...(outcome.adapter ? { adapter: outcome.adapter } : {}) }
  } catch (error) {
    if (error instanceof StreamCancelled) {
      deps.log.info('stream', {
        uid,
        credentialId: request.credentialId,
        requestId,
        durationMs: Date.now() - startedAt,
        status: 'cancelled',
      })
      return { stopReason: 'other', usage: { inputTokens: null, outputTokens: null }, requestId }
    }
    if (error instanceof PublicError && error.code === 'PROVIDER_AUTH_FAILED') {
      // The provider just told us this key is bad — reflect it so Settings
      // shows the credential needs attention.
      void deps.store
        .updateMetadata(uid, request.credentialId, {
          status: 'invalid',
          verificationErrorCode: 'unauthorized',
          updatedAt: deps.now(),
        })
        .catch(() => {})
    }
    throw error
  } finally {
    await deps.leases.release(uid, requestId).catch(() => {})
  }
}

/// lastUsedAt is UI garnish; one write per hour per credential is plenty.
function stampUsage(deps: GatewayDeps, uid: string, credentialId: string, lastUsedAt: Date | null): void {
  const now = deps.now()
  if (lastUsedAt && now.getTime() - lastUsedAt.getTime() < USED_STAMP_MIN_INTERVAL_MS) return
  void deps.store.updateMetadata(uid, credentialId, { lastUsedAt: now }).catch(() => {})
}
