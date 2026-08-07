import { describe, expect, it } from 'vitest'
import {
  makePerson,
  planCorrection,
  planCreatePerson,
  planInteractionBundle,
  planNamePerson,
  planQuickReschedule,
  planRelativeCapture,
  planRenamePerson,
  planUpdatePersonContext,
  planUnrelate,
  emptyInteractionDraft,
  makeObservation,
  parseActionLines,
} from './capture'
import { FactAttributes } from './facts'
import type { Person } from './person'
import type { Relationship } from './relationships'

const NOW = new Date('2026-08-06T15:00:00')

function person(overrides: Partial<Person> & { displayName: string }): Person {
  return {
    ...makePerson({ displayName: overrides.displayName }, NOW),
    ...overrides,
    id: overrides.id ?? `p-${overrides.displayName.toLowerCase().replace(/\s+/g, '-')}`,
  }
}

describe('planInteractionBundle', () => {
  const ana = person({ displayName: 'Ana Torres', lastContactAt: new Date('2026-07-01T12:00:00') })
  const sam = person({ displayName: 'Sam Ruiz', lastContactAt: new Date('2026-08-10T12:00:00') })

  it('writes one interaction, one reminder per follow-up line, and only stale cache updates', () => {
    const draft = {
      ...emptyInteractionDraft(NOW),
      kind: 'phone' as const,
      participantIDs: [ana.id, sam.id, ana.id],
      summary: '  Caught up  ',
      discussion: '',
      followUps: 'Send neighborhood list\n\n  Book dinner  \n',
      occurredAt: new Date('2026-08-06T10:00:00'),
    }

    const { plan, interaction, reminders } = planInteractionBundle(draft, [ana, sam], NOW)

    expect(interaction.participantIDs).toEqual([ana.id, sam.id])
    expect(interaction.summary).toBe('Caught up')
    expect(interaction.discussion).toBeNull()
    expect(interaction.provenance).toBe('logged')

    expect(reminders.map((r) => r.title)).toEqual(['Send neighborhood list', 'Book dinner'])
    expect(reminders.every((r) => r.sourceInteractionID === interaction.id)).toBe(true)
    expect(reminders.every((r) => r.startAt === null && r.dueAt === null)).toBe(true)

    const cacheUpdates = plan.filter((w) => w.collection === 'people')
    expect(cacheUpdates).toHaveLength(1)
    expect(cacheUpdates[0].id).toBe(ana.id) // Sam's cache is already newer; it must not move backwards

    expect(plan).toHaveLength(1 + 2 + 1)
  })

  it('refuses a draft with no summary or no participants', () => {
    expect(() => planInteractionBundle({ ...emptyInteractionDraft(NOW), summary: 'x' }, [], NOW)).toThrow()
    expect(() =>
      planInteractionBundle({ ...emptyInteractionDraft(NOW), participantIDs: ['a'], summary: '  ' }, [], NOW),
    ).toThrow()
  })

  it('treats blank follow-up lines as nothing, not as errors', () => {
    expect(parseActionLines(' \n\n one \n two \n ')).toEqual(['one', 'two'])
    expect(parseActionLines('')).toEqual([])
  })
})

describe('facts planners', () => {
  it('corrects by appending: the replacement chains back and the note stays on the old row', () => {
    const old = makeObservation(
      { subjectID: 'ana', attribute: FactAttributes.location, value: 'Austin' },
      new Date('2025-01-01T12:00:00'),
    )

    const { plan, observation: next } = planCorrection(old, { value: 'Portland' }, ' misheard ', NOW)

    expect(next.supersedesID).toBe(old.id)
    expect(next.value).toBe('Portland')
    const update = plan.find((w) => w.op === 'update')
    expect(update).toMatchObject({
      collection: 'observations',
      id: old.id,
      data: { supersededOn: NOW, correctionNote: 'misheard' },
    })
    expect(plan).toHaveLength(2)
  })
})

