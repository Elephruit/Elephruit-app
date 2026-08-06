import { describe, expect, it } from 'vitest'
import { planFromResolved, resolveProposal, type CaptureProposal } from './assist'
import { makePerson } from './capture'
import { FactAttributes } from './facts'
import type { Person } from './person'

const NOW = new Date('2026-08-06T15:00:00')

function person(name: string, overrides: Partial<Person> = {}): Person {
  return { ...makePerson({ displayName: name }, NOW), id: `p-${name.toLowerCase().replace(/\s+/g, '-')}`, ...overrides }
}

const emptyProposal: CaptureProposal = {
  interaction: null,
  participantNames: [],
  facts: [],
  relationships: [],
  followUps: [],
}

const keepAll = (items: { id: string }[]) => new Set(items.map((i) => i.id))

describe('resolveProposal', () => {
  it('matches names case- and diacritic-insensitively', () => {
    const jose = person('José García')
    const { items, warnings } = resolveProposal(
      { ...emptyProposal, facts: [{ personName: 'jose garcia', attribute: 'location', value: 'Austin', confidence: 'stated' }] },
      [jose],
      NOW,
    )
    expect(items).toHaveLength(1)
    const fact = items[0]
    if (fact.type !== 'fact') throw new Error('expected fact')
    expect(fact.person).toEqual({ ref: 'existing', person: jose })
    expect(warnings).toEqual([])
  })

  it('creates an unknown person once, shared across every item that names them', () => {
    const { items } = resolveProposal(
      {
        ...emptyProposal,
        interaction: { kind: 'phone', summary: 'Caught up', discussion: null },
        participantNames: ['Jack Marsh'],
        facts: [{ personName: 'jack marsh', attribute: 'school', value: 'South High', confidence: 'stated' }],
      },
      [],
      NOW,
    )
    const interaction = items.find((i) => i.type === 'interaction')
    const fact = items.find((i) => i.type === 'fact')
    if (interaction?.type !== 'interaction' || fact?.type !== 'fact') throw new Error('bad shape')
    expect(interaction.participants[0].ref).toBe('create')
    expect(fact.person.ref).toBe('create')
    expect(interaction.participants[0].person.id).toBe(fact.person.person.id)
  })

  it('folds attributes through the curated registry and keeps custom ones', () => {
    const ana = person('Ana Torres')
    const { items } = resolveProposal(
      {
        ...emptyProposal,
        facts: [
          { personName: 'Ana Torres', attribute: 'School', value: 'South High', confidence: 'stated' },
          { personName: 'Ana Torres', attribute: 'coffee order', value: 'oat flat white', confidence: 'stated' },
        ],
      },
      [ana],
      NOW,
    )
    const [school, coffee] = items
    if (school.type !== 'fact' || coffee.type !== 'fact') throw new Error('bad shape')
    expect(school.attribute).toBe(FactAttributes.school)
    expect(coffee.attribute).toBe('coffee order')
  })

  it('warns and picks the most recently contacted when two people share a name', () => {
    const older = person('Ana Torres', { id: 'ana-1', lastContactAt: new Date('2026-01-01T12:00:00') })
    const newer = person('Ana Torres', { id: 'ana-2', lastContactAt: new Date('2026-08-01T12:00:00') })
    const { items, warnings } = resolveProposal(
      { ...emptyProposal, facts: [{ personName: 'Ana Torres', attribute: 'location', value: 'Austin', confidence: 'stated' }] },
      [older, newer],
      NOW,
    )
    const fact = items[0]
    if (fact.type !== 'fact') throw new Error('expected fact')
    expect(fact.person.person.id).toBe('ana-2')
    expect(warnings).toHaveLength(1)
  })
})

