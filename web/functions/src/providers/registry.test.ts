import { describe, expect, it } from 'vitest'
import { PublicError } from '../log/errors.js'
import { anthropicAdapter } from './anthropic.js'
import { fakeAdapter } from './fake.js'
import { buildAdapterRegistry, requireEnabledModel } from './registry.js'

const baseConfig = { isEmulator: false, kmsKeyName: null, devEncryptionKey: null, useFakeAdapter: false }

describe('buildAdapterRegistry', () => {
  it('serves the real adapter by default', () => {
    expect(buildAdapterRegistry({ ...baseConfig }).anthropic).toBe(anthropicAdapter)
  })

  it('serves the fake only when BOTH the flag and the emulator are present', () => {
    expect(buildAdapterRegistry({ ...baseConfig, useFakeAdapter: true }).anthropic).toBe(anthropicAdapter)
    expect(buildAdapterRegistry({ ...baseConfig, isEmulator: true }).anthropic).toBe(anthropicAdapter)
    expect(buildAdapterRegistry({ ...baseConfig, useFakeAdapter: true, isEmulator: true }).anthropic).toBe(fakeAdapter)
  })
})

describe('requireEnabledModel', () => {
  it('accepts a cataloged model for its provider', () => {
    expect(requireEnabledModel('anthropic', 'claude-opus-5').id).toBe('claude-opus-5')
  })

  it('rejects unknown models', () => {
    expect(() => requireEnabledModel('anthropic', 'gpt-4o')).toThrow(PublicError)
    expect(() => requireEnabledModel('anthropic', 'claude-2')).toThrow(PublicError)
  })
})
