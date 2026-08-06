/// Gateway request validation: strict shapes, every dimension bounded, and
/// nothing the browser sends can steer transport — no URLs, no headers, no
/// provider request bodies. outputFormat is the one deliberately opaque
/// field: a JSON-schema object the client derives from its zod schema,
/// forwarded only into the adapter's typed output_config. Under BYOK it
/// shapes the user's own generation on their own key, so beyond size and
/// coarse shape it earns no deeper inspection.

import { z } from 'zod'
import { CREDENTIAL_ID_PATTERN } from '../credentials/schemas.js'

export const GATEWAY_LIMITS = {
  maxMessages: 40,
  maxMessageChars: 50_000,
  maxSystemChars: 50_000,
  maxTotalChars: 200_000,
  maxOutputTokens: 16_384,
  defaultMaxTokens: 8_192,
  maxOutputFormatChars: 32_768,
} as const

const MessageSchema = z.strictObject({
  role: z.enum(['user', 'assistant']),
  content: z.string().min(1).max(GATEWAY_LIMITS.maxMessageChars),
})

export const GatewayRequestSchema = z
  .strictObject({
    credentialId: z.string().regex(CREDENTIAL_ID_PATTERN),
    provider: z.enum(['anthropic']),
    model: z.string().min(1).max(100),
    messages: z.array(MessageSchema).min(1).max(GATEWAY_LIMITS.maxMessages),
    system: z.string().max(GATEWAY_LIMITS.maxSystemChars).optional(),
    maxTokens: z.number().int().min(1).max(GATEWAY_LIMITS.maxOutputTokens).optional(),
    effort: z.enum(['low', 'medium', 'high']).optional(),
    outputFormat: z.record(z.string(), z.unknown()).optional(),
  })
  .superRefine((request, ctx) => {
    const total =
      (request.system?.length ?? 0) + request.messages.reduce((sum, message) => sum + message.content.length, 0)
    if (total > GATEWAY_LIMITS.maxTotalChars) {
      ctx.addIssue({ code: 'custom', message: 'prompt too large' })
    }
    if (request.outputFormat) {
      if (request.outputFormat.type !== 'json_schema') {
        ctx.addIssue({ code: 'custom', message: 'outputFormat must be a json_schema format object' })
      }
      if (JSON.stringify(request.outputFormat).length > GATEWAY_LIMITS.maxOutputFormatChars) {
        ctx.addIssue({ code: 'custom', message: 'outputFormat too large' })
      }
    }
  })

export type GatewayRequest = z.infer<typeof GatewayRequestSchema>
