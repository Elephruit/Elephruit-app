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
  provider: 'anthropic'
  displayName: string
  enabled: boolean
  /// Whether the gateway forwards image/document content blocks to it. A
  /// model without this set rejects attachment-bearing requests with a
  /// friendly UNSUPPORTED_ATTACHMENT before anything travels.
  supportsAttachments: boolean
}

export const MODEL_CATALOG: ModelDefinition[] = [
  { id: 'claude-opus-5', provider: 'anthropic', displayName: 'Claude Opus 5', enabled: true, supportsAttachments: true },
  { id: 'claude-sonnet-5', provider: 'anthropic', displayName: 'Claude Sonnet 5', enabled: true, supportsAttachments: true },
  { id: 'claude-haiku-4-5', provider: 'anthropic', displayName: 'Claude Haiku 4.5', enabled: true, supportsAttachments: true },
]
