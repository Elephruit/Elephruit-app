/// The gateway's wire vocabulary — the only shapes the browser ever receives
/// from a stream. Raw provider events, headers, and response objects stop at
/// the adapter; these cross the boundary. The web package keeps a verbatim
/// copy (src/ai/gateway.ts) pinned by a parity test.

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
  /// Present only when the emulator's fake adapter answered — lets smoke
  /// tests assert that no real provider was contacted.
  adapter?: 'fake'
}
