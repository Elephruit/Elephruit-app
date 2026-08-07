import { describe, expect, it } from 'vitest'
import { isDeveloperAdminClaims } from './admin.js'

describe('developer admin authorization', () => {
  it('accepts only Mike’s verified production identity', () => {
    expect(isDeveloperAdminClaims({ email: 'mike@moocowgames.com', email_verified: true }, false)).toBe(true)
    expect(isDeveloperAdminClaims({ email: 'MIKE@MOOCOWGAMES.COM', email_verified: true }, false)).toBe(true)
    expect(isDeveloperAdminClaims({ email: 'mike@moocowgames.com', email_verified: false }, false)).toBe(false)
    expect(isDeveloperAdminClaims({ email: 'other@moocowgames.com', email_verified: true }, false)).toBe(false)
    expect(isDeveloperAdminClaims(undefined, false)).toBe(false)
  })

  it('allows the emulator-only local developer identity', () => {
    expect(isDeveloperAdminClaims({ email: 'dev@local.test' }, true)).toBe(true)
    expect(isDeveloperAdminClaims({ email: 'dev@local.test' }, false)).toBe(false)
  })
})
