/// AI browser preferences. The model choice stays in localStorage — it is a
/// preference, not a secret, and the server enforces its own allowlist per
/// request. The API key no longer lives here at all: custody moved
/// server-side (see ai/credentials.ts). What remains of key storage is the
/// legacy slot from the earlier localStorage era, kept only so Settings can
/// offer a consented migration — link it to your account or discard it —
/// and then clear it.

import type { AIProvider } from './gateway'

const LEGACY_KEY_STORAGE = 'elephruit.ai.apiKey'
const MODEL_STORAGE = 'elephruit.ai.model'
const SELECTION_STORAGE = 'elephruit.ai.selection.v2'

export interface AIModelChoice {
  id: string
  provider: AIProvider
  label: string
}

export const AI_MODELS: AIModelChoice[] = [
  { id: 'claude-opus-5', provider: 'anthropic', label: 'Claude Opus 5 — the default' },
  { id: 'claude-sonnet-5', provider: 'anthropic', label: 'Claude Sonnet 5 — faster, cheaper' },
  { id: 'claude-haiku-4-5', provider: 'anthropic', label: 'Claude Haiku 4.5 — fastest, cheapest' },
  { id: 'gpt-5.6-luna', provider: 'openai', label: 'GPT-5.6 Luna — the default' },
  { id: 'gpt-5-nano', provider: 'openai', label: 'GPT-5 Nano — compatibility' },
  { id: 'gemini-3.6-flash', provider: 'google', label: 'Gemini 3.6 Flash — the default' },
  { id: 'gemini-3.5-flash-lite', provider: 'google', label: 'Gemini 3.5 Flash-Lite — fastest, cheapest' },
]

export const DEFAULT_AI_MODEL = AI_MODELS[0].id

export interface AISelection {
  provider: AIProvider
  model: string
}

export const DEFAULT_MODEL_BY_PROVIDER: Record<AIProvider, string> = {
  anthropic: 'claude-opus-5',
  openai: 'gpt-5.6-luna',
  google: 'gemini-3.6-flash',
}

export function modelsForProvider(provider: AIProvider): AIModelChoice[] {
  return AI_MODELS.filter((model) => model.provider === provider)
}

function validSelection(value: unknown): AISelection | null {
  if (!value || typeof value !== 'object') return null
  const candidate = value as { provider?: unknown; model?: unknown }
  if (typeof candidate.provider !== 'string' || typeof candidate.model !== 'string') return null
  const model = AI_MODELS.find((entry) => entry.id === candidate.model && entry.provider === candidate.provider)
  return model ? { provider: model.provider, model: model.id } : null
}

export function storedAISelection(): AISelection {
  try {
    const stored = localStorage.getItem(SELECTION_STORAGE)
    const selection = stored ? validSelection(JSON.parse(stored)) : null
    if (selection) return selection
  } catch {
    // Fall through to the legacy model preference.
  }
  const legacyModel = localStorage.getItem(MODEL_STORAGE)
  const legacyChoice = AI_MODELS.find((choice) => choice.id === legacyModel)
  return legacyChoice
    ? { provider: legacyChoice.provider, model: legacyChoice.id }
    : { provider: 'anthropic', model: DEFAULT_AI_MODEL }
}

export function setAISelection(selection: AISelection): void {
  const validated = validSelection(selection)
  if (!validated) return
  localStorage.setItem(SELECTION_STORAGE, JSON.stringify(validated))
  localStorage.removeItem(MODEL_STORAGE)
}

export function storedModel(): string {
  return storedAISelection().model
}

export function setModel(model: string): void {
  const choice = AI_MODELS.find((entry) => entry.id === model)
  if (choice) setAISelection({ provider: choice.provider, model: choice.id })
}

/// The pre-migration key, if this browser still holds one. Read-only except
/// for the explicit clear — nothing auto-uploads it.
export function legacyStoredAPIKey(): string | null {
  const key = localStorage.getItem(LEGACY_KEY_STORAGE)
  return key && key.trim() ? key.trim() : null
}

export function clearLegacyAPIKey(): void {
  localStorage.removeItem(LEGACY_KEY_STORAGE)
}
