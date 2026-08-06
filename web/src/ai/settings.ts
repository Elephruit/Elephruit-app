/// AI browser preferences. The model choice stays in localStorage — it is a
/// preference, not a secret, and the server enforces its own allowlist per
/// request. The API key no longer lives here at all: custody moved
/// server-side (see ai/credentials.ts). What remains of key storage is the
/// legacy slot from the earlier localStorage era, kept only so Settings can
/// offer a consented migration — link it to your account or discard it —
/// and then clear it.

const LEGACY_KEY_STORAGE = 'elephruit.ai.apiKey'
const MODEL_STORAGE = 'elephruit.ai.model'

export interface AIModelChoice {
  id: string
  label: string
}

export const AI_MODELS: AIModelChoice[] = [
  { id: 'claude-opus-5', label: 'Claude Opus 5 — the default' },
  { id: 'claude-sonnet-5', label: 'Claude Sonnet 5 — faster, cheaper' },
  { id: 'claude-haiku-4-5', label: 'Claude Haiku 4.5 — fastest, cheapest' },
]

export const DEFAULT_AI_MODEL = AI_MODELS[0].id

export function storedModel(): string {
  return localStorage.getItem(MODEL_STORAGE) ?? DEFAULT_AI_MODEL
}

export function setModel(model: string): void {
  localStorage.setItem(MODEL_STORAGE, model)
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
