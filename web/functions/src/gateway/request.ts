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
  maxMessageChars: 200_000,
  maxSystemChars: 50_000,
  maxTotalChars: 200_000,
  maxOutputTokens: 16_384,
  defaultMaxTokens: 8_192,
  maxOutputFormatChars: 32_768,
  /// Attachment blocks: base64 payload ceilings sized to fit the callable
  /// transport envelope with headroom, counted separately from text.
  maxAttachmentBlocks: 10,
  maxAttachmentChars: 24_000_000,
  maxTotalAttachmentChars: 26_000_000,
} as const

/// Provider-neutral content blocks — the only non-text shapes that cross the
/// wire. MIME types are closed enums: an attachment the browser failed to
/// re-encode into one of these simply cannot be expressed.
const TextBlockSchema = z.strictObject({
  type: z.literal('text'),
  text: z.string().min(1).max(GATEWAY_LIMITS.maxMessageChars),
})

const ImageBlockSchema = z.strictObject({
  type: z.literal('image'),
  mimeType: z.enum(['image/jpeg', 'image/png', 'image/webp']),
  data: z.string().min(1).max(GATEWAY_LIMITS.maxAttachmentChars),
})

const DocumentBlockSchema = z.strictObject({
  type: z.literal('document'),
  mimeType: z.literal('application/pdf'),
  data: z.string().min(1).max(GATEWAY_LIMITS.maxAttachmentChars),
  name: z.string().max(200).optional(),
})

const ContentBlockSchema = z.union([TextBlockSchema, ImageBlockSchema, DocumentBlockSchema])
export type GatewayContentBlock = z.infer<typeof ContentBlockSchema>

const MessageSchema = z.strictObject({
  role: z.enum(['user', 'assistant']),
  content: z.union([
    z.string().min(1).max(GATEWAY_LIMITS.maxMessageChars),
    z.array(ContentBlockSchema).min(1).max(GATEWAY_LIMITS.maxAttachmentBlocks + 4),
  ]),
})

const OutputFormatSchema = z.strictObject({
  type: z.literal('json_schema'),
  name: z.string().regex(/^[A-Za-z][A-Za-z0-9_-]{0,63}$/),
  schema: z.record(z.string(), z.unknown()),
})

export const GatewayRequestSchema = z
  .strictObject({
    credentialId: z.string().regex(CREDENTIAL_ID_PATTERN),
    provider: z.enum(['anthropic', 'openai', 'google']),
    model: z.string().min(1).max(100),
    messages: z.array(MessageSchema).min(1).max(GATEWAY_LIMITS.maxMessages),
    system: z.string().max(GATEWAY_LIMITS.maxSystemChars).optional(),
    maxTokens: z.number().int().min(1).max(GATEWAY_LIMITS.maxOutputTokens).optional(),
    effort: z.enum(['low', 'medium', 'high']).optional(),
    outputFormat: OutputFormatSchema.optional(),
  })
  .superRefine((request, ctx) => {
    let textChars = request.system?.length ?? 0
    let attachmentChars = 0
    let attachmentCount = 0
    for (const message of request.messages) {
      if (typeof message.content === 'string') {
        textChars += message.content.length
        continue
      }
      for (const block of message.content) {
        if (block.type === 'text') textChars += block.text.length
        else {
          attachmentCount += 1
          attachmentChars += block.data.length
        }
      }
    }
    if (textChars > GATEWAY_LIMITS.maxTotalChars) {
      ctx.addIssue({ code: 'custom', message: 'prompt too large' })
    }
    if (attachmentCount > GATEWAY_LIMITS.maxAttachmentBlocks) {
      ctx.addIssue({ code: 'custom', message: 'too many attachments' })
    }
    if (attachmentChars > GATEWAY_LIMITS.maxTotalAttachmentChars) {
      ctx.addIssue({ code: 'custom', message: 'attachments too large' })
    }
    if (request.outputFormat) {
      if (JSON.stringify(request.outputFormat).length > GATEWAY_LIMITS.maxOutputFormatChars) {
        ctx.addIssue({ code: 'custom', message: 'outputFormat too large' })
      }
    }
  })

export type GatewayRequest = z.infer<typeof GatewayRequestSchema>
