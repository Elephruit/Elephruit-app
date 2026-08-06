/// Runtime configuration and the startup invariants that keep development
/// conveniences out of production. Read once at load; everything downstream
/// takes the parsed config, never process.env.

export interface RuntimeConfig {
  /// True only under the Functions emulator (FUNCTIONS_EMULATOR=true).
  isEmulator: boolean
  /// Full Cloud KMS crypto key resource name. Required in production; optional
  /// in the emulator for developers deliberately exercising a nonproduction key.
  kmsKeyName: string | null
  /// Local AES-256-GCM key material for the development encryption service.
  /// Emulator-only; its mere presence in production fails startup.
  devEncryptionKey: string | null
  /// Serve canned provider responses instead of calling api.anthropic.com.
  /// Emulator-only; its mere presence in production fails startup.
  useFakeAdapter: boolean
}

export function readConfig(env: NodeJS.ProcessEnv = process.env): RuntimeConfig {
  return {
    isEmulator: env.FUNCTIONS_EMULATOR === 'true',
    kmsKeyName: env.KMS_KEY_NAME?.trim() || null,
    devEncryptionKey: env.DEV_ENCRYPTION_KEY?.trim() || null,
    useFakeAdapter: env.AI_FAKE_ADAPTER === '1',
  }
}

/// Fails fast — at deploy-time module load, not first request — when production
/// is configured like a development machine. The emulator passes trivially.
export function assertStartupInvariants(config: RuntimeConfig): void {
  if (config.isEmulator) return

  if (!config.kmsKeyName) {
    throw new Error('production requires KMS_KEY_NAME; refusing to start without real key custody')
  }
  if (config.devEncryptionKey) {
    throw new Error('DEV_ENCRYPTION_KEY is set in production; the development cipher must never hold real credentials')
  }
  if (config.useFakeAdapter) {
    throw new Error('AI_FAKE_ADAPTER is set in production; canned responses are an emulator-only affordance')
  }
}
