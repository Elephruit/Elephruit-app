/// Development implementation of the encryption seam: AES-256-GCM from
/// node:crypto, keyed from an uncommitted .env.local value. It exists so the
/// emulator can exercise the whole credential lifecycle without Cloud access —
/// and it is fenced accordingly: the constructor throws outside the emulator,
/// every record it writes is labeled DEV_KEY_LABEL, and it refuses to touch
/// ciphertext carrying a real KMS key name (as the KMS service refuses its).

import { createCipheriv, createDecipheriv, randomBytes, scryptSync } from 'node:crypto'
import {
  DEV_KEY_LABEL,
  EncryptionError,
  assertEncryptable,
  canonicalAad,
  type EncryptedCredential,
  type EncryptionContext,
  type EncryptionService,
} from './encryption.js'

const IV_BYTES = 12
const TAG_BYTES = 16

export class DevelopmentEncryptionService implements EncryptionService {
  private readonly key: Buffer

  constructor(rawKey: string | null, options: { isEmulator: boolean }) {
    if (!options.isEmulator) {
      throw new EncryptionError('DevelopmentEncryptionService is emulator-only; production must use Cloud KMS')
    }
    if (!rawKey || rawKey.trim().length < 16) {
      throw new EncryptionError(
        'DEV_ENCRYPTION_KEY is missing or too short — add a long random value to functions/.env.local',
      )
    }
    // scrypt turns whatever the developer generated into uniform key material;
    // the fixed salt is fine because this key never protects production data.
    this.key = scryptSync(rawKey.trim(), 'elephruit-byok-dev', 32)
  }

  async encrypt(plaintext: string, context: EncryptionContext): Promise<EncryptedCredential> {
    assertEncryptable(plaintext)
    const iv = randomBytes(IV_BYTES)
    const cipher = createCipheriv('aes-256-gcm', this.key, iv)
    cipher.setAAD(canonicalAad(context))
    const encrypted = Buffer.concat([cipher.update(plaintext, 'utf8'), cipher.final()])
    const tag = cipher.getAuthTag()
    return {
      ciphertext: Buffer.concat([iv, tag, encrypted]).toString('base64'),
      kmsKeyName: DEV_KEY_LABEL,
    }
  }

  async decrypt(encrypted: EncryptedCredential, context: EncryptionContext): Promise<string> {
    if (encrypted.kmsKeyName !== DEV_KEY_LABEL) {
      throw new EncryptionError('refusing non-development ciphertext under the development service')
    }
    const raw = Buffer.from(encrypted.ciphertext, 'base64')
    if (raw.length <= IV_BYTES + TAG_BYTES) {
      throw new EncryptionError('development ciphertext is malformed')
    }
    const iv = raw.subarray(0, IV_BYTES)
    const tag = raw.subarray(IV_BYTES, IV_BYTES + TAG_BYTES)
    const body = raw.subarray(IV_BYTES + TAG_BYTES)
    try {
      const decipher = createDecipheriv('aes-256-gcm', this.key, iv)
      decipher.setAAD(canonicalAad(context))
      decipher.setAuthTag(tag)
      return Buffer.concat([decipher.update(body), decipher.final()]).toString('utf8')
    } catch {
      // GCM authentication failure: wrong key, tampered ciphertext, or a
      // context (AAD) that does not match the record this was encrypted for.
      throw new EncryptionError('development decrypt failed authentication')
    }
  }
}
