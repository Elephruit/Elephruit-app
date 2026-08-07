import { describe, expect, it } from 'vitest'
import { productionConfigurationError } from './buildEnvironment'

describe('production environment validation', () => {
  it('refuses a real Firebase build without App Check', () => {
    expect(productionConfigurationError({ VITE_FIREBASE_PROJECT_ID: 'mcg-crm-app' })).toBe(
      'VITE_APPCHECK_SITE_KEY is required when building Firebase project mcg-crm-app.',
    )
  })

  it('accepts a real Firebase build with the public site key', () => {
    expect(
      productionConfigurationError({
        VITE_FIREBASE_PROJECT_ID: 'mcg-crm-app',
        VITE_APPCHECK_SITE_KEY: 'public-site-key',
      }),
    ).toBeNull()
  })

  it('keeps demo builds available for local tests', () => {
    expect(productionConfigurationError({ VITE_FIREBASE_PROJECT_ID: 'demo-elephruit' })).toBeNull()
  })
})
