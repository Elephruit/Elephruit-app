import { describe, expect, it } from 'vitest'
import { resolveProposal, type CaptureProposal } from './assist'
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
