import { describe, expect, it } from 'vitest'
import { DayBriefSchema, buildBriefingRequestParams, buildBriefingSystemPrompt } from './briefing'

const INPUT = {
  date: 'Thursday, August 6, 2026',
  people: [
    {
      name: 'Ana Torres',
      role: 'Designer · Meridian',
      lastContact: 'Last spoke today',
      facts: [{ label: 'Lives in', value: 'Lisbon', confidence: 'Estimated' }],
      relationships: ['partner: Tomás Silva'],
      openFollowUps: ['Book flights (due today)'],
      recentInteractions: [{ when: 'Aug 6', kind: 'in-person', summary: 'Coffee', notes: null }],
    },
  ],
}

describe('the day brief', () => {
  it('accepts a well-formed brief and rejects a malformed one', () => {
    const brief = DayBriefSchema.parse({
      people: [
        {
          name: 'Ana Torres',
          headline: 'Mid-move to Denver, launch behind her.',
          talkingPoints: ['The flat hunt'],
          openLoops: ['You owe her flight bookings today'],
          suggestedQuestions: ['Is Lisbon still home base?'],
        },
      ],
      dayNote: null,
    })
    expect(brief.people[0].name).toBe('Ana Torres')
    expect(() => DayBriefSchema.parse({ people: [{ name: 'X' }], dayNote: null })).toThrow()
  })

  it('pins the gateway request shape: chosen model, low effort, the payload as one user turn', () => {
    const params = buildBriefingRequestParams('claude-opus-5', INPUT)
    expect(params.provider).toBe('anthropic')
    expect(params.model).toBe('claude-opus-5')
    expect(params.maxTokens).toBe(8192)
    expect(params.effort).toBe('low')
    expect(params.outputFormat).toMatchObject({ type: 'json_schema' })
    expect(params.messages).toEqual([{ role: 'user', content: JSON.stringify(INPUT) }])
  })

  it('tells the model the rules that matter: only the records, no invention, confirm the uncertain', () => {
    const prompt = buildBriefingSystemPrompt()
    expect(prompt).toContain('Never invent')
    expect(prompt).toContain('only the records provided')
    expect(prompt.toLowerCase()).toContain('confirm')
  })
})
