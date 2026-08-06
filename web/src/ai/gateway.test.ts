/// collectStream against plain async iterables, the error mapping table,
/// and the parity pin: the wire types here must stay mutually assignable
/// with functions/src/gateway/events.ts — the compiler enforces it through
/// the annotated round-trips below, so a drift on either side fails
/// npm run build / test typechecking.

import { describe, expect, it } from 'vitest'
import type {
  GatewayChunk as ServerGatewayChunk,
  GatewayFinal as ServerGatewayFinal,
} from '../../functions/src/gateway/events'
import { GatewayError, collectStream, toGatewayError, type GatewayChunk, type GatewayFinal } from './gateway'

async function* chunks(parts: string[], failWith?: unknown): AsyncGenerator<GatewayChunk> {
  for (const part of parts) {
    yield { type: 'text_delta', text: part }
  }
  if (failWith) throw failWith
}

const final: GatewayFinal = {
  stopReason: 'end_turn',
  usage: { inputTokens: 10, outputTokens: 5 },
  requestId: 'req-1',
}

describe('collectStream', () => {
  it('concatenates deltas, reports each one, and returns the final result', async () => {
    const seen: string[] = []
    const result = await collectStream(
      { stream: chunks(['Hel', 'lo']), data: Promise.resolve(final) },
      { onDelta: (text) => seen.push(text) },
    )
    expect(result.text).toBe('Hello')
    expect(result.final).toEqual(final)
    expect(seen).toEqual(['Hel', 'lo'])
  })

  it('maps a mid-stream failure to a GatewayError with the public code', async () => {
    const failure = Object.assign(new Error('resource-exhausted'), {
      details: { code: 'PROVIDER_RATE_LIMITED' },
    })
    const attempt = collectStream({ stream: chunks(['a'], failure), data: Promise.resolve(final) })
    await expect(attempt).rejects.toBeInstanceOf(GatewayError)
    await expect(attempt).rejects.toMatchObject({ code: 'PROVIDER_RATE_LIMITED', recoverable: true })
  })
})

describe('toGatewayError', () => {
  it('maps credential problems to non-recoverable settings guidance', () => {
    const error = toGatewayError(Object.assign(new Error('x'), { details: { code: 'CREDENTIAL_NOT_FOUND' } }))
    expect(error.code).toBe('CREDENTIAL_NOT_FOUND')
    expect(error.recoverable).toBe(false)
    expect(error.message).toContain('Settings')
  })

  it('maps provider auth failure to key guidance', () => {
    const error = toGatewayError(Object.assign(new Error('x'), { details: { code: 'PROVIDER_AUTH_FAILED' } }))
    expect(error.recoverable).toBe(false)
    expect(error.message).toContain('key')
  })

  it('treats unknown failures as retriable without inventing details', () => {
    const error = toGatewayError(new Error('socket hang up'))
    expect(error.code).toBe('UNKNOWN')
    expect(error.recoverable).toBe(true)
    expect(error.message).not.toContain('socket')
  })

  it('passes existing GatewayErrors through unchanged', () => {
    const original = new GatewayError('RATE_LIMITED', 'slow down', true)
    expect(toGatewayError(original)).toBe(original)
  })
})

describe('wire-type parity with the server', () => {
  it('chunk and final types are mutually assignable with functions/src/gateway/events.ts', () => {
    const chunk = { type: 'text_delta', text: 'x' } satisfies GatewayChunk
    const serverChunk: ServerGatewayChunk = chunk
    const chunkRoundTrip: GatewayChunk = serverChunk
    expect(chunkRoundTrip).toEqual(chunk)

    const fakeTagged = { ...final, adapter: 'fake' } satisfies GatewayFinal
    const serverFinal: ServerGatewayFinal = fakeTagged
    const finalRoundTrip: GatewayFinal = serverFinal
    expect(finalRoundTrip).toEqual(fakeTagged)
  })
})
