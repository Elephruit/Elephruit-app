import { describe, expect, it } from 'vitest'
import { resolveProposal, type CaptureProposal } from './assist'
import { makePerson } from './capture'
import { defaultMemoryTitle, makeMemoryRecord } from './memory'
import type { Person } from './person'
import { draftFromResolved, planFromReviewDraft, reviewDraftReducer } from './reviewDraft'

/// The feed-contract tests — the Phase 0 regression fixtures, now passing:
/// every non-empty save writes exactly one MemoryRecord referencing every
/// entity in the same atomic plan, so the Kelly/Harbinder state (facts, a
/// relationship, and a follow-up saved with the interaction removed) can
/// never again render a feed that claims nothing was logged.

const NOW = new Date('2026-08-06T15:00:00')
const CHICAGO = { timeZone: 'America/Chicago' }

function person(name: string, overrides: Partial<Person> = {}): Person {
  return { ...makePerson({ displayName: name }, NOW), id: `p-${name.toLowerCase().replace(/\s+/g, '-')}`, ...overrides }
}

const kellyHarbinderProposal: CaptureProposal = {
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

describe('feed contract (Kelly/Harbinder regression)', () => {
  it('a save with the interaction removed still writes something the feed can render', () => {
    let draft = draftFromResolved(resolveProposal(kellyHarbinderProposal, [], NOW), NOW)
    const interaction = draft.items.find((i) => i.type === 'interaction')!
    draft = reviewDraftReducer(draft, { type: 'remove-item', id: interaction.id })

    const { plan, memory } = planFromReviewDraft(draft, NOW, CHICAGO)

    // The save is real: two people, two facts, a relationship pair, a follow-up.
    expect(plan.filter((w) => w.collection === 'people' && w.op === 'set').length).toBeGreaterThanOrEqual(2)
    expect(plan.filter((w) => w.collection === 'observations')).toHaveLength(2)
    expect(plan.filter((w) => w.collection === 'relationships')).toHaveLength(2)
    expect(plan.filter((w) => w.collection === 'reminders')).toHaveLength(1)
    expect(plan.some((w) => w.collection === 'interactions')).toBe(false)

    // The contract: exactly one feed-visible memory record, in the same plan.
    const memoryWrites = plan.filter((w) => w.collection === 'memories')
    expect(memoryWrites).toHaveLength(1)
    expect(memory).not.toBeNull()
    expect(memory!.kind).toBe('profileUpdate')
    expect(memory!.interactionID).toBeNull()
    expect(memory!.observationIDs).toHaveLength(2)
    expect(memory!.relationshipIDs).toHaveLength(2)
    expect(memory!.reminderIDs).toHaveLength(1)
    expect(memory!.personIDs).toHaveLength(2)

    // Every referenced id is scheduled by this same plan — never dangling.
    const plannedIDs = new Set(plan.map((w) => w.id))
    for (const id of [
      ...memory!.observationIDs,
      ...memory!.relationshipIDs,
      ...memory!.reminderIDs,
      ...memory!.personIDs,
    ]) {
      expect(plannedIDs.has(id), `memory references unplanned id ${id}`).toBe(true)
    }

    // Nobody's last contact moved — no conversation happened.
    expect(plan.some((w) => w.collection === 'people' && w.op === 'update')).toBe(false)
  })

  it('a dossier-style save (facts only, no event at all) is feedable', () => {
    const dave = person('Dave Okafor')
    const draft = draftFromResolved(
      resolveProposal(
        {
          interaction: null,
          participantNames: [],
          facts: [{ personName: 'Dave Okafor', attribute: 'location', value: 'Chicago', confidence: 'stated' }],
          relationships: [],
          followUps: [],
        },
        [dave],
        NOW,
      ),
      NOW,
    )
    const { plan, memory } = planFromReviewDraft(draft, NOW, CHICAGO)
    expect(plan.length).toBeGreaterThan(0)
    expect(plan.filter((w) => w.collection === 'memories')).toHaveLength(1)
    expect(memory!.kind).toBe('profileUpdate')
    expect(memory!.title).toBe('Updated Dave Okafor')
  })

  it('keeping the interaction makes the memory an interaction at its occurred time', () => {
    const draft = draftFromResolved(resolveProposal(kellyHarbinderProposal, [], NOW), NOW)
    const { plan, memory } = planFromReviewDraft(draft, NOW, CHICAGO)
    expect(memory!.kind).toBe('interaction')
    expect(memory!.interactionID).not.toBeNull()
    expect(memory!.title).toBe('Harbinder introduced me to Kelly Tsaur')
    expect(plan.filter((w) => w.collection === 'memories')).toHaveLength(1)
    // Both participants receive last-contact state through the bundle.
    expect(plan.filter((w) => w.collection === 'people' && w.op === 'update')).toHaveLength(2)
  })

  it('an empty review saves nothing and creates no memory', () => {
    let draft = draftFromResolved(resolveProposal(kellyHarbinderProposal, [], NOW), NOW)
    for (const item of draft.items) {
      draft = reviewDraftReducer(draft, { type: 'remove-item', id: item.id })
    }
    const { plan, memory } = planFromReviewDraft(draft, NOW, CHICAGO)
    expect(plan).toEqual([])
    expect(memory).toBeNull()
  })
})

describe('memory titles', () => {
  it('follows the precedence ladder', () => {
    const kelly = { displayName: 'Kelly Tsaur' }
    const harbinder = { displayName: 'Harbinder Raina' }
    expect(
      defaultMemoryTitle({
        interactionSummary: 'Coffee with Ana',
        primaryPerson: kelly,
        createdPeople: [],
        hasFacts: true,
        hasRelationships: false,
      }),
    ).toBe('Coffee with Ana')
    expect(
      defaultMemoryTitle({
        interactionSummary: null,
        dossierFileCount: 3,
        primaryPerson: kelly,
        createdPeople: [],
        hasFacts: true,
        hasRelationships: false,
      }),
    ).toBe('Built out Kelly Tsaur from 3 files')
    expect(
      defaultMemoryTitle({
        interactionSummary: null,
        primaryPerson: kelly,
        createdPeople: [kelly],
        hasFacts: false,
        hasRelationships: false,
      }),
    ).toBe('Added Kelly Tsaur')
    expect(
      defaultMemoryTitle({
        interactionSummary: null,
        primaryPerson: kelly,
        createdPeople: [],
        connectedPair: [kelly, harbinder],
        hasFacts: false,
        hasRelationships: true,
      }),
    ).toBe('Connected Kelly Tsaur and Harbinder Raina')
    expect(
      defaultMemoryTitle({
        interactionSummary: null,
        primaryPerson: kelly,
        createdPeople: [],
        followUpOnly: true,
        hasFacts: false,
        hasRelationships: false,
      }),
    ).toBe('Added a follow-up for Kelly Tsaur')
    expect(
      defaultMemoryTitle({
        interactionSummary: null,
        primaryPerson: kelly,
        createdPeople: [],
        hasFacts: true,
        hasRelationships: true,
      }),
    ).toBe('Updated Kelly Tsaur')
  })

  it('the Kelly fixture defaults to Added Kelly Tsaur once the interaction is removed', () => {
    let draft = draftFromResolved(resolveProposal(kellyHarbinderProposal, [], NOW), NOW)
    const interaction = draft.items.find((i) => i.type === 'interaction')!
    draft = reviewDraftReducer(draft, { type: 'remove-item', id: interaction.id })
    // Facts + relationship + follow-up around Kelly → Updated Kelly Tsaur.
    expect(draft.title).toBe('Updated Kelly Tsaur')

    // A user-edited title survives further edits and is what gets saved.
    draft = reviewDraftReducer(draft, { type: 'update-title', title: 'Met Kelly via Harbinder' })
    const fact = draft.items.find((i) => i.type === 'fact')!
    draft = reviewDraftReducer(draft, { type: 'update-fact', id: fact.id, changes: { value: 'Vertical Head' } })
    expect(draft.title).toBe('Met Kelly via Harbinder')
    const { memory } = planFromReviewDraft(draft, NOW, CHICAGO)
    expect(memory!.title).toBe('Met Kelly via Harbinder')
  })
})

describe('makeMemoryRecord', () => {
  it('dedupes people and defaults collections empty', () => {
    const memory = makeMemoryRecord(
      { kind: 'manualUpdate', title: '  ', occurredAt: NOW, personIDs: ['a', 'a', 'b'], origin: 'manualFact' },
      NOW,
    )
    expect(memory.personIDs).toEqual(['a', 'b'])
    expect(memory.title).toBe('Memory')
    expect(memory.observationIDs).toEqual([])
  })
})
