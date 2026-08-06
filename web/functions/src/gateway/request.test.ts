import { describe, expect, it } from 'vitest'
import { GATEWAY_LIMITS, GatewayRequestSchema } from './request.js'

const BASE = {
  credentialId: 'cred_0123456789abcdef',
  provider: 'anthropic',
  model: 'claude-opus-5',
  messages: [{ role: 'user', content: 'hello' }],
}

describe('content blocks', () => {
  it('accepts plain string content unchanged', () => {
    expect(GatewayRequestSchema.safeParse(BASE).success).toBe(true)
  })

  it('accepts text, image, and document blocks together', () => {
    const request = {
      ...BASE,
      messages: [
        {
          role: 'user',
          content: [
            { type: 'text', text: '[File: dossier.pdf (a1)]' },
            { type: 'document', mimeType: 'application/pdf', data: 'aGVsbG8=', name: 'dossier.pdf' },
            { type: 'image', mimeType: 'image/jpeg', data: 'aGVsbG8=' },
          ],
        },
      ],
    }
    expect(GatewayRequestSchema.safeParse(request).success).toBe(true)
  })

  it('rejects MIME types outside the closed enums', () => {
    const svg = {
      ...BASE,
      messages: [{ role: 'user', content: [{ type: 'image', mimeType: 'image/svg+xml', data: 'aGVsbG8=' }] }],
    }
    expect(GatewayRequestSchema.safeParse(svg).success).toBe(false)
    const docx = {
      ...BASE,
      messages: [
        {
          role: 'user',
          content: [
            {
              type: 'document',
              mimeType: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
              data: 'aGVsbG8=',
            },
          ],
        },
      ],
    }
    expect(GatewayRequestSchema.safeParse(docx).success).toBe(false)
  })

  it('rejects unknown block shapes and extra keys', () => {
    const unknown = {
      ...BASE,
      messages: [{ role: 'user', content: [{ type: 'audio', data: 'aGVsbG8=' }] }],
    }
    expect(GatewayRequestSchema.safeParse(unknown).success).toBe(false)
    const extra = {
      ...BASE,
      messages: [{ role: 'user', content: [{ type: 'text', text: 'hi', url: 'https://x' }] }],
    }
    expect(GatewayRequestSchema.safeParse(extra).success).toBe(false)
  })

  it('bounds the attachment count and the total attachment payload', () => {
    const blocks = Array.from({ length: GATEWAY_LIMITS.maxAttachmentBlocks + 1 }, () => ({
      type: 'image',
      mimeType: 'image/png',
      data: 'aGVsbG8=',
    }))
    const tooMany = { ...BASE, messages: [{ role: 'user', content: blocks }] }
    expect(GatewayRequestSchema.safeParse(tooMany).success).toBe(false)
  })

  it('still bounds text across string and block content together', () => {
    const half = 'x'.repeat(GATEWAY_LIMITS.maxTotalChars / 2 + 1)
    const request = {
      ...BASE,
      messages: [
        { role: 'user', content: half },
        { role: 'user', content: [{ type: 'text', text: half }] },
      ],
    }
    expect(GatewayRequestSchema.safeParse(request).success).toBe(false)
  })
})
