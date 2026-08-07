export const DEVELOPER_ADMIN_EMAIL = 'mike@moocowgames.com'

export function isDeveloperAdminClaims(
  token: Record<string, unknown> | undefined,
  isEmulator: boolean,
): boolean {
  const email = typeof token?.email === 'string' ? token.email.toLowerCase() : ''
  if (isEmulator && email === 'dev@local.test') return true
  return token?.email_verified === true && email === DEVELOPER_ADMIN_EMAIL
}
