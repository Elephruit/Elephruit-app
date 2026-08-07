export interface BuildEnvironment {
  VITE_FIREBASE_PROJECT_ID?: string
  VITE_APPCHECK_SITE_KEY?: string
}

/// Production callables enforce App Check. Shipping a real Firebase project
/// without its public site key makes every AI request fail before the gateway
/// handler runs, so refuse that build instead of discovering it in production.
export function productionConfigurationError(env: BuildEnvironment): string | null {
  const projectID = env.VITE_FIREBASE_PROJECT_ID?.trim()
  if (!projectID || projectID === 'demo-elephruit') return null
  if (!env.VITE_APPCHECK_SITE_KEY?.trim()) {
    return `VITE_APPCHECK_SITE_KEY is required when building Firebase project ${projectID}.`
  }
  return null
}
