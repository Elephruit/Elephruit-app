/// The Anthropic adapter. The SDK talks to its fixed official endpoint; the
/// key exists only inside the per-request client; the stream is folded into
/// text deltas and a normalized outcome. Errors leave here as public codes —
/// never provider bodies, headers, or request echoes.

import Anthropic from '@anthropic-ai/sdk'
import { PublicError } from '../log/errors.js'
import { StreamCancelled, type NormalizedRequest, type ProviderAdapter, type StreamOutcome } from './adapter.js'
import { verifyAnthropicKey } from './verify.js'

const STREAM_TIMEOUT_MS = 240_000

/// Structured outputs on the streaming path ride a beta flag; the SDK's own
/// beta helpers send exactly this value. Sent only when a format is present.
const STRUCTURED_OUTPUTS_BETA = 'structured-outputs-2025-12-15'

/// Provider-neutral blocks → Anthropic content blocks. Only the three shapes
/// the gateway schema admits can arrive; anything else is unrepresentable.
/// Filenames and payloads are never logged on any path out of here.
function toAnthropicContent(
  content: NormalizedRequest['messages'][number]['content'],
): Anthropic.MessageParam['content'] {
  if (typeof content === 'string') return content
  return content.map((block): Anthropic.ContentBlockParam => {
    switch (block.type) {
      case 'text':
        return { type: 'text', text: block.text }
      case 'image':
        return { type: 'image', source: { type: 'base64', media_type: block.mimeType, data: block.data } }
      case 'document':
        return {
          type: 'document',
          source: { type: 'base64', media_type: 'application/pdf', data: block.data },
          ...(block.name ? { title: block.name } : {}),
        }
    }
  })
}

function buildParams(request: NormalizedRequest): Anthropic.MessageStreamParams {
  const params: Anthropic.MessageStreamParams = {
    model: request.model,
    max_tokens: request.maxTokens,
    messages: request.messages.map((message) => ({ role: message.role, content: toAnthropicContent(message.content) })),
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
  const publicError = classifyAnthropicError(error)
  if (publicError instanceof PublicError && error instanceof Anthropic.APIError) {
    // Log-only diagnostics: upstream status and the API's own complaint,
    // truncated. These describe request shape, never prompts or keys, and
    // toHttpsError never sends them to the client.
    publicError.providerStatus = typeof error.status === 'number' ? error.status : undefined
    publicError.providerNote = String(error.message ?? '').slice(0, 200)
  }
  return publicError
}

function classifyAnthropicError(error: unknown): Error {
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
      const stream = client.messages.stream(buildParams(request), {
        signal,
        ...(request.outputFormat ? { headers: { 'anthropic-beta': STRUCTURED_OUTPUTS_BETA } } : {}),
      })
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
