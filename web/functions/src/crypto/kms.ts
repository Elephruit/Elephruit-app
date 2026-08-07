/// Cloud KMS implementation of the encryption seam. Symmetric
/// encrypt/decrypt against one crypto key, with the canonical AAD bound on
/// both sides so ciphertext cannot be replayed across records. Decrypt names
/// the key, not a version — KMS resolves the version from the ciphertext,
/// which is why rotated-away versions must never be destroyed while records
/// still reference them (see the cloud runbook).

import { KeyManagementServiceClient } from '@google-cloud/kms'
import {
  DEV_KEY_LABEL,
  EncryptionError,
  assertEncryptable,
  canonicalAad,
  type EncryptedCredential,
  type EncryptionContext,
  type EncryptionService,
} from './encryption.js'

/// The slice of the KMS client this service uses, kept structural so unit
/// tests inject a fake instead of standing up gRPC.
export interface KmsClientLike {
  encrypt(request: {
    name: string
    plaintext: Uint8Array
    additionalAuthenticatedData: Uint8Array
  }): Promise<[{ ciphertext?: Uint8Array | string | null }, ...unknown[]]>
  decrypt(request: {
    name: string
    ciphertext: Uint8Array
    additionalAuthenticatedData: Uint8Array
  }): Promise<[{ plaintext?: Uint8Array | string | null }, ...unknown[]]>
}

export class CloudKmsEncryptionService implements EncryptionService {
  private readonly client: KmsClientLike

  constructor(
    private readonly keyName: string,
    client?: KmsClientLike,
  ) {
    if (!keyName || keyName === DEV_KEY_LABEL) {
      throw new EncryptionError('CloudKmsEncryptionService requires a real KMS key resource name')
    }
    this.client = client ?? new KeyManagementServiceClient()
  }

  async encrypt(plaintext: string, context: EncryptionContext): Promise<EncryptedCredential> {
    assertEncryptable(plaintext)
    const aad = canonicalAad(context)
    let ciphertext: Uint8Array | string | null | undefined
    try {
      const [response] = await this.client.encrypt({
        name: this.keyName,
        plaintext: Buffer.from(plaintext, 'utf8'),
        additionalAuthenticatedData: aad,
      })
      ciphertext = response.ciphertext
    } catch (cause) {
      throw new EncryptionError('KMS encrypt failed', { cause })
    }
    if (!ciphertext) {
      throw new EncryptionError('KMS encrypt returned no ciphertext')
    }
    return {
      ciphertext: Buffer.from(ciphertext as Uint8Array).toString('base64'),
      kmsKeyName: this.keyName,
    }
  }

  async decrypt(encrypted: EncryptedCredential, context: EncryptionContext): Promise<string> {
    if (encrypted.kmsKeyName === DEV_KEY_LABEL) {
      throw new EncryptionError('refusing development-labeled ciphertext under the KMS service')
    }
    const aad = canonicalAad(context)
    let plaintext: Uint8Array | string | null | undefined
    try {
      const [response] = await this.client.decrypt({
        name: this.keyName,
        ciphertext: Buffer.from(encrypted.ciphertext, 'base64'),
        additionalAuthenticatedData: aad,
      })
      plaintext = response.plaintext
    } catch (cause) {
      throw new EncryptionError('KMS decrypt failed', { cause })
    }
    if (!plaintext) {
      throw new EncryptionError('KMS decrypt returned no plaintext')
    }
    return Buffer.from(plaintext as Uint8Array).toString('utf8')
  }
}
