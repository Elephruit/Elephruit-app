/// Callable input validation. Strict objects — unknown properties are
/// rejected, not ignored — and every string is bounded. The api key bound is
/// deliberately loose (formats change; prefixes are hints, not contracts)
/// but a key under 20 characters is nobody's real credential.

import { z } from 'zod'

export const CREDENTIAL_ID_PATTERN = /^[A-Za-z0-9_-]{1,64}$/

const ProviderSchema = z.enum(['anthropic', 'openai', 'google'])

const CredentialIdSchema = z.string().regex(CREDENTIAL_ID_PATTERN)

const ApiKeySchema = z
  .string()
  .transform((value) => value.trim())
  .pipe(z.string().min(20).max(2048))

const LabelSchema = z
  .string()
  .transform((value) => value.replace(/[\p{Cc}\p{Cf}]/gu, '').trim())
  .pipe(z.string().max(80))

export const AddCredentialInputSchema = z.strictObject({
  provider: ProviderSchema,
  apiKey: ApiKeySchema,
  label: LabelSchema.optional(),
})

export const VerifyCredentialInputSchema = z.strictObject({
  credentialId: CredentialIdSchema,
})

export const ReplaceCredentialInputSchema = z.strictObject({
  credentialId: CredentialIdSchema,
  apiKey: ApiKeySchema,
})

export const DeleteCredentialInputSchema = z.strictObject({
  credentialId: CredentialIdSchema,
})

export type AddCredentialInput = z.infer<typeof AddCredentialInputSchema>
export type VerifyCredentialInput = z.infer<typeof VerifyCredentialInputSchema>
export type ReplaceCredentialInput = z.infer<typeof ReplaceCredentialInputSchema>
export type DeleteCredentialInput = z.infer<typeof DeleteCredentialInputSchema>

/// Derives the UI hint from the exact value that was encrypted.
export function keyHintFor(apiKey: string): string {
  return apiKey.slice(-4)
}
