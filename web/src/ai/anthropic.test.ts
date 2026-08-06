import { describe, expect, it } from 'vitest'
import { planFromResolved, resolveProposal } from '../domain/assist'
import { FactAttributes } from '../domain/facts'
import { CaptureProposalSchema, buildRequestParams, buildSystemPrompt } from './anthropic'

const NO_SCHEDULE = {
  mode: 'none',
  localDate: null,
  localTime: null,
  timeZone: null,
  sourceText: null,
  confidence: 'stated',
} as const

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
  followUps: [{ title: 'Send the neighborhood list', personNames: ['Ana Torres'], notes: null, schedule: NO_SCHEDULE }],
}

const CONTEXT = {
  today: new Date('2026-08-06T15:00:00'),
  peopleNames: ['Ana Torres', 'Sam Ruiz'],
  locale: 'en-US',
  timeZone: 'America/Chicago',
  utcOffsetMinutes: -300,
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
    expect(() =>
      CaptureProposalSchema.parse({
        ...FIXTURE,
        followUps: [{ title: 'x', personNames: [], notes: null, schedule: { ...NO_SCHEDULE, mode: 'eventually' } }],
      }),
    ).toThrow()
  })
})

describe('the request', () => {
  it('pins the gateway shape: chosen model, low effort, one user turn, structured format', () => {
    const params = buildRequestParams('claude-opus-5', 'SYSTEM', 'coffee with ana')
    expect(params.provider).toBe('anthropic')
    expect(params.model).toBe('claude-opus-5')
    expect(params.maxTokens).toBe(8192)
    expect(params.effort).toBe('low')
    expect(params.outputFormat).toMatchObject({ type: 'json_schema' })
    expect(params.messages).toEqual([{ role: 'user', content: 'coffee with ana' }])
    expect(params.system).toBe('SYSTEM')
  })

  it('writes the prompt with the date, the roster, and the never-invent rule', () => {
    const prompt = buildSystemPrompt(CONTEXT)
    expect(prompt).toContain('Aug 06 2026')
    expect(prompt).toContain('Ana Torres; Sam Ruiz')
    expect(prompt).toContain('Never invent a name')
    expect(prompt).toContain('quickFact')
  })

  it('grounds temporal resolution in the user absolute date, zone, and offset', () => {
    const prompt = buildSystemPrompt(CONTEXT)
    expect(prompt).toContain('America/Chicago')
    expect(prompt).toContain('UTC−05:00')
    expect(prompt).toContain('Thursday, August 6, 2026')
  })

  it('teaches the deadline-vs-start distinction and the CT resolution rule', () => {
    const prompt = buildSystemPrompt(CONTEXT)
    expect(prompt).toContain('attendance obligations at a specific time are deadlines')
    expect(prompt).toContain('"Attend Monday 10am CT meeting" is a deadline')
    expect(prompt).toContain('"CT" means America/Chicago')
    expect(prompt).toContain('Never leave temporal wording only in the title')
  })

  it('teaches that introductions are interactions while biography is not', () => {
    const prompt = buildSystemPrompt(CONTEXT)
    expect(prompt).toContain('"Harbinder introduced me to Kelly"')
    expect(prompt).toContain('kind "other" when the channel is unknown')
    expect(prompt).toContain('"Kelly was introduced by Harbinder"')
  })
})

describe('the Harbinder/Kelly regression', () => {
  /// The exact expected model output for: "Harbinder introduced me to Kelly
  /// Tsaur, who is Head of Payer/Provider Industry Vertical at ZS. Attend
  /// Monday 10am CT meeting with Kelly." — pinned so resolution and planning
  /// behavior is proven deterministically, not by live model behavior.
  const KELLY_PROPOSAL = {
    interaction: {
      kind: 'other',
      summary: 'Harbinder introduced me to Kelly Tsaur',
      discussion: null,
    },
    participantNames: ['Kelly Tsaur', 'Harbinder Raina'],
    facts: [
      { personName: 'Kelly Tsaur', attribute: 'role', value: 'Head of Payer/Provider Industry Vertical', confidence: 'stated' },
      { personName: 'Kelly Tsaur', attribute: 'employer', value: 'ZS', confidence: 'stated' },
    ],
    relationships: [
      { subjectName: 'Kelly Tsaur', kind: 'introducedBy', label: null, otherName: 'Harbinder Raina', facts: [] },
    ],
    followUps: [
      {
        title: 'Attend Monday 10am CT meeting with Kelly Tsaur',
        personNames: ['Kelly Tsaur'],
        notes: null,
        schedule: {
          mode: 'deadline',
          localDate: '2026-08-10',
          localTime: '10:00',
          timeZone: 'America/Chicago',
          sourceText: 'Monday 10am CT',
          confidence: 'stated',
        },
      },
    ],
  }

  const NOW = new Date('2026-08-06T15:00:00')

  it('parses, resolves, and plans the meeting as a timed Central deadline', () => {
    const proposal = CaptureProposalSchema.parse(KELLY_PROPOSAL)
    const { items } = resolveProposal(proposal, [], NOW)
    const plan = planFromResolved(items, new Set(items.map((i) => i.id)), NOW, { timeZone: 'America/Chicago' })

    const reminderWrite = plan.find((w) => w.collection === 'reminders')
    if (!reminderWrite || reminderWrite.op !== 'set') throw new Error('no reminder write')
    const data = reminderWrite.data as {
      dueAt: Date
      startAt: Date | null
      duePrecision: string
      scheduleTimeZone: string
    }
    // Monday Aug 10 2026, 10:00 America/Chicago (CDT, UTC-5) = 15:00Z.
    expect(data.dueAt.toISOString()).toBe('2026-08-10T15:00:00.000Z')
    expect(data.startAt).toBeNull()
    expect(data.duePrecision).toBe('dateTime')
    expect(data.scheduleTimeZone).toBe('America/Chicago')
  })

  it('keeps the introduction as a removable interaction alongside the other items', () => {
    const proposal = CaptureProposalSchema.parse(KELLY_PROPOSAL)
    const { items } = resolveProposal(proposal, [], NOW)
    expect(items.map((i) => i.type)).toEqual(['interaction', 'fact', 'fact', 'relationship', 'followUp'])

    const interaction = items[0]
    if (interaction.type !== 'interaction') throw new Error('expected interaction')
    expect(interaction.kind).toBe('other')
    expect(interaction.participants).toHaveLength(2)

    // Removing the interaction keeps everything else plannable.
    const withoutInteraction = new Set(items.filter((i) => i.type !== 'interaction').map((i) => i.id))
    const plan = planFromResolved(items, withoutInteraction, NOW, { timeZone: 'America/Chicago' })
    expect(plan.some((w) => w.collection === 'interactions')).toBe(false)
    expect(plan.filter((w) => w.collection === 'observations')).toHaveLength(2)
    expect(plan.filter((w) => w.collection === 'relationships')).toHaveLength(2)
    expect(plan.filter((w) => w.collection === 'reminders')).toHaveLength(1)
  })
})
