/// The server-side model allowlist — the only model ids the gateway will
/// forward, whatever the browser asks for. Deliberately a dependency-free
/// module: the web package's parity test imports this file directly to pin
/// its own picker against it, so it must not drag SDK imports across the
/// package boundary.
///
/// Growing this list is a deliberate act (add the model, test it, ship),
/// never an automatic passthrough of whatever a provider exposes.

export interface ModelDefinition {
  id: string
  provider: 'anthropic' | 'openai' | 'google'
  displayName: string
  enabled: boolean
  supportsImages: boolean
  supportsDocuments: boolean
}

export const MODEL_CATALOG: ModelDefinition[] = [
  { id: 'claude-opus-5', provider: 'anthropic', displayName: 'Claude Opus 5', enabled: true, supportsImages: true, supportsDocuments: true },
  { id: 'claude-sonnet-5', provider: 'anthropic', displayName: 'Claude Sonnet 5', enabled: true, supportsImages: true, supportsDocuments: true },
  { id: 'claude-haiku-4-5', provider: 'anthropic', displayName: 'Claude Haiku 4.5', enabled: true, supportsImages: true, supportsDocuments: true },
  { id: 'gpt-5.6-luna', provider: 'openai', displayName: 'GPT-5.6 Luna', enabled: true, supportsImages: true, supportsDocuments: true },
  { id: 'gpt-5-nano', provider: 'openai', displayName: 'GPT-5 Nano', enabled: true, supportsImages: true, supportsDocuments: true },
  { id: 'gemini-3.6-flash', provider: 'google', displayName: 'Gemini 3.6 Flash', enabled: true, supportsImages: true, supportsDocuments: true },
  { id: 'gemini-3.5-flash-lite', provider: 'google', displayName: 'Gemini 3.5 Flash-Lite', enabled: true, supportsImages: true, supportsDocuments: true },
]
