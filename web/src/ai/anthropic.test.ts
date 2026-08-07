import { describe, expect, it } from 'vitest'
import { resolveProposal } from '../domain/assist'
import { FactAttributes } from '../domain/facts'
import { draftFromResolved, planFromReviewDraft, reviewDraftReducer } from '../domain/reviewDraft'
import { CaptureProposalSchema, buildRequestParams, buildSystemPrompt, extractJsonPayload, normalizeCaptureProposal } from './anthropic'

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
    occurredAt: null,
  },
  participantNames: ['Ana Torres'],
  personContexts: [],
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
  followUps: [{ title: 'Send the neighborhood list', personNames: ['Ana Torres'], notes: null, schedule: NO_SCHEDULE, responsibility: 'mine', progress: 'notStarted', tags: ['Work', 'Important'], folderPath: null }],
  reminderChanges: [],
  factChanges: [],
  relationshipChanges: [],
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

  it('repairs omitted optional fields and string-shaped arrays without losing the capture', () => {
    const proposal = normalizeCaptureProposal({
      interaction: { kind: 'coffee', summary: 'Coffee with Madeline' },
      participantNames: 'Madeline Brooks',
      personContexts: [{ personName: 'Madeline Brooks' }],
      facts: [{ personName: 'Madeline Brooks', attribute: 'city', value: 'Chicago Suburbs' }],
      followUps: [{ title: 'Send Madeline the details', personNames: 'Madeline Brooks', tags: 'Personal' }],
    })

    expect(proposal.interaction).toMatchObject({ kind: 'in-person', discussion: null, occurredAt: null })
    expect(proposal.participantNames).toEqual(['Madeline Brooks'])
    expect(proposal.personContexts).toEqual([
      expect.objectContaining({ roleTitle: null, organizationName: null, connectionStatus: 'unknown' }),
    ])
    expect(proposal.facts[0]).toMatchObject({ confidence: 'stated', sensitivity: 'normal', context: 'personal' })
    expect(proposal.followUps[0]).toMatchObject({
      personNames: ['Madeline Brooks'],
      tags: ['Personal'],
      schedule: NO_SCHEDULE,
    })
    expect(proposal.normalizationWarnings).toEqual(expect.arrayContaining([
      expect.stringContaining('participant names as text'),
      expect.stringContaining('follow-up names as text'),
      expect.stringContaining('tags as text'),
    ]))
  })

  it('normalizes relationship aliases, preserves their labels, and accepts string facts', () => {
    const proposal = normalizeCaptureProposal({
      relationships: [
        { subjectName: 'Madeline Brooks', kind: 'twin sister', otherName: 'Morgan Brooks', facts: ['lives in Chicago Suburbs'] },
        { subjectName: 'Madeline Brooks', kind: 'niece and nephew', facts: [] },
        { subjectName: 'Madeline Brooks', kind: 'connection', otherName: 'Alex Kim' },
      ],
    })

    expect(proposal.relationships).toEqual([
      expect.objectContaining({ kind: 'sibling', label: 'twin sister', facts: [{ attribute: 'detail', value: 'lives in Chicago Suburbs' }] }),
      expect.objectContaining({ kind: 'child', label: 'niece and nephew' }),
      expect.objectContaining({ kind: 'friend', label: 'connection' }),
    ])
  })

  it('preserves unknown relationship labels for review without guessing their meaning', () => {
    const proposal = normalizeCaptureProposal({
      relationships: [{ subjectName: 'Madeline Brooks', kind: 'godparent', otherName: 'Pat', facts: ['Lives nearby'] }],
      facts: ['lives in Chicago Suburbs'],
      reminderChanges: [{ action: 'delete' }],
    })
    const resolved = resolveProposal(proposal, [], new Date('2026-08-06T15:00:00'))

    expect(proposal.relationships).toEqual([
      expect.objectContaining({ kind: 'unknown', label: 'godparent', facts: [{ attribute: 'detail', value: 'Lives nearby' }] }),
    ])
    expect(proposal.taxonomyGaps).toEqual([{ field: 'relationship.kind', value: 'godparent' }])
    expect(proposal.reminderChanges).toEqual([])
    expect(resolved.items).toHaveLength(1)
    expect(resolved.warnings).toEqual(expect.arrayContaining([
      expect.stringContaining('not in the relationship taxonomy'),
      expect.stringContaining('fact without both a person and value'),
      expect.stringContaining('invalid follow-up change'),
    ]))
  })

  it('extracts a JSON object from fenced or prefaced provider text', () => {
    expect(extractJsonPayload('```json\n{"participantNames": []}\n```')).toBe('{"participantNames": []}')
    expect(extractJsonPayload('Here is the result: {"participantNames": []}')).toBe('{"participantNames": []}')
  })
})

