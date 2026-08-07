import { beforeEach, describe, expect, it, vi } from 'vitest'
import {
  DEFAULT_MODEL_BY_PROVIDER,
  modelsForProvider,
  setAISelection,
  storedAISelection,
} from './settings'

const values = new Map<string, string>()

beforeEach(() => {
  values.clear()
  vi.stubGlobal('localStorage', {
    getItem: (key: string) => values.get(key) ?? null,
    setItem: (key: string, value: string) => values.set(key, value),
    removeItem: (key: string) => values.delete(key),
  })
})

describe('AI provider selection', () => {
  it('offers Luna and Nano under OpenAI and Gemini models under Google', () => {
    expect(modelsForProvider('openai').map((model) => model.id)).toEqual(['gpt-5.6-luna', 'gpt-5-nano'])
    expect(modelsForProvider('google').map((model) => model.id)).toEqual([
      'gemini-3.6-flash',
      'gemini-3.5-flash-lite',
    ])
  })

  it('persists provider and model as one validated selection', () => {
    setAISelection({ provider: 'openai', model: 'gpt-5-nano' })
    expect(storedAISelection()).toEqual({ provider: 'openai', model: 'gpt-5-nano' })
  })

  it('keeps provider defaults paired with their catalog', () => {
    for (const provider of ['anthropic', 'openai', 'google'] as const) {
      expect(modelsForProvider(provider).map((model) => model.id)).toContain(DEFAULT_MODEL_BY_PROVIDER[provider])
    }
  })
})
