/// The browser's side of the AI gateway. What used to be a direct SDK call
/// to api.anthropic.com is now a streaming callable: the request carries a
/// credential id — never a key — plus model, messages, and bounded settings;
/// the server decrypts, calls the provider, and streams normalized text
/// deltas back. The wire types here are a verbatim copy of
/// functions/src/gateway/events.ts, pinned by a parity test.

import { httpsCallable } from 'firebase/functions'
import { z } from 'zod'
import { functions } from '../data/firebase'

export type AIProvider = 'anthropic' | 'openai' | 'google'

/// Provider-neutral content blocks. Text is what it always was; image and
/// document carry base64 payloads of *processed* attachments — re-encoded
/// images, original PDFs only when vision is required — never arbitrary raw
/// files. The server re-validates MIME types, counts, and sizes regardless.
export type GatewayContentBlock =
  | { type: 'text'; text: string }
  | { type: 'image'; mimeType: 'image/jpeg' | 'image/png' | 'image/webp'; data: string }
  | { type: 'document'; mimeType: 'application/pdf'; data: string; name?: string }

export type GatewayMessageContent = string | GatewayContentBlock[]

export interface GatewayRequest {
  credentialId: string
  provider: AIProvider
  model: string
  messages: Array<{ role: 'user' | 'assistant'; content: GatewayMessageContent }>
  system?: string
  maxTokens?: number
  effort?: 'low' | 'medium' | 'high'
  outputFormat?: Record<string, unknown>
}

export interface GatewayChunk {
  type: 'text_delta'
  text: string
}

export type GatewayStopReason = 'end_turn' | 'max_tokens' | 'refusal' | 'other'

export interface GatewayFinal {
  stopReason: GatewayStopReason
  usage: {
    inputTokens: number | null
    outputTokens: number | null
  }
  requestId: string
  adapter?: 'fake'
}

export type GatewayErrorCode =
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
  | 'UNSUPPORTED_ATTACHMENT'
  | 'PAYLOAD_TOO_LARGE'
  | 'ATTACHMENT_PROCESSING_FAILED'
  | 'INTERNAL'
  | 'STREAM_TIMEOUT'
  | 'UNKNOWN'

export class GatewayError extends Error {
  readonly code: GatewayErrorCode
  readonly recoverable: boolean

  constructor(code: GatewayErrorCode, message: string, recoverable: boolean) {
    super(message)
    this.code = code
    this.recoverable = recoverable
  }
}

/// Curated copy per public code, matching the app's existing error tone.
/// recoverable=false means "go fix something in Settings", true means
/// "trying again may just work".
const FRIENDLY: Record<Exclude<GatewayErrorCode, 'STREAM_TIMEOUT' | 'UNKNOWN'>, { message: string; recoverable: boolean }> = {
  AUTH_REQUIRED: { message: 'Sign in again to use AI features.', recoverable: false },
  INVALID_REQUEST: { message: 'The request was rejected. Try again; if it persists, reload.', recoverable: true },
  CREDENTIAL_NOT_FOUND: { message: 'That stored key is gone. Link a key in Settings.', recoverable: false },
  CREDENTIAL_INVALID: {
    message: 'The provider rejected this key. Check it, or create a fresh one in the provider console.',
    recoverable: false,
  },
  CREDENTIAL_NOT_ACTIVE: { message: 'This credential was revoked. Add a fresh key in Settings.', recoverable: false },
  UNSUPPORTED_PROVIDER: { message: 'That provider is not available here.', recoverable: false },
  UNSUPPORTED_MODEL: { message: 'That model is not available. Pick one from the model list.', recoverable: true },
  RATE_LIMITED: { message: 'Too many requests for now — try again in a minute.', recoverable: true },
  TOO_MANY_CONCURRENT_STREAMS: {
    message: 'Another AI request is still running — let it finish first.',
    recoverable: true,
  },
  PROVIDER_AUTH_FAILED: {
    message: 'Your key was not accepted by the provider. Verify or replace it in Settings.',
    recoverable: false,
  },
  PROVIDER_RATE_LIMITED: { message: 'The API is rate-limiting right now — try again in a moment.', recoverable: true },
  PROVIDER_UNAVAILABLE: { message: 'Could not reach the provider. Nothing was lost.', recoverable: true },
  UNSUPPORTED_ATTACHMENT: {
    message: 'The selected model cannot read these files. Choose a vision-capable model in Settings.',
    recoverable: false,
  },
  PAYLOAD_TOO_LARGE: {
    message: 'These files are too large to send together. Remove one and try again.',
    recoverable: true,
  },
  ATTACHMENT_PROCESSING_FAILED: {
    message: 'The provider could not process one of the files. Try removing it.',
    recoverable: true,
  },
  INTERNAL: { message: 'Something went wrong on our side. Try again.', recoverable: true },
}

