import { describe, expect, it } from 'vitest'
import { createLogger, pickSafeFields, type LogFields } from './logger.js'

describe('pickSafeFields', () => {
  it('keeps only the allowlist — unknown fields are dropped, not masked', () => {
    const fields: LogFields = {
      uid: 'alice',
      credentialId: 'cred-1',
      apiKey: 'sk-ant-real-key-material',
      authorization: 'Bearer abc',
      ciphertext: 'AAAA',
      body: { messages: ['secret prompt'] },
      durationMs: 42,
    }
    expect(pickSafeFields(fields)).toEqual({ uid: 'alice', credentialId: 'cred-1', durationMs: 42 })
  })

  it('drops allowlisted fields carrying non-primitive values', () => {
    expect(pickSafeFields({ uid: { nested: 'object' } as unknown as string })).toEqual({})
  })
})

describe('createLogger', () => {
  it('never hands unlisted fields to the sink', () => {
    const seen: unknown[] = []
    const sink = {
      info: (message: string, payload?: unknown) => seen.push([message, payload]),
      warn: () => {},
      error: () => {},
    }
    const logger = createLogger(sink)
    logger.info('credential_add', { uid: 'alice', apiKey: 'sk-ant-should-never-appear' })
    expect(JSON.stringify(seen)).not.toContain('sk-ant-should-never-appear')
    expect(seen).toEqual([['credential_add', { uid: 'alice' }]])
  })
})
