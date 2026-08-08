/// OpenAI Responses API adapter. The browser never sees this SDK or a raw
/// key; the server builds a fixed, stateless request and normalizes the
/// provider stream into the gateway's tiny text/usage vocabulary.

import OpenAI from 'openai'
import type { ResponseCreateParamsStreaming, ResponseInput, ResponseInputContent } from 'openai/resources/responses/responses'
import { PublicError } from '../log/errors.js'
import { StreamCancelled, type NormalizedRequest, type ProviderAdapter, type StreamOutcome } from './adapter.js'
import type { KeyVerification } from './types.js'

const STREAM_TIMEOUT_MS = 240_000
const VERIFY_TIMEOUT_MS = 10_000

function toOpenAIContent(content: NormalizedRequest['messages'][number]['content']): string | ResponseInputContent[] {
  if (typeof content === 'string') return content
  return content.map((block): ResponseInputContent => {
    switch (block.type) {
      case 'text':
        return { type: 'input_text', text: block.text }
      case 'image':
        return { type: 'input_image', detail: 'auto', image_url: `data:${block.mimeType};base64,${block.data}` }
      case 'document':
        return {
          type: 'input_file',
          file_data: `data:application/pdf;base64,${block.data}`,
          filename: block.name ?? 'document.pdf',
        }
    }
  })
}

export function buildOpenAIParams(request: NormalizedRequest): ResponseCreateParamsStreaming {
  const input: ResponseInput = request.messages.map((message) => ({
    type: 'message',
    role: message.role,
    content: toOpenAIContent(message.content),
  }))
  return {
    model: request.model,
    input,
    instructions: request.system,
    max_output_tokens: request.maxTokens,
    store: false,
    stream: true,
    ...(request.effort ? { reasoning: { effort: request.effort } } : {}),
    ...(request.outputFormat
      ? {
          text: {
            format: {
              type: 'json_schema',
              name: request.outputFormat.name,
              schema: request.outputFormat.schema,
              strict: true,
            },
          },
        }
      : {}),
  }
}

function classifyOpenAIError(error: unknown): Error {
  if (error instanceof OpenAI.APIUserAbortError) return new StreamCancelled()
  if (error instanceof OpenAI.AuthenticationError || error instanceof OpenAI.PermissionDeniedError) {
    return new PublicError('PROVIDER_AUTH_FAILED', 'The provider rejected this key. Verify or replace it in Settings.')
  }
  if (error instanceof OpenAI.RateLimitError) {
    return new PublicError('PROVIDER_RATE_LIMITED', 'The provider is rate-limiting right now — try again in a moment.')
  }
  if (error instanceof OpenAI.BadRequestError) {
    return new PublicError('INVALID_REQUEST', 'The provider rejected the request shape.')
  }
  if (error instanceof OpenAI.APIConnectionError || error instanceof OpenAI.InternalServerError) {
    return new PublicError('PROVIDER_UNAVAILABLE', 'The provider could not be reached. Nothing was lost.')
  }
  return new PublicError('PROVIDER_UNAVAILABLE', 'The provider returned an unexpected error. Try again.')
}

export async function verifyOpenAIKey(apiKey: string): Promise<KeyVerification> {
  const client = new OpenAI({ apiKey, maxRetries: 0, timeout: VERIFY_TIMEOUT_MS })
  try {
    await client.models.list()
    return { outcome: 'valid' }
  } catch (error) {
    if (error instanceof OpenAI.AuthenticationError || error instanceof OpenAI.PermissionDeniedError) {
      return { outcome: 'invalid', reason: 'unauthorized' }
    }
    if (error instanceof OpenAI.RateLimitError) return { outcome: 'inconclusive', reason: 'rate_limited' }
    if (error instanceof OpenAI.APIConnectionError) return { outcome: 'inconclusive', reason: 'network' }
    return { outcome: 'inconclusive', reason: 'provider_unavailable' }
  }
}

export const openAIAdapter: ProviderAdapter = {
  provider: 'openai',
  verifyKey: verifyOpenAIKey,

  async streamMessage(apiKey, request, signal, onText): Promise<StreamOutcome> {
    const client = new OpenAI({ apiKey, maxRetries: 0, timeout: STREAM_TIMEOUT_MS })
    let finalUsage: { input_tokens?: number; output_tokens?: number } | null = null
    let stopReason: StreamOutcome['stopReason'] = 'other'
    let refused = false
    try {
      const stream = await client.responses.create(buildOpenAIParams(request), { signal })
      for await (const event of stream) {
        if (event.type === 'response.output_text.delta') await onText(event.delta)
        if (event.type === 'response.refusal.delta') refused = true
        if (event.type === 'response.completed') {
          finalUsage = event.response.usage ?? null
          stopReason = refused ? 'refusal' : 'end_turn'
        }
        if (event.type === 'response.incomplete') {
          finalUsage = event.response.usage ?? null
          stopReason = event.response.incomplete_details?.reason === 'max_output_tokens' ? 'max_tokens' : 'other'
        }
        if (event.type === 'response.failed') {
          throw new PublicError('PROVIDER_UNAVAILABLE', 'The provider could not complete this request. Nothing was lost.')
        }
      }
      return {
        stopReason,
        usage: {
          inputTokens: finalUsage?.input_tokens ?? null,
          outputTokens: finalUsage?.output_tokens ?? null,
        },
      }
    } catch (error) {
      if (signal.aborted) throw new StreamCancelled()
      if (error instanceof PublicError) throw error
      throw classifyOpenAIError(error)
    }
  },
}
