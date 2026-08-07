import { describe, expect, it } from 'vitest'
import {
  DEFAULT_FOLLOW_UP_THRESHOLD_DAYS,
  deriveLastContact,
  followUpSuggestions,
  lastContactLine,
  relativeDescription,
} from './contact'
import { provenancePhrase, type Interaction, type InteractionProvenance } from './interaction'

const NOW = new Date('2026-08-06T15:00:00')

let counter = 0
function interaction(overrides: Partial<Interaction>): Interaction {
  counter += 1
  return {
    id: `int-${counter}`,
    kind: 'phone',
    provenance: 'logged',
    summary: 'Caught up',
    discussion: null,
    participantIDs: ['ana'],
    occurredAt: new Date('2026-08-01T10:00:00'),
    createdAt: new Date('2026-08-01T10:05:00'),
    ...overrides,
  }
}

describe('deriveLastContact', () => {
  it('takes the newest logged interaction the person took part in', () => {
    const older = interaction({ occurredAt: new Date('2026-07-01T12:00:00') })
    const newest = interaction({ occurredAt: new Date('2026-08-03T12:00:00') })
    const someoneElse = interaction({ participantIDs: ['sam'], occurredAt: new Date('2026-08-05T12:00:00') })
    expect(deriveLastContact([older, newest, someoneElse], 'ana')).toEqual(new Date('2026-08-03T12:00:00'))
  })

  it('never counts initiated or detected interactions as contact', () => {
    const pressed: InteractionProvenance[] = ['initiated', 'detected']
    const interactions = pressed.map((provenance) =>
      interaction({ provenance, occurredAt: new Date('2026-08-05T12:00:00') }),
    )
    expect(deriveLastContact(interactions, 'ana')).toBeNull()

    const spoke = interaction({ occurredAt: new Date('2026-07-15T12:00:00') })
    expect(deriveLastContact([...interactions, spoke], 'ana')).toEqual(new Date('2026-07-15T12:00:00'))
  })
})

describe('relative phrasing', () => {
  it('reads naturally at every distance', () => {
    expect(relativeDescription(new Date('2026-08-06T09:00:00'), NOW)).toBe('today')
    expect(relativeDescription(new Date('2026-08-05T12:00:00'), NOW)).toBe('yesterday')
    expect(relativeDescription(new Date('2026-08-03T12:00:00'), NOW)).toBe('3 days ago')
    expect(relativeDescription(new Date('2026-07-28T12:00:00'), NOW)).toBe('last week')
    expect(relativeDescription(new Date('2026-07-16T12:00:00'), NOW)).toBe('3 weeks ago')
    expect(relativeDescription(new Date('2026-04-01T12:00:00'), NOW)).toBe('4 months ago')
    expect(relativeDescription(new Date('2026-08-07T12:00:00'), NOW)).toBe('tomorrow')
    expect(relativeDescription(new Date('2026-08-10T12:00:00'), NOW)).toBe('in 4 days')
  })

  it('summarises the top of a person page without inventing history', () => {
    expect(lastContactLine(null, NOW)).toBe('Nothing recorded yet')
    expect(lastContactLine(null, NOW, true)).toBe('No conversations logged yet')
    // A real conversation wins over profile data either way.
    expect(lastContactLine(new Date('2026-08-05T12:00:00'), NOW)).toBe('Last spoke yesterday')
    expect(lastContactLine(new Date('2026-08-05T12:00:00'), NOW, true)).toBe('Last spoke yesterday')
  })

  it('opens a timeline row with the provenance phrase', () => {
    expect(provenancePhrase('logged', 'phone')).toBe('phone — logged')
    expect(provenancePhrase('initiated', 'email')).toBe('email started from Elephruit')
    expect(provenancePhrase('detected', null)).toBe('detected from your calendar')
  })
})

describe('followUpSuggestions', () => {
  it('suggests only past the threshold, never for zero contact, most overdue first', () => {
    const people = [
      { personID: 'a', displayName: 'Ana', lastContactAt: new Date('2026-06-25T12:00:00') }, // 42 days
      { personID: 'b', displayName: 'Ben', lastContactAt: new Date('2026-06-26T12:00:00') }, // 41 days
      { personID: 'c', displayName: 'Cleo', lastContactAt: new Date('2026-01-01T12:00:00') }, // long ago
      { personID: 'd', displayName: 'Drew', lastContactAt: null },
    ]

    const suggestions = followUpSuggestions(people, NOW)
    expect(suggestions.map((s) => s.personID)).toEqual(['c', 'a'])
    expect(suggestions[1].daysSinceContact).toBe(DEFAULT_FOLLOW_UP_THRESHOLD_DAYS)
  })
})
