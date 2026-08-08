import { describe, expect, it } from 'vitest'
import { PublicError } from '../log/errors.js'
import { anthropicAdapter } from './anthropic.js'
import { googleAdapter } from './google.js'
import { openAIAdapter } from './openai.js'
import { buildAdapterRegistry, requireEnabledModel } from './registry.js'

const baseConfig = { isEmulator: false, kmsKeyName: null, devEncryptionKey: null, useFakeAdapter: false }

describe('buildAdapterRegistry', () => {
  it('serves the real adapter by default', () => {
    const registry = buildAdapterRegistry({ ...baseConfig })
    expect(registry.anthropic).toBe(anthropicAdapter)
    expect(registry.openai).toBe(openAIAdapter)
    expect(registry.google).toBe(googleAdapter)
  })

  it('serves the fake only when BOTH the flag and the emulator are present', () => {
    expect(buildAdapterRegistry({ ...baseConfig, useFakeAdapter: true }).anthropic).toBe(anthropicAdapter)
    expect(buildAdapterRegistry({ ...baseConfig, isEmulator: true }).anthropic).toBe(anthropicAdapter)
    const registry = buildAdapterRegistry({ ...baseConfig, useFakeAdapter: true, isEmulator: true })
    expect(Object.values(registry).map((adapter) => adapter.provider)).toEqual(['anthropic', 'openai', 'google'])
  })
})

describe('requireEnabledModel', () => {
  it('accepts a cataloged model for its provider', () => {
    expect(requireEnabledModel('anthropic', 'claude-opus-5').id).toBe('claude-opus-5')
    expect(requireEnabledModel('openai', 'gpt-5.6-luna').id).toBe('gpt-5.6-luna')
    expect(requireEnabledModel('google', 'gemini-3.6-flash').id).toBe('gemini-3.6-flash')
  })

  it('rejects unknown models', () => {
    expect(() => requireEnabledModel('anthropic', 'gpt-4o')).toThrow(PublicError)
    expect(() => requireEnabledModel('anthropic', 'claude-2')).toThrow(PublicError)
  })
})