describe('relative capture', () => {
  const dave = person({ displayName: 'Dave Marsh' })

  it('creates an unnamed relative as a first-class record titled by the phrase', () => {
    const { plan, relative, pair } = planRelativeCapture(
      dave,
      { kind: 'child', label: 'son', facts: [{ attribute: FactAttributes.school, value: 'South High' }] },
      NOW,
    )

    expect(relative.displayName).toBe("Dave Marsh's son")
    expect(relative.isPlaceholder).toBe(true)
    expect(relative.hasStatedName).toBe(false)
    expect(pair[0].customLabel).toBe('son')
    expect(pair[1].customLabel).toBeNull()

    const collections = plan.map((w) => w.collection)
    expect(collections).toEqual(['people', 'relationships', 'relationships', 'observations'])
  })

  it('creates a named relative as an ordinary person', () => {
    const { relative } = planRelativeCapture(dave, { kind: 'child', label: 'daughter', name: 'Rosa' }, NOW)
    expect(relative.displayName).toBe('Rosa')
    expect(relative.isPlaceholder).toBe(false)
    expect(relative.hasStatedName).toBe(true)
  })

  it('naming a placeholder touches only the person document, so every fact and relationship survives', () => {
    const { relative } = planRelativeCapture(
      dave,
      { kind: 'child', label: 'son', facts: [{ attribute: FactAttributes.school, value: 'South High' }] },
      NOW,
    )

    const { plan } = planNamePerson(relative, 'Jack Marsh', NOW)

    expect(plan).toHaveLength(1)
    const write = plan[0]
    if (write.op !== 'update') throw new Error('expected a single update')
    expect(write.collection).toBe('people')
    expect(write.id).toBe(relative.id)
    expect(write.data).toMatchObject({
      displayName: 'Jack Marsh',
      givenName: 'Jack',
      familyName: 'Marsh',
      hasStatedName: true,
      isPlaceholder: false,
    })
    // Nothing else is rewritten and nothing is deleted — observations and
    // relationship rows reference the person by ID and stay attached.
    expect(plan.some((w) => w.op === 'delete')).toBe(false)
    expect(plan.some((w) => w.collection === 'observations' || w.collection === 'relationships')).toBe(false)
  })

  it('refreshes dependent phrase titles when the subject is renamed', () => {
    const { relative, pair } = planRelativeCapture(dave, { kind: 'child', label: 'son' }, NOW)
    const peopleByID = new Map([
      [dave.id, dave],
      [relative.id, relative],
    ])

    const { plan } = planRenamePerson(dave, 'David Marsh', [pair[0]], peopleByID, NOW)

    const titleRefresh = plan.find((w) => w.id === relative.id)
    expect(titleRefresh).toMatchObject({ op: 'update', data: { displayName: "David Marsh's son" } })
  })

  it('unrelates both halves at once', () => {
    const forward: Relationship = {
      id: 'f',
      subjectID: 'a',
      otherID: 'b',
      kind: 'friend',
      customLabel: null,
      reciprocalID: 'b-side',
      createdAt: NOW,
    }
    const { plan } = planUnrelate(forward)
    expect(plan.map((w) => w.id).sort()).toEqual(['b-side', 'f'])
    expect(plan.every((w) => w.op === 'delete')).toBe(true)
  })
})

describe('reminder planners', () => {
  it('quick reschedule can only ever touch the start date', () => {
    const { plan } = planQuickReschedule('rem-1', new Date('2026-08-07T12:00:00'))
    expect(plan).toHaveLength(1)
    const write = plan[0]
    if (write.op !== 'update') throw new Error('expected update')
    expect(Object.keys(write.data).sort()).toEqual(['isSomeday', 'startAt', 'startPrecision'])
    expect(write.data.startPrecision).toBe('date')
    expect(write.data).not.toHaveProperty('dueAt')
  })
})

describe('people planners', () => {
  it('creates a person with a stable colour and split name', () => {
    const { person: p } = planCreatePerson({ displayName: '  Ana Torres ' }, NOW)
    expect(p.displayName).toBe('Ana Torres')
    expect(p.givenName).toBe('Ana')
    expect(p.familyName).toBe('Torres')
    const { person: again } = planCreatePerson({ displayName: 'Ana Torres' }, NOW)
    expect(again.colorName).toBe(p.colorName)
  })

  it('updates role and company through the shared person-context planner', () => {
    const kelly = person({ displayName: 'Kelly Tsaur' })

    expect(
      planUpdatePersonContext(kelly, {
        profileFocus: 'professional',
        roleTitle: 'Head of Vertical',
        organizationName: 'ZS',
      }).plan,
    ).toEqual([
      {
        op: 'update',
        collection: 'people',
        id: kelly.id,
        data: {
          profileFocus: 'professional',
          roleTitle: 'Head of Vertical',
          organizationName: 'ZS',
        },
      },
    ])
  })
})
