import { describe, expect, it } from 'vitest'
import type { NormalizedRequest } from './adapter.js'
import { buildGoogleParams } from './google.js'

const request: NormalizedRequest = {
  model: 'gemini-3.6-flash',
  system: 'Return only the proposal.',
  messages: [
    {
      role: 'user',
      content: [
        { type: 'text', text: 'Read these.' },
        { type: 'image', mimeType: 'image/webp', data: 'aW1hZ2U=' },
        { type: 'document', mimeType: 'application/pdf', data: 'cGRm', name: 'brief.pdf' },
      ],
    },
    { role: 'assistant', content: 'Prior answer' },
  ],
  maxTokens: 2048,
  effort: 'low',
  outputFormat: {
    type: 'json_schema',
    name: 'capture_proposal',
    schema: { type: 'object', properties: { title: { type: 'string' } }, required: ['title'] },
  },
}

describe('buildGoogleParams', () => {
  it('builds a stateless streaming Interactions request with structured output', () => {
    expect(buildGoogleParams(request)).toMatchObject({
      model: 'gemini-3.6-flash',
      store: false,
      stream: true,
      system_instruction: 'Return only the proposal.',
      generation_config: { max_output_tokens: 2048, thinking_level: 'low' },
      response_format: { type: 'text', mime_type: 'application/json' },
    })
  })

  it('maps conversation roles and inline media into Interaction turns', () => {
    expect(buildGoogleParams(request).input).toEqual([
      {
        role: 'user',
        content: [
          { type: 'text', text: 'Read these.' },
          { type: 'image', data: 'aW1hZ2U=', mime_type: 'image/webp' },
          { type: 'document', data: 'cGRm', mime_type: 'application/pdf' },
        ],
      },
      { role: 'model', content: 'Prior answer' },
    ])
  })
})
