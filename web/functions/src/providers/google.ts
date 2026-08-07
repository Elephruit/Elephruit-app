/// Google Gemini Interactions API adapter. Interactions are explicitly
/// stateless and never persisted at Google; content and streamed events are
/// translated at this boundary so the gateway stays provider-neutral.

import { ApiError, GoogleGenAI } from '@google/genai'
import { PublicError } from '../log/errors.js'
import { StreamCancelled, type NormalizedRequest, type ProviderAdapter, type StreamOutcome } from './adapter.js'
import type { KeyVerification } from './types.js'

const STREAM_TIMEOUT_MS = 240_000
type GeminiContent =
  | { type: 'text'; text: string }
  | { type: 'image'; data: string; mime_type: string }
  | { type: 'document'; data: string; mime_type: 'application/pdf' }

function toGeminiContent(content: NormalizedRequest['messages'][number]['content']): string | GeminiContent[] {
  if (typeof content === 'string') return content
  return content.map((block): GeminiContent => {
    switch (block.type) {
      case 'text':
        return { type: 'text', text: block.text }
      case 'image':
        return { type: 'image', data: block.data, mime_type: block.mimeType }
      case 'document':
        return { type: 'document', data: block.data, mime_type: 'application/pdf' }
    }
  })
}

export function buildGoogleParams(request: NormalizedRequest) {
  return {
    model: request.model,
    input: request.messages.map((message) => ({
      role: message.role === 'assistant' ? 'model' : 'user',
      content: toGeminiContent(message.content),
    })),
    system_instruction: request.system ?? undefined,
    store: false,
    stream: true as const,
    generation_config: {
      max_output_tokens: request.maxTokens,
      ...(request.effort ? { thinking_level: request.effort } : {}),
    },
    ...(request.outputFormat
      ? {
          response_format: {
            type: 'text' as const,
            mime_type: 'application/json' as const,
            schema: request.outputFormat.schema,
          },
        }
      : {}),
  }
}

function classifyGoogleError(error: unknown): Error {
  if (error instanceof ApiError) {
    if (error.status === 401 || error.status === 403) {
      return new PublicError('PROVIDER_AUTH_FAILED', 'The provider rejected this key. Verify or replace it in Settings.')
    }
    if (error.status === 429) {
      return new PublicError('PROVIDER_RATE_LIMITED', 'The provider is rate-limiting right now — try again in a moment.')
    }
    if (error.status === 400 || error.status === 404 || error.status === 422) {
      return new PublicError('INVALID_REQUEST', 'The provider rejected the request shape.')
    }
    if (error.status >= 500) {
      return new PublicError('PROVIDER_UNAVAILABLE', 'The provider could not be reached. Nothing was lost.')
    }
  }
  return new PublicError('PROVIDER_UNAVAILABLE', 'The provider returned an unexpected error. Try again.')
}

export async function verifyGoogleKey(apiKey: string): Promise<KeyVerification> {
  const client = new GoogleGenAI({ apiKey })
  try {
    const models = await client.models.list({ config: { pageSize: 1 } })
    for await (const _model of models) break
    return { outcome: 'valid' }
  } catch (error) {
    if (error instanceof ApiError && (error.status === 401 || error.status === 403)) {
      return { outcome: 'invalid', reason: 'unauthorized' }
    }
    if (error instanceof ApiError && error.status === 429) return { outcome: 'inconclusive', reason: 'rate_limited' }
    if (!(error instanceof ApiError)) return { outcome: 'inconclusive', reason: 'network' }
    return { outcome: 'inconclusive', reason: 'provider_unavailable' }
  }
}

export const googleAdapter: ProviderAdapter = {
  provider: 'google',
  verifyKey: verifyGoogleKey,

  async streamMessage(apiKey, request, signal, onText): Promise<StreamOutcome> {
    const client = new GoogleGenAI({ apiKey })
    let usage: { total_input_tokens?: number; total_output_tokens?: number } | null = null
    try {
      const stream = await client.interactions.create(buildGoogleParams(request), {
        signal,
        timeout_ms: STREAM_TIMEOUT_MS,
      })
      for await (const event of stream) {
        if (event.event_type === 'step.delta' && event.delta.type === 'text') {
          await onText(event.delta.text)
        }
        if (event.event_type === 'interaction.completed') usage = event.interaction.usage ?? null
      }
      return {
        stopReason: 'end_turn',
        usage: {
          inputTokens: usage?.total_input_tokens ?? null,
          outputTokens: usage?.total_output_tokens ?? null,
        },
      }
    } catch (error) {
      if (signal.aborted) throw new StreamCancelled()
      throw classifyGoogleError(error)
    }
  },
}
