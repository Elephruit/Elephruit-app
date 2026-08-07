import { describe, expect, it } from 'vitest'
import { makeMemoryRecord } from '../domain/memory'
import { makeObservation, makePerson, planInteractionBundle, emptyInteractionDraft } from '../domain/capture'
import { relationshipPair } from '../domain/relationships'
import type { Reminder } from '../domain/reminders'
import { legacyMemoryProjection, projectFeed, projectMemories, type ProjectionEntities } from './memoryProjection'

const NOW = new Date('2026-08-06T15:00:00')

function reminder(overrides: Partial<Reminder> & { id: string }): Reminder {
  return {
    title: 'Follow up',
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

function base(): ProjectionEntities {
  return { memories: [], people: [], interactions: [], observations: [], relationships: [], reminders: [], sources: [] }
}

const kelly = { ...makePerson({ displayName: 'Kelly Tsaur' }, NOW), id: 'p-kelly' }
const harbinder = { ...makePerson({ displayName: 'Harbinder Raina' }, NOW), id: 'p-harbinder' }

describe('projectMemories', () => {
  it('renders the Kelly profileUpdate as one composite moment', () => {
    const fact1 = makeObservation({ subjectID: kelly.id, attribute: 'role', value: 'Head of Vertical' }, NOW)
    const fact2 = makeObservation({ subjectID: kelly.id, attribute: 'employer', value: 'ZS' }, NOW)
    const pair = relationshipPair({ subjectID: kelly.id, otherID: harbinder.id, kind: 'introducedBy', now: NOW })
    const followUp = reminder({ id: 'rem-1', title: 'Attend Monday meeting', personIDs: [kelly.id] })
    const memory = makeMemoryRecord(
      {
        kind: 'profileUpdate',
        title: 'Added Kelly Tsaur',
        occurredAt: NOW,
        personIDs: [kelly.id, harbinder.id],
        observationIDs: [fact1.id, fact2.id],
        relationshipIDs: [pair[0].id, pair[1].id],
        reminderIDs: ['rem-1'],
        origin: 'capture',
      },
      NOW,
    )

    const moments = projectMemories({
      ...base(),
      memories: [memory],
      people: [kelly, harbinder],
      observations: [fact1, fact2],
      relationships: [...pair],
      reminders: [followUp],
    })

    expect(moments).toHaveLength(1)
    const moment = moments[0]
    expect(moment.title).toBe('Added Kelly Tsaur')
    expect(moment.provenanceLabel).toBe('Profile update')
    expect(moment.isContact).toBe(false)
    expect(moment.people.map((p) => p.displayName)).toEqual(['Kelly Tsaur', 'Harbinder Raina'])
    expect(moment.details).toHaveLength(2)
    // The relationship pair renders once, not twice.
    expect(moment.relationships).toHaveLength(1)
    expect(moment.followUps).toHaveLength(1)
  })

  it('labels an interaction memory with its provenance phrase and contact state', () => {
    const { interaction } = planInteractionBundle(
      { ...emptyInteractionDraft(NOW), participantIDs: [kelly.id], summary: 'Coffee', occurredAt: NOW },
      [kelly],
      NOW,
    )
    const memory = makeMemoryRecord(
      {
        kind: 'interaction',
        title: 'Coffee',
        occurredAt: NOW,
        personIDs: [kelly.id],
        interactionID: interaction.id,
        origin: 'capture',
      },
      NOW,
    )
    const [moment] = projectMemories({ ...base(), memories: [memory], people: [kelly], interactions: [interaction] })
    expect(moment.provenanceLabel).toBe('in person — logged')
    expect(moment.isContact).toBe(true)
    expect(moment.interactionKind).toBe('in-person')
  })
})

describe('legacyMemoryProjection', () => {
  it('synthesizes one moment per unreferenced interaction, absorbing its sourced entities', () => {
    const { interaction } = planInteractionBundle(
      { ...emptyInteractionDraft(NOW), participantIDs: [kelly.id], summary: 'Coffee', occurredAt: NOW },
      [kelly],
      NOW,
    )
    const sourced = makeObservation(
      { subjectID: kelly.id, attribute: 'location', value: 'Chicago', sourceInteractionID: interaction.id },
      NOW,
    )
    const sourcedReminder = reminder({ id: 'rem-2', sourceInteractionID: interaction.id })

    const moments = legacyMemoryProjection({
      ...base(),
      people: [kelly],
      interactions: [interaction],
      observations: [sourced],
      reminders: [sourcedReminder],
    })

    expect(moments).toHaveLength(1)
    expect(moments[0].id).toBe(`legacy-interaction-${interaction.id}`)
    expect(moments[0].details).toHaveLength(1)
    expect(moments[0].followUps).toHaveLength(1)
    expect(moments[0].legacy).toBe(true)
  })

  it('excludes entities referenced by real memories so nothing renders twice', () => {
    const fact = makeObservation({ subjectID: kelly.id, attribute: 'role', value: 'Head' }, NOW)
    const memory = makeMemoryRecord(
      { kind: 'profileUpdate', title: 'Updated Kelly Tsaur', occurredAt: NOW, personIDs: [kelly.id], observationIDs: [fact.id], origin: 'capture' },
      NOW,
    )
    const entities: ProjectionEntities = { ...base(), memories: [memory], people: [kelly], observations: [fact] }
    expect(legacyMemoryProjection(entities)).toHaveLength(0)
    expect(projectFeed(entities)).toHaveLength(1)
  })

  it('projects standalone facts, relationship pairs, and reminders exactly once with stable ids', () => {
    const fact = makeObservation({ subjectID: kelly.id, attribute: 'role', value: 'Head' }, NOW)
    const pair = relationshipPair({ subjectID: kelly.id, otherID: harbinder.id, kind: 'colleague', now: NOW })
    const standalone = reminder({ id: 'rem-3', personIDs: [kelly.id] })

    const entities: ProjectionEntities = {
      ...base(),
      people: [kelly, harbinder],
      observations: [fact],
      relationships: [...pair],
      reminders: [standalone],
    }
    const first = legacyMemoryProjection(entities)
    const second = legacyMemoryProjection(entities)

    expect(first.map((m) => m.id)).toEqual(second.map((m) => m.id))
    expect(first).toHaveLength(3) // fact + one pair moment + reminder
    expect(first.filter((m) => m.id.startsWith('legacy-relationship'))).toHaveLength(1)
  })

  it('keeps superseded observations out of the feed', () => {
    const old = makeObservation({ subjectID: kelly.id, attribute: 'role', value: 'Old role' }, NOW)
    old.supersededOn = NOW
    expect(legacyMemoryProjection({ ...base(), people: [kelly], observations: [old] })).toHaveLength(0)
  })
})
