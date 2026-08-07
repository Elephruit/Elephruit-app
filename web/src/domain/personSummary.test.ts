import { describe, expect, it } from 'vitest'
import { makeObservation, makePerson } from './capture'
import { FactAttributes } from './facts'
import { professionalIdentityOf, summarizePerson } from './personSummary'
import { relationshipPair } from './relationships'

const NOW = new Date('2026-08-06T18:00:00Z')

describe('summarizePerson', () => {
  it('fills company and role from current observations', () => {
    const kelly = { ...makePerson({ displayName: 'Kelly Tsaur' }, NOW), id: 'kelly' }
    const role = makeObservation({ subjectID: kelly.id, attribute: FactAttributes.role, value: 'Head of Vertical' }, NOW)
    const employer = makeObservation({ subjectID: kelly.id, attribute: FactAttributes.employer, value: 'ZS' }, NOW)

    const summary = summarizePerson({ person: kelly, people: [kelly], observations: [role, employer], relationships: [], interactions: [], reminders: [], now: NOW })

    expect(summary.role).toBe('Head of Vertical')
    expect(summary.organization).toBe('ZS')
  })

  it('resolves professional identity for list rows from observations', () => {
    const kelly = { ...makePerson({ displayName: 'Kelly Tsaur' }, NOW), id: 'kelly' }
    const role = makeObservation({ subjectID: kelly.id, attribute: FactAttributes.role, value: 'Head of Vertical' }, NOW)
    const employer = makeObservation({ subjectID: kelly.id, attribute: FactAttributes.employer, value: 'ZS' }, NOW)

    expect(professionalIdentityOf(kelly, [role, employer])).toEqual({
      role: 'Head of Vertical',
      organization: 'ZS',
    })
  })

  it('surfaces an introducer from the existing reciprocal relationship model', () => {
    const kelly = { ...makePerson({ displayName: 'Kelly Tsaur' }, NOW), id: 'kelly' }
    const harbinder = { ...makePerson({ displayName: 'Harbinder Raina' }, NOW), id: 'harbinder' }
    const [introducedBy] = relationshipPair({ subjectID: kelly.id, otherID: harbinder.id, kind: 'introducedBy', now: NOW })

    const summary = summarizePerson({ person: kelly, people: [kelly, harbinder], observations: [], relationships: [introducedBy], interactions: [], reminders: [], now: NOW })

    expect(summary.introducedBy?.displayName).toBe('Harbinder Raina')
  })
})
