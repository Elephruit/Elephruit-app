import { describe, expect, it } from 'vitest'
import type { NormalizedRequest } from './adapter.js'
import { buildOpenAIParams } from './openai.js'

const request: NormalizedRequest = {
  model: 'gpt-5.6-luna',
  system: 'Return only the proposal.',
  messages: [
    {
      role: 'user',
      content: [
        { type: 'text', text: 'Read these.' },
        { type: 'image', mimeType: 'image/png', data: 'aW1hZ2U=' },
        { type: 'document', mimeType: 'application/pdf', data: 'cGRm', name: 'brief.pdf' },
      ],
    },
  ],
  maxTokens: 2048,
  effort: 'medium',
  outputFormat: {
    type: 'json_schema',
    name: 'capture_proposal',
    schema: { type: 'object', properties: { title: { type: 'string' } }, required: ['title'] },
  },
}

describe('buildOpenAIParams', () => {
  it('builds a stateless streaming Responses request with structured output', () => {
    const params = buildOpenAIParams(request)
    expect(params).toMatchObject({
      model: 'gpt-5.6-luna',
      store: false,
      stream: true,
      max_output_tokens: 2048,
      reasoning: { effort: 'medium' },
      text: { format: { type: 'json_schema', name: 'capture_proposal', strict: true } },
    })
  })

  it('converts inline images and PDFs without exposing transport controls', () => {
    const content = (buildOpenAIParams(request).input as Array<{ content: unknown }>)[0]!.content
    expect(content).toEqual([
      { type: 'input_text', text: 'Read these.' },
      { type: 'input_image', detail: 'auto', image_url: 'data:image/png;base64,aW1hZ2U=' },
      { type: 'input_file', file_data: 'data:application/pdf;base64,cGRm', filename: 'brief.pdf' },
    ])
  })
})
