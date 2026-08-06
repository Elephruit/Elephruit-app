/// The adapter contract: fixed endpoint, fixed headers, key set only at
/// server-side client construction, everything upstream normalized before it
/// crosses back. One adapter today; the registry keys by provider so more
/// slot in without touching the gateway.

import type { GatewayStopReason } from '../gateway/events.js'
import type { KeyVerification, ProviderId } from './types.js'

export interface NormalizedRequest {
  model: string
  system: string | null
  messages: Array<{ role: 'user' | 'assistant'; content: string }>
  maxTokens: number
  effort: 'low' | 'medium' | 'high' | null
  /// Client-derived JSON-schema output format, forwarded opaquely.
  outputFormat: Record<string, unknown> | null
}

export interface StreamOutcome {
  stopReason: GatewayStopReason
  usage: { inputTokens: number | null; outputTokens: number | null }
  adapter?: 'fake'
}

/// Thrown when the client went away and the upstream call was aborted —
/// not an error to report, just a stream with nobody listening.
export class StreamCancelled extends Error {
  constructor() {
    super('stream cancelled by client disconnect')
  }
}

export interface ProviderAdapter {
  provider: ProviderId
  verifyKey(apiKey: string): Promise<KeyVerification>
  streamMessage(
    apiKey: string,
    request: NormalizedRequest,
    signal: AbortSignal,
    onText: (text: string) => Promise<void> | void,
  ): Promise<StreamOutcome>
}
