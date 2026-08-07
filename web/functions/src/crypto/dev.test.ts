import { describe, expect, it } from 'vitest'
import { DevelopmentEncryptionService } from './dev.js'
import { DEV_KEY_LABEL, EncryptionError, type EncryptionContext } from './encryption.js'

const context: EncryptionContext = { uid: 'user-a', credentialId: 'cred-1', provider: 'anthropic' }
const service = () => new DevelopmentEncryptionService('a-long-random-development-key', { isEmulator: true })

describe('DevelopmentEncryptionService', () => {
  it('is emulator-only', () => {
    expect(() => new DevelopmentEncryptionService('a-long-random-development-key', { isEmulator: false })).toThrow(
      EncryptionError,
    )
  })

  it('requires substantial key material', () => {
    expect(() => new DevelopmentEncryptionService(null, { isEmulator: true })).toThrow(EncryptionError)
    expect(() => new DevelopmentEncryptionService('short', { isEmulator: true })).toThrow(EncryptionError)
  })

  it('round-trips a secret and labels the record as development-encrypted', async () => {
    const svc = service()
    const encrypted = await svc.encrypt('sk-ant-test-secret-000', context)
    expect(encrypted.kmsKeyName).toBe(DEV_KEY_LABEL)
    expect(encrypted.ciphertext).not.toContain('sk-ant')
    expect(() => Buffer.from(encrypted.ciphertext, 'base64')).not.toThrow()
    await expect(svc.decrypt(encrypted, context)).resolves.toBe('sk-ant-test-secret-000')
  })

  it('produces distinct ciphertext per encryption (fresh IV)', async () => {
    const svc = service()
    const a = await svc.encrypt('sk-ant-test-secret-000', context)
    const b = await svc.encrypt('sk-ant-test-secret-000', context)
    expect(a.ciphertext).not.toBe(b.ciphertext)
  })

  it('refuses to decrypt under a different context — ciphertext is bound to its record', async () => {
    const svc = service()
    const encrypted = await svc.encrypt('sk-ant-test-secret-000', context)
    await expect(svc.decrypt(encrypted, { ...context, uid: 'user-b' })).rejects.toThrow(EncryptionError)
    await expect(svc.decrypt(encrypted, { ...context, credentialId: 'cred-2' })).rejects.toThrow(EncryptionError)
    await expect(svc.decrypt(encrypted, { ...context, provider: 'openai' })).rejects.toThrow(EncryptionError)
  })

  it('refuses tampered ciphertext', async () => {
    const svc = service()
    const encrypted = await svc.encrypt('sk-ant-test-secret-000', context)
    const raw = Buffer.from(encrypted.ciphertext, 'base64')
    raw[raw.length - 1] = raw[raw.length - 1]! ^ 0xff
    await expect(
      svc.decrypt({ ciphertext: raw.toString('base64'), kmsKeyName: DEV_KEY_LABEL }, context),
    ).rejects.toThrow(EncryptionError)
  })

  it('refuses records that claim real KMS custody', async () => {
    const svc = service()
    await expect(
      svc.decrypt({ ciphertext: 'AAAA', kmsKeyName: 'projects/p/locations/l/keyRings/r/cryptoKeys/k' }, context),
    ).rejects.toThrow(EncryptionError)
  })

  it('rejects empty plaintext', async () => {
    await expect(service().encrypt('', context)).rejects.toThrow(EncryptionError)
  })
})
