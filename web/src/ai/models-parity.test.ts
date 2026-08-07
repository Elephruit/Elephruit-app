/// The picker's models and the server's allowlist live in different
/// packages on purpose (no cross-package imports in shipped code). This
/// test is the tripwire: a model offered here but absent or disabled in the
/// catalog would fail every request with UNSUPPORTED_MODEL, so the build
/// should fail first.

import { describe, expect, it } from 'vitest'
import { MODEL_CATALOG } from '../../functions/src/providers/model-catalog'
import { AI_MODELS, DEFAULT_AI_MODEL } from './settings'

describe('model catalog parity', () => {
  it('every model the picker offers is enabled in the server catalog', () => {
    const enabled = new Set(MODEL_CATALOG.filter((model) => model.enabled).map((model) => model.id))
    for (const choice of AI_MODELS) {
      expect(enabled, `picker offers ${choice.id} but the server catalog does not enable it`).toContain(choice.id)
    }
  })

  it('the default model is one the server will accept', () => {
    expect(MODEL_CATALOG.some((model) => model.id === DEFAULT_AI_MODEL && model.enabled)).toBe(true)
  })

  it('all cataloged models belong to the one supported provider', () => {
    for (const model of MODEL_CATALOG) {
      expect(model.provider).toBe('anthropic')
    }
  })
})