describe('the request', () => {
  it('pins the gateway shape without provider-specific structured-output options', () => {
    const params = buildRequestParams('claude-opus-5', 'SYSTEM', 'coffee with ana')
    expect(params.provider).toBe('anthropic')
    expect(params.model).toBe('claude-opus-5')
    expect(params.maxTokens).toBe(8192)
    expect(params).not.toHaveProperty('effort')
    expect(params).not.toHaveProperty('outputFormat')
    expect(params.messages).toEqual([{ role: 'user', content: 'coffee with ana' }])
    expect(params.system).toBe('SYSTEM')
  })

  it('writes the prompt with the date, the roster, and the never-invent rule', () => {
    const prompt = buildSystemPrompt(CONTEXT)
    expect(prompt).toContain('Aug 06 2026')
    expect(prompt).toContain('Ana Torres; Sam Ruiz')
    expect(prompt).toContain('Never invent a name')
    expect(prompt).toContain('quickFact')
    expect(prompt).toContain('folderPath preserves one folder name or slash-separated path')
    expect(prompt).toContain('Tags never substitute for a folder')
    expect(prompt).toContain('Return only one raw JSON object')
    expect(prompt).toContain('Always include these top-level keys')
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
      occurredAt: null,
    },
    participantNames: ['Kelly Tsaur', 'Harbinder Raina'],
    personContexts: [],
    facts: [
      { personName: 'Kelly Tsaur', attribute: 'role', value: 'Head of Payer/Provider Industry Vertical', confidence: 'stated', sensitivity: 'normal', context: 'professional', observedOn: null, effectiveOn: null },
      { personName: 'Kelly Tsaur', attribute: 'employer', value: 'ZS', confidence: 'stated', sensitivity: 'normal', context: 'professional', observedOn: null, effectiveOn: null },
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
        responsibility: 'mine',
        progress: 'notStarted',
        tags: [],
        folderPath: null,
      },
    ],
    reminderChanges: [],
    factChanges: [],
    relationshipChanges: [],
  }

  const NOW = new Date('2026-08-06T15:00:00')

  it('parses, resolves, and plans the meeting as a timed Central deadline', () => {
    const proposal = CaptureProposalSchema.parse(KELLY_PROPOSAL)
    const draft = draftFromResolved(resolveProposal(proposal, [], NOW), NOW)
    const { plan } = planFromReviewDraft(draft, NOW, { timeZone: 'America/Chicago' })

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
    expect(items.map((i) => i.type)).toEqual(['interaction', 'personContext', 'fact', 'fact', 'relationship', 'followUp'])

    const interaction = items[0]
    if (interaction.type !== 'interaction') throw new Error('expected interaction')
    expect(interaction.kind).toBe('other')
    expect(interaction.participants).toHaveLength(2)

    // Removing the interaction keeps everything else plannable.
    let draft = draftFromResolved({ items, warnings: [] }, NOW)
    const interactionItem = draft.items.find((i) => i.type === 'interaction')!
    draft = reviewDraftReducer(draft, { type: 'remove-item', id: interactionItem.id })
    const { plan } = planFromReviewDraft(draft, NOW, { timeZone: 'America/Chicago' })
    expect(plan.some((w) => w.collection === 'interactions')).toBe(false)
    expect(plan.filter((w) => w.collection === 'observations')).toHaveLength(2)
    expect(plan.filter((w) => w.collection === 'relationships')).toHaveLength(2)
    expect(plan.filter((w) => w.collection === 'reminders')).toHaveLength(1)
  })
})