export function toGatewayError(error: unknown): GatewayError {
  if (error instanceof GatewayError) return error
  const details = (error as { details?: { code?: unknown } } | null | undefined)?.details
  const code = typeof details?.code === 'string' ? details.code : null
  if (code && code in FRIENDLY) {
    const friendly = FRIENDLY[code as keyof typeof FRIENDLY]
    return new GatewayError(code as GatewayErrorCode, friendly.message, friendly.recoverable)
  }
  return new GatewayError('UNKNOWN', 'Could not reach the AI gateway. Nothing was lost.', true)
}

export interface AiTaskResult {
  text: string
  final: GatewayFinal
}

/// Convert an app-owned zod proposal schema into the provider-neutral wire
/// format. Adapters translate these three fields into their SDK vocabulary.
export function zodOutputFormat(name: string, schema: z.ZodType): Record<string, unknown> {
  return {
    type: 'json_schema',
    name,
    schema: z.toJSONSchema(schema),
  }
}

interface StreamSource {
  stream: AsyncIterable<GatewayChunk>
  data: Promise<GatewayFinal>
}

export function streamAiTask(request: GatewayRequest, options: { signal?: AbortSignal } = {}): Promise<StreamSource> {
  const callable = httpsCallable<GatewayRequest, GatewayFinal, GatewayChunk>(functions, 'streamAiResponse')
  return callable.stream(request, options.signal ? { signal: options.signal } : {})
}

/// Folds a stream into its full text and final result. Exported separately
/// from runAiTask so it can be tested against plain async iterables.
export async function collectStream(
  source: StreamSource,
  options: { onDelta?: (text: string) => void; resetWatchdog?: () => void } = {},
): Promise<AiTaskResult> {
  // On failure both the iterable and the data promise reject with the same
  // error; the iterable's is the one surfaced, so mark the twin handled or
  // every gateway failure also fires an unhandled-rejection event.
  source.data.catch(() => {})
  let text = ''
  try {
    for await (const chunk of source.stream) {
      options.resetWatchdog?.()
      if (chunk?.type === 'text_delta' && typeof chunk.text === 'string') {
        text += chunk.text
        options.onDelta?.(chunk.text)
      }
    }
    return { text, final: await source.data }
  } catch (error) {
    throw toGatewayError(error)
  }
}

export const DEFAULT_SILENCE_TIMEOUT_MS = 120_000

/// One AI task, end to end. Callable streams expose no timeout option — only
/// an abort signal — so a silence watchdog stands in: any delta resets it,
/// and a stream that goes quiet is aborted rather than left hanging until
/// the server's 300s ceiling.
export async function runAiTask(
  request: GatewayRequest,
  options: { onDelta?: (text: string) => void; silenceTimeoutMs?: number } = {},
): Promise<AiTaskResult> {
  const controller = new AbortController()
  const timeoutMs = options.silenceTimeoutMs ?? DEFAULT_SILENCE_TIMEOUT_MS
  let timedOut = false
  let timer = setTimeout(onSilence, timeoutMs)

  function onSilence() {
    timedOut = true
    controller.abort()
  }

  try {
    const source = await streamAiTask(request, { signal: controller.signal })
    return await collectStream(source, {
      onDelta: options.onDelta,
      resetWatchdog: () => {
        clearTimeout(timer)
        timer = setTimeout(onSilence, timeoutMs)
      },
    })
  } catch (error) {
    if (timedOut) {
      throw new GatewayError('STREAM_TIMEOUT', 'The stream went quiet and was stopped. Try again.', true)
    }
    throw toGatewayError(error)
  } finally {
    clearTimeout(timer)
  }
}
