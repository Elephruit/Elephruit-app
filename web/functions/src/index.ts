/// Composition root for the BYOK backend. Today it exports only the streaming
/// spike: gatewayPing exists to prove, through the emulator, that a streaming
/// callable delivers chunks incrementally rather than buffered. It dies in the
/// commit that lands the real gateway.

import { setGlobalOptions } from 'firebase-functions/v2'
import { onCall } from 'firebase-functions/v2/https'
import { assertStartupInvariants, readConfig } from './config.js'

setGlobalOptions({ region: 'us-central1' })

const config = readConfig()
assertStartupInvariants(config)

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))

interface PingChunk {
  type: 'ping'
  index: number
  sentAt: number
}

export const gatewayPing = onCall<unknown, Promise<object>, PingChunk>(
  { enforceAppCheck: false },
  async (request, response) => {
    const spacingMs = 300
    for (let index = 0; index < 3; index += 1) {
      await response?.sendChunk({ type: 'ping', index, sentAt: Date.now() })
      await sleep(spacingMs)
    }
    return { done: true, chunks: 3, spacingMs, acceptsStreaming: request.acceptsStreaming }
  },
)
