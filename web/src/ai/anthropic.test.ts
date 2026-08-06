import { describe, expect, it } from 'vitest'
import { resolveProposal } from '../domain/assist'
import { FactAttributes } from '../domain/facts'
import { CaptureProposalSchema, buildRequestParams, buildSystemPrompt } from './anthropic'

/// The wire fixture: what the model is expected to return for the canonical
/// dictation — "Coffee with Ana — her son starts at South High this fall;
/// need to send her the neighborhood list."
const FIXTURE = {
  interaction: {
    kind: 'in-person',
    summary: 'Coffee with Ana',
    discussion: 'Her son starts at South High this fall.',
  },
  participantNames: ['Ana Torres'],
  facts: [],
  relationships: [
    {
      subjectName: 'Ana Torres',
      kind: 'child',
      label: 'son',
      otherName: null,
      facts: [{ attribute: 'school', value: 'South High' }],
    },
  ],
  followUps: [{ title: 'Send the neighborhood list', personNames: ['Ana Torres'] }],
}

describe('CaptureProposalSchema', () => {
  it('accepts the canonical fixture and feeds resolution cleanly', () => {
    const proposal = CaptureProposalSchema.parse(FIXTURE)
    const { items, warnings } = resolveProposal(proposal, [], new Date('2026-08-06T15:00:00'))

    expect(warnings).toEqual([])
    expect(items.map((i) => i.type)).toEqual(['interaction', 'relationship', 'followUp'])
    const relationship = items[1]
    if (relationship.type !== 'relationship') throw new Error('expected relationship')
    expect(relationship.other).toBeNull()
    expect(relationship.facts[0].attribute).toBe(FactAttributes.school)
  })

  it('rejects shapes that would corrupt a write', () => {
    expect(() => CaptureProposalSchema.parse({ ...FIXTURE, relationships: [{ subjectName: 'A', kind: 'cousin' }] })).toThrow()
    expect(() => CaptureProposalSchema.parse({ ...FIXTURE, facts: [{ personName: 'A', attribute: 'x', value: 'y', confidence: 'sure' }] })).toThrow()
  })
})

describe('the request', () => {
  it('pins the shape: chosen model, low effort, one user turn, structured format', () => {
    const params = buildRequestParams('claude-opus-5', 'SYSTEM', 'coffee with ana')
    expect(params.model).toBe('claude-opus-5')
    expect(params.max_tokens).toBe(8192)
    expect(params.output_config.effort).toBe('low')
    expect(params.output_config.format).toBeDefined()
    expect(params.messages).toEqual([{ role: 'user', content: 'coffee with ana' }])
    expect(params.system).toBe('SYSTEM')
  })

  it('writes the prompt with the date, the roster, and the never-invent rule', () => {
    const prompt = buildSystemPrompt({
      today: new Date('2026-08-06T15:00:00'),
      peopleNames: ['Ana Torres', 'Sam Ruiz'],
    })
    expect(prompt).toContain('Aug 06 2026')
    expect(prompt).toContain('Ana Torres; Sam Ruiz')
    expect(prompt).toContain('Never invent a name')
    expect(prompt).toContain('quickFact')
  })
})
