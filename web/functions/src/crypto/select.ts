/// Chooses the cipher behind the encryption seam. An explicit KMS_KEY_NAME
/// always wins — including under the emulator, where it means a developer is
/// deliberately exercising a nonproduction KMS key. Otherwise the emulator
/// gets the development service, and production configured with neither has
/// already failed the startup invariants.

import type { RuntimeConfig } from '../config.js'
import { DevelopmentEncryptionService } from './dev.js'
import { EncryptionError, type EncryptionService } from './encryption.js'
import { CloudKmsEncryptionService } from './kms.js'

export function buildEncryptionService(config: RuntimeConfig): EncryptionService {
  if (config.kmsKeyName) {
    return new CloudKmsEncryptionService(config.kmsKeyName)
  }
  if (config.isEmulator) {
    return new DevelopmentEncryptionService(config.devEncryptionKey, { isEmulator: true })
  }
  throw new EncryptionError('no encryption backend configured; startup invariants should have caught this')
}
