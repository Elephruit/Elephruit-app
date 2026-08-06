/// AI capture settings. The API key is the user's own, pasted at runtime, and
/// lives in localStorage only — never Firestore (it would sync), never .env
/// (it would end up in a build), never logged. Clearing it forgets it.

const KEY_STORAGE = 'elephruit.ai.apiKey'
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

export function storedAPIKey(): string | null {
  const key = localStorage.getItem(KEY_STORAGE)
  return key && key.trim() ? key : null
}

export function setAPIKey(key: string): void {
  localStorage.setItem(KEY_STORAGE, key.trim())
}

export function clearAPIKey(): void {
  localStorage.removeItem(KEY_STORAGE)
}

export function storedModel(): string {
  return localStorage.getItem(MODEL_STORAGE) ?? DEFAULT_AI_MODEL
}

export function setModel(model: string): void {
  localStorage.setItem(MODEL_STORAGE, model)
}

export function aiCaptureReady(): boolean {
  return storedAPIKey() !== null
}
