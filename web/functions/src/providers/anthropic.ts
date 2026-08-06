/// The Anthropic adapter. The SDK talks to its fixed official endpoint; the
/// key exists only inside the per-request client; the stream is folded into
/// text deltas and a normalized outcome. Errors leave here as public codes —
/// never provider bodies, headers, or request echoes.

import Anthropic from '@anthropic-ai/sdk'
import { PublicError } from '../log/errors.js'
import { StreamCancelled, type NormalizedRequest, type ProviderAdapter, type StreamOutcome } from './adapter.js'
import { verifyAnthropicKey } from './verify.js'

const STREAM_TIMEOUT_MS = 240_000

function buildParams(request: NormalizedRequest): Anthropic.MessageStreamParams {
  const params: Anthropic.MessageStreamParams = {
    model: request.model,
    max_tokens: request.maxTokens,
    messages: request.messages,
  }
  if (request.system) params.system = request.system
  if (request.effort || request.outputFormat) {
    params.output_config = {
      ...(request.effort ? { effort: request.effort } : {}),
      // Client-derived JSON schema, validated for size and coarse shape at
      // the gateway; the SDK type is narrower than "arbitrary schema", hence
      // the deliberate cast.
      ...(request.outputFormat ? { format: request.outputFormat as never } : {}),
    }
  }
  return params
}

export function normalizeAnthropicError(error: unknown): Error {
  if (error instanceof Anthropic.APIUserAbortError) return new StreamCancelled()
  if (error instanceof Anthropic.AuthenticationError || error instanceof Anthropic.PermissionDeniedError) {
    return new PublicError('PROVIDER_AUTH_FAILED', 'The provider rejected this key. Verify or replace it in Settings.')
  }
  if (error instanceof Anthropic.RateLimitError) {
    return new PublicError('PROVIDER_RATE_LIMITED', 'The provider is rate-limiting right now — try again in a moment.')
  }
  if (error instanceof Anthropic.BadRequestError) {
    return new PublicError('INVALID_REQUEST', 'The provider rejected the request shape.')
  }
  if (error instanceof Anthropic.APIConnectionError || error instanceof Anthropic.InternalServerError) {
    return new PublicError('PROVIDER_UNAVAILABLE', 'The provider could not be reached. Nothing was lost.')
  }
  return new PublicError('PROVIDER_UNAVAILABLE', 'The provider returned an unexpected error. Try again.')
}

export const anthropicAdapter: ProviderAdapter = {
  provider: 'anthropic',
  verifyKey: verifyAnthropicKey,

  async streamMessage(apiKey, request, signal, onText): Promise<StreamOutcome> {
    const client = new Anthropic({ apiKey, maxRetries: 0, timeout: STREAM_TIMEOUT_MS })
    try {
      const stream = client.messages.stream(buildParams(request), { signal })
      for await (const event of stream) {
        if (event.type === 'content_block_delta' && event.delta.type === 'text_delta') {
          await onText(event.delta.text)
        }
      }
      const final = await stream.finalMessage()
      const stopReason =
        final.stop_reason === 'end_turn' || final.stop_reason === 'max_tokens' || final.stop_reason === 'refusal'
          ? final.stop_reason
          : 'other'
      return {
        stopReason,
        usage: {
          inputTokens: final.usage?.input_tokens ?? null,
          outputTokens: final.usage?.output_tokens ?? null,
        },
      }
    } catch (error) {
      if (signal.aborted) throw new StreamCancelled()
      throw normalizeAnthropicError(error)
    }
  },
}
