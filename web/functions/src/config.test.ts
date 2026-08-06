import { describe, expect, it } from 'vitest'
import { assertStartupInvariants, readConfig } from './config.js'
import { DevelopmentEncryptionService } from './crypto/dev.js'
import { buildEncryptionService } from './crypto/select.js'

const KEY_NAME = 'projects/p/locations/us-central1/keyRings/ai-credentials/cryptoKeys/provider-api-keys'

describe('readConfig', () => {
  it('detects the emulator and trims configured values', () => {
    const config = readConfig({
      FUNCTIONS_EMULATOR: 'true',
      KMS_KEY_NAME: `  ${KEY_NAME}  `,
      DEV_ENCRYPTION_KEY: 'dev-key-material-long-enough',
      AI_FAKE_ADAPTER: '1',
    } as NodeJS.ProcessEnv)
    expect(config).toEqual({
      isEmulator: true,
      kmsKeyName: KEY_NAME,
      devEncryptionKey: 'dev-key-material-long-enough',
      useFakeAdapter: true,
    })
  })

  it('treats absent values as null/false', () => {
    const config = readConfig({} as NodeJS.ProcessEnv)
    expect(config).toEqual({ isEmulator: false, kmsKeyName: null, devEncryptionKey: null, useFakeAdapter: false })
  })
})

describe('assertStartupInvariants', () => {
  const prod = { isEmulator: false, kmsKeyName: KEY_NAME, devEncryptionKey: null, useFakeAdapter: false }

  it('accepts a correctly configured production runtime', () => {
    expect(() => assertStartupInvariants(prod)).not.toThrow()
  })

  it('refuses production without KMS', () => {
    expect(() => assertStartupInvariants({ ...prod, kmsKeyName: null })).toThrow(/KMS_KEY_NAME/)
  })

  it('refuses production carrying the development cipher key', () => {
    expect(() => assertStartupInvariants({ ...prod, devEncryptionKey: 'anything-long-enough' })).toThrow(
      /development cipher/,
    )
  })

  it('refuses production configured with the fake adapter', () => {
    expect(() => assertStartupInvariants({ ...prod, useFakeAdapter: true })).toThrow(/emulator-only/)
  })

  it('lets the emulator run with any of those set', () => {
    expect(() =>
      assertStartupInvariants({
        isEmulator: true,
        kmsKeyName: null,
        devEncryptionKey: 'dev-key-material-long-enough',
        useFakeAdapter: true,
      }),
    ).not.toThrow()
  })
})

describe('buildEncryptionService', () => {
  it('prefers an explicit KMS key even under the emulator', () => {
    const svc = buildEncryptionService({
      isEmulator: true,
      kmsKeyName: KEY_NAME,
      devEncryptionKey: 'dev-key-material-long-enough',
      useFakeAdapter: false,
    })
    expect(svc).not.toBeInstanceOf(DevelopmentEncryptionService)
  })

  it('gives the emulator the development service when no KMS key is set', () => {
    const svc = buildEncryptionService({
      isEmulator: true,
      kmsKeyName: null,
      devEncryptionKey: 'dev-key-material-long-enough',
      useFakeAdapter: false,
    })
    expect(svc).toBeInstanceOf(DevelopmentEncryptionService)
  })

  it('throws rather than silently falling back outside the emulator', () => {
    expect(() =>
      buildEncryptionService({ isEmulator: false, kmsKeyName: null, devEncryptionKey: null, useFakeAdapter: false }),
    ).toThrow()
  })
})
