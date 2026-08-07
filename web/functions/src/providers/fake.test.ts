import { describe, expect, it } from 'vitest'
import { PublicError } from '../log/errors.js'
import type { NormalizedRequest } from './adapter.js'
import { fakeAdapter } from './fake.js'

const signal = new AbortController().signal

function request(overrides: Partial<NormalizedRequest> = {}): NormalizedRequest {
  return {
    model: 'claude-opus-5',
    system: null,
    messages: [{ role: 'user', content: 'hello' }],
    maxTokens: 8192,
    effort: 'low',
    outputFormat: null,
    ...overrides,
  }
}

async function collect(req: NormalizedRequest, apiKey = 'sk-ant-test-valid-0000000000') {
  const parts: string[] = []
  const outcome = await fakeAdapter.streamMessage(apiKey, req, signal, (text) => {
    parts.push(text)
  })
  return { text: parts.join(''), parts, outcome }
}

describe('fakeAdapter', () => {
  it('streams in multiple chunks and tags the outcome as fake', async () => {
    const { parts, outcome } = await collect(request())
    expect(parts.length).toBeGreaterThan(1)
    expect(outcome.adapter).toBe('fake')
    expect(outcome.stopReason).toBe('end_turn')
  })

  it('serves parseable capture-proposal JSON when the format asks for one', async () => {
    const { text } = await collect(
      request({
        outputFormat: {
          type: 'json_schema',
          name: 'capture_proposal',
          schema: { properties: { participantNames: {} } },
        },
      }),
    )
    const proposal = JSON.parse(text)
    expect(proposal.participantNames).toEqual(['Ana Torres'])
    expect(proposal.interaction.kind).toBe('in-person')
  })

  it('echoes the briefed people back by name', async () => {
    const input = JSON.stringify({ date: '2026-08-06', people: [{ name: 'Priya Patel' }, { name: 'Sam Ruiz' }] })
    const { text } = await collect(
      request({
        messages: [{ role: 'user', content: input }],
        outputFormat: {
          type: 'json_schema',
          name: 'day_brief',
          schema: { properties: { talkingPoints: {} } },
        },
      }),
    )
    const brief = JSON.parse(text)
    expect(brief.people.map((person: { name: string }) => person.name)).toEqual(['Priya Patel', 'Sam Ruiz'])
  })

  it('fails auth for -invalid keys and availability for -flaky keys', async () => {
    await expect(collect(request(), 'sk-ant-test-invalid-000000')).rejects.toMatchObject({
      code: 'PROVIDER_AUTH_FAILED',
    })
    await expect(collect(request(), 'sk-ant-test-flaky-000000')).rejects.toBeInstanceOf(PublicError)
  })
})
