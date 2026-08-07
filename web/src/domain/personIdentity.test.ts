import { describe, expect, it } from 'vitest'
import { makeObservation, makePerson, planRelativeCapture } from './capture'
import { FactAttributes } from './facts'
import {
  comparisonKey,
  relationshipIdentitySummary,
  unnamedPairSuggestions,
} from './personIdentity'
import type { Person } from './person'

const NOW = new Date('2026-08-06T15:00:00')

const dave: Person = { ...makePerson({ displayName: 'Dave Okafor' }, NOW), id: 'p-dave' }

function unnamedSon(facts: Array<{ attribute: string; value: string }>) {
  const { relative, pair } = planRelativeCapture(dave, { kind: 'child', label: 'son' }, NOW)
  const observations = facts.map((fact) =>
    makeObservation({ subjectID: relative.id, attribute: fact.attribute, value: fact.value }, NOW),
  )
  return { relative, forward: pair[0], observations }
}

describe('relationshipIdentitySummary', () => {
  it('renders the Dave fixture: two sons, distinguishable at a glance', () => {
    const first = unnamedSon([{ attribute: FactAttributes.school, value: 'Riverside Middle School' }])
    const second = unnamedSon([
      { attribute: FactAttributes.observedAge, value: '13' },
      { attribute: FactAttributes.schoolGrade, value: '8th' },
      { attribute: FactAttributes.quickFact, value: 'Sailor' },
    ])

    const a = relationshipIdentitySummary({
      subject: dave,
      other: first.relative,
      relationship: first.forward,
      observations: first.observations,
    })
    expect(a.primaryLabel).toBe('Son')
    expect(a.details.map((d) => d.value)).toEqual(['Riverside Middle School'])

    const b = relationshipIdentitySummary({
      subject: dave,
      other: second.relative,
      relationship: second.forward,
      observations: second.observations,
    })
    expect(b.primaryLabel).toBe('Son')
    expect(b.details.map((d) => d.value)).toEqual(['Age 13', '8th grade', 'Sailor'])
    expect(b.accessibleLabel).toBe('Son, Age 13, 8th grade, Sailor')
  })

  it('never repeats the possessive phrase for an unnamed person', () => {
    const { relative, forward } = unnamedSon([])
    const summary = relationshipIdentitySummary({ subject: dave, other: relative, relationship: forward, observations: [] })
    expect(summary.primaryLabel).toBe('Son')
    expect(summary.primaryLabel).not.toContain('Dave')
  })

  it('uses the name for named people and work priorities for colleagues', () => {
    const marisol: Person = { ...makePerson({ displayName: 'Marisol Vega' }, NOW), id: 'p-marisol' }
    const relationship = {
      id: 'r1',
      subjectID: dave.id,
      otherID: marisol.id,
      kind: 'colleague' as const,
      customLabel: null,
      reciprocalID: 'r2',
      createdAt: NOW,
    }
    const observations = [
      makeObservation({ subjectID: marisol.id, attribute: FactAttributes.role, value: 'Architect' }, NOW),
      makeObservation({ subjectID: marisol.id, attribute: FactAttributes.employer, value: 'Alder Studio' }, NOW),
    ]
    const summary = relationshipIdentitySummary({ subject: dave, other: marisol, relationship, observations })
    expect(summary.primaryLabel).toBe('Marisol Vega')
    expect(summary.details.map((d) => d.value)).toEqual(['Architect', 'Alder Studio'])
  })

  it('skips restricted facts', () => {
    const { relative, forward } = unnamedSon([])
    const restricted = makeObservation(
      { subjectID: relative.id, attribute: FactAttributes.observedAge, value: '13', sensitivity: 'restricted' },
      NOW,
    )
    const summary = relationshipIdentitySummary({
      subject: dave,
      other: relative,
      relationship: forward,
      observations: [restricted],
    })
    expect(summary.details).toEqual([])
  })
})

describe('unnamedPairSuggestions', () => {
  it('suggests comparing two unnamed sons but not a son and a daughter', () => {
    const son1 = unnamedSon([])
    const son2 = unnamedSon([])
    const daughter = planRelativeCapture(dave, { kind: 'child', label: 'daughter' }, NOW)
    const peopleByID = new Map<string, Person>([
      [son1.relative.id, son1.relative],
      [son2.relative.id, son2.relative],
      [daughter.relative.id, daughter.relative],
    ])
    const suggestions = unnamedPairSuggestions(
      [son1.forward, son2.forward, daughter.pair[0]],
      peopleByID,
      new Set(),
    )
    expect(suggestions).toHaveLength(1)
    expect(suggestions[0].people.map((p) => p.id).sort()).toEqual([son1.relative.id, son2.relative.id].sort())
  })

  it('honors dismissals order-independently', () => {
    const son1 = unnamedSon([])
    const son2 = unnamedSon([])
    const peopleByID = new Map<string, Person>([
      [son1.relative.id, son1.relative],
      [son2.relative.id, son2.relative],
    ])
    const key = comparisonKey(son2.relative, son1.relative)
    expect(unnamedPairSuggestions([son1.forward, son2.forward], peopleByID, new Set([key]))).toEqual([])
  })
})
