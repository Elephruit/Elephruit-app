/// The encryption seam. Everything that stores or reads a provider API key
/// goes through EncryptionService; which cipher sits behind it (Cloud KMS in
/// production, local AES-256-GCM under the emulator) is a wiring decision made
/// once in the composition root.
///
/// Ciphertext is bound to its owning record via additional authenticated data:
/// a credential encrypted for one (uid, credentialId, provider) will not
/// decrypt under any other, so copying ciphertext between documents yields
/// nothing.

export interface EncryptionContext {
  uid: string
  credentialId: string
  provider: string
}

export interface EncryptedCredential {
  /// Base64. Never plaintext, never logged.
  ciphertext: string
  /// Full KMS key resource name, or DEV_KEY_LABEL for locally encrypted
  /// development records. Each service refuses the other's label.
  kmsKeyName: string
}

export interface EncryptionService {
  encrypt(plaintext: string, context: EncryptionContext): Promise<EncryptedCredential>
  decrypt(encrypted: EncryptedCredential, context: EncryptionContext): Promise<string>
}

export const DEV_KEY_LABEL = 'local-dev'

/// Generous ceiling for any provider key format; the request schema clamps
/// tighter. KMS itself allows 64KiB — this is a sanity bound, not a quota.
export const MAX_PLAINTEXT_CHARS = 4096

export class EncryptionError extends Error {}

export function assertEncryptable(plaintext: string): void {
  if (!plaintext || plaintext.trim().length === 0) {
    throw new EncryptionError('refusing to encrypt an empty value')
  }
  if (plaintext.length > MAX_PLAINTEXT_CHARS) {
    throw new EncryptionError('refusing to encrypt an implausibly large value')
  }
}

/// The AAD encoding must be injective: '|' is the separator, so no component
/// may contain it (or be empty, which would make adjacent fields ambiguous).
/// Firebase uids and our server-generated credential ids never do; a value
/// that does is corrupt input, not a case to accommodate.
export function canonicalAad(context: EncryptionContext): Buffer {
  const parts = [context.uid, context.credentialId, context.provider]
  for (const part of parts) {
    if (!part || part.includes('|')) {
      throw new EncryptionError('encryption context components must be nonempty and separator-free')
    }
  }
  return Buffer.from(parts.join('|'), 'utf8')
}
