import { describe, expect, it, vi } from 'vitest'
import { DEV_KEY_LABEL, EncryptionError, type EncryptionContext } from './encryption.js'
import { CloudKmsEncryptionService, type KmsClientLike } from './kms.js'

const KEY_NAME = 'projects/p/locations/us-central1/keyRings/ai-credentials/cryptoKeys/provider-api-keys'
const context: EncryptionContext = { uid: 'user-a', credentialId: 'cred-1', provider: 'anthropic' }

/// A fake that "encrypts" by concatenating plaintext and AAD, so decrypt can
/// verify the AAD actually round-tripped through the service.
function fakeClient(): KmsClientLike {
  return {
    encrypt: vi.fn(
      async ({
        plaintext,
        additionalAuthenticatedData,
      }: {
        plaintext: Uint8Array
        additionalAuthenticatedData: Uint8Array
      }): Promise<[{ ciphertext: Uint8Array }]> => [
        { ciphertext: Buffer.concat([Buffer.from('enc:'), plaintext, Buffer.from('#'), additionalAuthenticatedData]) },
      ],
    ),
    decrypt: vi.fn(
      async ({
        ciphertext,
        additionalAuthenticatedData,
      }: {
        ciphertext: Uint8Array
        additionalAuthenticatedData: Uint8Array
      }): Promise<[{ plaintext: Uint8Array }]> => {
        const raw = Buffer.from(ciphertext).toString('utf8')
        const [, body] = raw.split('enc:')
        const [plaintext, aad] = (body ?? '').split('#')
        if (aad !== Buffer.from(additionalAuthenticatedData).toString('utf8')) {
          throw new Error('AAD mismatch')
        }
        return [{ plaintext: Buffer.from(plaintext ?? '', 'utf8') }]
      },
    ),
  }
}

describe('CloudKmsEncryptionService', () => {
  it('requires a real key resource name', () => {
    expect(() => new CloudKmsEncryptionService('', fakeClient())).toThrow(EncryptionError)
    expect(() => new CloudKmsEncryptionService(DEV_KEY_LABEL, fakeClient())).toThrow(EncryptionError)
  })

  it('encrypts with the canonical AAD and returns base64 labeled with the key name', async () => {
    const client = fakeClient()
    const svc = new CloudKmsEncryptionService(KEY_NAME, client)
    const encrypted = await svc.encrypt('sk-ant-test-secret-000', context)

    expect(encrypted.kmsKeyName).toBe(KEY_NAME)
    expect(() => Buffer.from(encrypted.ciphertext, 'base64')).not.toThrow()
    expect(client.encrypt).toHaveBeenCalledWith(
      expect.objectContaining({
        name: KEY_NAME,
        additionalAuthenticatedData: Buffer.from('user-a|cred-1|anthropic', 'utf8'),
      }),
    )
  })

  it('round-trips when the decrypt context matches, and fails when it does not', async () => {
    const svc = new CloudKmsEncryptionService(KEY_NAME, fakeClient())
    const encrypted = await svc.encrypt('sk-ant-test-secret-000', context)
    await expect(svc.decrypt(encrypted, context)).resolves.toBe('sk-ant-test-secret-000')
    await expect(svc.decrypt(encrypted, { ...context, uid: 'user-b' })).rejects.toThrow(EncryptionError)
  })

  it('refuses development-labeled ciphertext outright', async () => {
    const client = fakeClient()
    const svc = new CloudKmsEncryptionService(KEY_NAME, client)
    await expect(svc.decrypt({ ciphertext: 'AAAA', kmsKeyName: DEV_KEY_LABEL }, context)).rejects.toThrow(
      EncryptionError,
    )
    expect(client.decrypt).not.toHaveBeenCalled()
  })

  it('normalizes client failures without exposing the request', async () => {
    const failing: KmsClientLike = {
      encrypt: async () => {
        throw new Error('PERMISSION_DENIED: verbose upstream detail')
      },
      decrypt: async () => [{ plaintext: null }],
    }
    const svc = new CloudKmsEncryptionService(KEY_NAME, failing)
    await expect(svc.encrypt('sk-ant-test-secret-000', context)).rejects.toThrow('KMS encrypt failed')
    await expect(svc.decrypt({ ciphertext: 'AAAA', kmsKeyName: KEY_NAME }, context)).rejects.toThrow(
      'KMS decrypt returned no plaintext',
    )
  })
})
