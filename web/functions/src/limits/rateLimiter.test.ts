import { describe, expect, it } from 'vitest'
import { counterDocId, windowStart } from './rateLimiter.js'

describe('windowStart', () => {
  it('floors to the window boundary', () => {
    expect(windowStart(3_600_000, 3600)).toBe(3600)
    expect(windowStart(3_599_999, 3600)).toBe(0)
    expect(windowStart(7_200_000, 3600)).toBe(7200)
  })

  it('rolls over between adjacent windows', () => {
    const windowSeconds = 60
    const inWindow = windowStart(119_999, windowSeconds)
    const nextWindow = windowStart(120_000, windowSeconds)
    expect(inWindow).toBe(60)
    expect(nextWindow).toBe(120)
  })
})

describe('counterDocId', () => {
  it('is stable per (uid, operation, window)', () => {
    expect(counterDocId('alice', 'stream_start', 7200)).toBe('c_alice_stream_start_7200')
  })
})