describe('planFromResolved', () => {
  it('handles a pure fact dump: observations only, no interaction, no source', () => {
    const ana = person('Ana Torres')
    const { items } = resolveProposal(
      { ...emptyProposal, facts: [{ personName: 'Ana Torres', attribute: 'employer', value: 'Alder Studio', confidence: 'inferred' }] },
      [ana],
      NOW,
    )
    const plan = planFromResolved(items, keepAll(items), NOW)
    expect(plan).toHaveLength(1)
    expect(plan[0].collection).toBe('observations')
    const data = (plan[0] as { data: { sourceInteractionID: string | null; confidence: string } }).data
    expect(data.sourceInteractionID).toBeNull()
    expect(data.confidence).toBe('inferred')
  })

  it('links follow-ups and facts to the interaction when it is kept', () => {
    const ana = person('Ana Torres')
    const { items } = resolveProposal(
      {
        ...emptyProposal,
        interaction: { kind: 'in-person', summary: 'Coffee with Ana', discussion: 'Talked about the move.' },
        participantNames: ['Ana Torres'],
        facts: [{ personName: 'Ana Torres', attribute: 'lives in', value: 'Portland soon', confidence: 'stated' }],
        followUps: [{ title: 'Send the neighborhood list', personNames: ['Ana Torres'] }],
      },
      [ana],
      NOW,
    )
    const plan = planFromResolved(items, keepAll(items), NOW)

    const interactionWrite = plan.find((w) => w.collection === 'interactions')
    const observationWrite = plan.find((w) => w.collection === 'observations')
    const reminderWrite = plan.find((w) => w.collection === 'reminders')
    if (!interactionWrite || interactionWrite.op !== 'set') throw new Error('no interaction')
    const interactionID = interactionWrite.id
    expect((observationWrite as { data: { sourceInteractionID: string } }).data.sourceInteractionID).toBe(interactionID)
    expect((reminderWrite as { data: { sourceInteractionID: string } }).data.sourceInteractionID).toBe(interactionID)
    // cache update for Ana rides in the same plan
    expect(plan.some((w) => w.collection === 'people' && w.op === 'update' && w.id === ana.id)).toBe(true)
  })

  it('drops unchecked items and never creates people only they referenced', () => {
    const { items } = resolveProposal(
      {
        ...emptyProposal,
        facts: [
          { personName: 'Ana Torres', attribute: 'location', value: 'Portland', confidence: 'stated' },
          { personName: 'Rob Vance', attribute: 'employer', value: 'Acme', confidence: 'stated' },
        ],
      },
      [person('Ana Torres')],
      NOW,
    )
    const keepFirst = new Set([items[0].id])
    const plan = planFromResolved(items, keepFirst, NOW)
    expect(plan).toHaveLength(1)
    expect(plan[0].collection).toBe('observations')
    // Rob was only named by the discarded item; nobody creates him.
    expect(plan.some((w) => w.collection === 'people')).toBe(false)
  })

  it('creates an unnamed relative with the phrase title and facts in one plan', () => {
    const ana = person('Ana Torres')
    const { items } = resolveProposal(
      {
        ...emptyProposal,
        relationships: [
          {
            subjectName: 'Ana Torres',
            kind: 'child',
            label: 'son',
            otherName: null,
            facts: [{ attribute: 'School', value: 'South High' }],
          },
        ],
      },
      [ana],
      NOW,
    )
    const plan = planFromResolved(items, keepAll(items), NOW)

    const personWrite = plan.find((w) => w.collection === 'people' && w.op === 'set')
    const relationshipWrites = plan.filter((w) => w.collection === 'relationships')
    const observationWrite = plan.find((w) => w.collection === 'observations')
    const created = (personWrite as { data: { displayName: string; hasStatedName: boolean } }).data
    expect(created.displayName).toBe("Ana Torres's son")
    expect(created.hasStatedName).toBe(false)
    expect(relationshipWrites).toHaveLength(2)
    const school = (observationWrite as { data: { attribute: string; value: string } }).data
    expect(school.attribute).toBe(FactAttributes.school)
    expect(school.value).toBe('South High')
  })

  it('moves nobody\'s last contact when the interaction is removed before save', () => {
    const kelly = person('Kelly Tsaur', { lastContactAt: null })
    const { items } = resolveProposal(
      {
        ...emptyProposal,
        interaction: { kind: 'other', summary: 'Harbinder introduced me to Kelly', discussion: null },
        participantNames: ['Kelly Tsaur', 'Harbinder Raina'],
        facts: [{ personName: 'Kelly Tsaur', attribute: 'employer', value: 'ZS', confidence: 'stated' }],
        followUps: [{ title: 'Attend Monday meeting', personNames: ['Kelly Tsaur'] }],
      },
      [kelly],
      NOW,
    )
    const withoutInteraction = new Set(items.filter((i) => i.type !== 'interaction').map((i) => i.id))
    const plan = planFromResolved(items, withoutInteraction, NOW)

    expect(plan.length).toBeGreaterThan(0)
    expect(plan.some((w) => w.collection === 'interactions')).toBe(false)
    // Last contact is only ever advanced inside an interaction bundle; profile
    // data alone must not pretend a conversation happened.
    expect(plan.some((w) => w.collection === 'people' && w.op === 'update')).toBe(false)
  })

  it('returns an empty plan when nothing is kept', () => {
    const { items } = resolveProposal(
      { ...emptyProposal, followUps: [{ title: 'Call back', personNames: [] }] },
      [],
      NOW,
    )
    expect(planFromResolved(items, new Set(), NOW)).toEqual([])
  })
})
