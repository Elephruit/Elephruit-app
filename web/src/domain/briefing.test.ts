import { describe, expect, it } from 'vitest'
import { briefingInputFor, defaultBriefingPersonIDs } from './briefing'
import { makeObservation, makePerson, planRelativeCapture } from './capture'
import type { Interaction } from './interaction'
import type { Reminder } from './reminders'

const NOW = new Date('2026-08-06T10:00:00')

function reminder(overrides: Partial<Reminder>): Reminder {
  return {
    id: Math.random().toString(36).slice(2),
    title: 'Something owed',
    notes: null,
    personIDs: [],
    sourceInteractionID: null,
    startAt: null,
    dueAt: null,
    isSomeday: false,
    status: 'open',
    completedAt: null,
    createdAt: NOW,
    ...overrides,
  }
}

function interaction(personID: string, daysAgo: number, summary: string, discussion: string | null = null): Interaction {
  return {
    id: Math.random().toString(36).slice(2),
    kind: 'in-person',
    provenance: 'logged',
    summary,
    discussion,
    participantIDs: [personID],
    occurredAt: new Date(NOW.getTime() - daysAgo * 86_400_000),
    createdAt: NOW,
  }
}

describe('defaultBriefingPersonIDs', () => {
  it('collects overdue people first, then today, deduplicated, skipping completed', () => {
    const ids = defaultBriefingPersonIDs(
      [
        reminder({ personIDs: ['ana'], dueAt: new Date('2026-07-31T12:00:00') }),
        reminder({ personIDs: ['ana', 'priya'], dueAt: new Date('2026-08-06T18:00:00') }),
        reminder({ personIDs: ['dave'], dueAt: new Date('2026-07-30T12:00:00'), status: 'completed', completedAt: NOW }),
        reminder({ personIDs: ['jonas'] }),
      ],
      NOW,
    )
    expect(ids).toEqual(['ana', 'priya'])
  })
})

describe('briefingInputFor', () => {
  const ana = makePerson({ displayName: 'Ana Torres', roleTitle: 'Designer', organizationName: 'Meridian' }, NOW)
  ana.lastContactAt = new Date('2026-08-06T09:00:00')

  it('carries current facts with decayed confidence, and never restricted ones', () => {
    const employer = makeObservation(
      { subjectID: ana.id, attribute: 'employer', value: 'Meridian Labs' },
      new Date('2026-08-01T12:00:00'),
    )
    const health = makeObservation(
      { subjectID: ana.id, attribute: 'health', value: 'Knee surgery', sensitivity: 'restricted' },
      NOW,
    )
    const oldLocation = makeObservation(
      { subjectID: ana.id, attribute: 'location', value: 'Lisbon' },
      new Date('2023-08-01T12:00:00'),
    )

    const input = briefingInputFor(
      [ana],
      new Map([[ana.id, [employer, health, oldLocation]]]),
      [],
      new Map([[ana.id, ana]]),
      [],
      [],
      NOW,
    )

    const serialized = JSON.stringify(input)
    expect(serialized).not.toContain('Knee surgery')
    expect(serialized).toContain('Meridian Labs')
    const location = input.people[0].facts.find((fact) => fact.value === 'Lisbon')
    expect(location?.confidence).toBeDefined()
    const employerFact = input.people[0].facts.find((fact) => fact.value === 'Meridian Labs')
    expect(employerFact?.confidence).toBeUndefined()
  })

  it('phrases relationships, follow-ups, and recent history compactly', () => {
    const capture = planRelativeCapture(ana, { kind: 'child', label: 'son' }, NOW)
    const son = capture.relative
    const [forward] = capture.pair

    const input = briefingInputFor(
      [ana],
      new Map(),
      [forward],
      new Map([
        [ana.id, ana],
        [son.id, son],
      ]),
      [
        reminder({ personIDs: [ana.id], title: 'Book flights', dueAt: new Date('2026-08-06T21:00:00') }),
        reminder({ personIDs: [ana.id], title: 'Send intro', dueAt: new Date('2026-07-31T12:00:00') }),
        reminder({ personIDs: [ana.id], title: 'Share hiring plan', responsibility: 'theirs' }),
        reminder({ personIDs: ['someone-else'], title: 'Not hers' }),
      ],
      [
        interaction(ana.id, 0, 'Coffee', 'A discussion well beyond one hundred and forty characters — ' + 'x'.repeat(160)),
        interaction(ana.id, 1, 'Call'),
        interaction(ana.id, 2, 'Lunch'),
        interaction(ana.id, 3, 'Walk'),
        interaction(ana.id, 4, 'Email'),
        interaction(ana.id, 5, 'Too old to include'),
      ],
      NOW,
    )

    const person = input.people[0]
    expect(person.relationships).toEqual([`son: unnamed ("Ana Torres's son")`])
    expect(person.myNextMoves).toEqual(['Book flights (due today)', 'Send intro (due 6 days ago)'])
    expect(person.waitingOnThem).toEqual(['Share hiring plan'])
    expect(person.recentInteractions).toHaveLength(5)
    expect(person.recentInteractions.map((i) => i.summary)).not.toContain('Too old to include')
    expect(person.recentInteractions[0].notes!.length).toBeLessThanOrEqual(141)
    expect(person.role).toBe('Designer · Meridian')
    expect(person.lastContact.toLowerCase()).toContain('today')
  })
})
