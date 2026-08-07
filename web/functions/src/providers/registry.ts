/// Static provider registry and model allowlist checks. Adapters are chosen
/// here from configuration — never imported dynamically, never constructed
/// from client input.

import type { RuntimeConfig } from '../config.js'
import { PublicError } from '../log/errors.js'
import type { ProviderAdapter } from './adapter.js'
import { anthropicAdapter } from './anthropic.js'
import { fakeAdapterFor } from './fake.js'
import { googleAdapter } from './google.js'
import { MODEL_CATALOG, type ModelDefinition } from './model-catalog.js'
import { openAIAdapter } from './openai.js'
import type { ProviderId } from './types.js'

export type AdapterRegistry = Record<ProviderId, ProviderAdapter>

export function buildAdapterRegistry(config: RuntimeConfig): AdapterRegistry {
  const useFake = config.useFakeAdapter && config.isEmulator
  return {
    anthropic: useFake ? fakeAdapterFor('anthropic') : anthropicAdapter,
    openai: useFake ? fakeAdapterFor('openai') : openAIAdapter,
    google: useFake ? fakeAdapterFor('google') : googleAdapter,
  }
}

export function requireEnabledModel(provider: ProviderId, modelId: string): ModelDefinition {
  const model = MODEL_CATALOG.find((entry) => entry.id === modelId)
  if (!model || !model.enabled || model.provider !== provider) {
    throw new PublicError('UNSUPPORTED_MODEL', 'That model is not available here. Pick one from the model list.')
  }
  return model
}
