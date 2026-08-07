import { describe, expect, it } from 'vitest'
import { EncryptionError, MAX_PLAINTEXT_CHARS, assertEncryptable, canonicalAad } from './encryption.js'

describe('canonicalAad', () => {
  it('encodes the context as uid|credentialId|provider', () => {
    const aad = canonicalAad({ uid: 'u1', credentialId: 'c1', provider: 'anthropic' })
    expect(aad.toString('utf8')).toBe('u1|c1|anthropic')
  })

  it('differs when any component differs', () => {
    const base = canonicalAad({ uid: 'u1', credentialId: 'c1', provider: 'anthropic' })
    const otherUser = canonicalAad({ uid: 'u2', credentialId: 'c1', provider: 'anthropic' })
    const otherCred = canonicalAad({ uid: 'u1', credentialId: 'c2', provider: 'anthropic' })
    expect(base.equals(otherUser)).toBe(false)
    expect(base.equals(otherCred)).toBe(false)
  })

  it('rejects separator characters that would make the encoding ambiguous', () => {
    expect(() => canonicalAad({ uid: 'u|1', credentialId: 'c1', provider: 'anthropic' })).toThrow(EncryptionError)
  })

  it('rejects empty components', () => {
    expect(() => canonicalAad({ uid: '', credentialId: 'c1', provider: 'anthropic' })).toThrow(EncryptionError)
    expect(() => canonicalAad({ uid: 'u1', credentialId: 'c1', provider: '' })).toThrow(EncryptionError)
  })
})

describe('assertEncryptable', () => {
  it('rejects empty and whitespace-only plaintext', () => {
    expect(() => assertEncryptable('')).toThrow(EncryptionError)
    expect(() => assertEncryptable('   ')).toThrow(EncryptionError)
  })

  it('rejects implausibly large plaintext', () => {
    expect(() => assertEncryptable('x'.repeat(MAX_PLAINTEXT_CHARS + 1))).toThrow(EncryptionError)
  })

  it('accepts a key-shaped value', () => {
    expect(() => assertEncryptable('sk-ant-test-000000000000')).not.toThrow()
  })
})
