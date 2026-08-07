import { describe, expect, it } from 'vitest'
import { resolveProposal, type CaptureProposal } from './assist'
import { makePerson } from './capture'
import type { Person } from './person'
import type { Reminder } from './reminders'
import {
  activeItems,
  draftFromResolved,
  planFromReviewDraft,
  reviewDraftReducer,
  slotPerson,
  validateDraft,
  type ResolvedCaptureDraft,
} from './reviewDraft'

const NOW = new Date('2026-08-06T15:00:00')
const CHICAGO = { timeZone: 'America/Chicago' }

function person(name: string, overrides: Partial<Person> = {}): Person {
  return { ...makePerson({ displayName: name }, NOW), id: `p-${name.toLowerCase().replace(/\s+/g, '-')}`, ...overrides }
}

const KELLY_PROPOSAL: CaptureProposal = {
  interaction: { kind: 'other', summary: 'Harbinder introduced me to Kelly Tsaur', discussion: null },
  participantNames: ['Kelly Tsaur', 'Harbinder Raina'],
  facts: [
    { personName: 'Kelly Tsaur', attribute: 'role', value: 'Head of Payer/Provider Industry Vertical', confidence: 'stated' },
    { personName: 'Kelly Tsaur', attribute: 'employer', value: 'ZS', confidence: 'stated' },
  ],
  relationships: [{ subjectName: 'Kelly Tsaur', kind: 'introducedBy', label: null, otherName: 'Harbinder Raina', facts: [] }],
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

function kellyDraft(existing: Person[] = []): ResolvedCaptureDraft {
  return draftFromResolved(resolveProposal(KELLY_PROPOSAL, existing, NOW), NOW)
}

describe('draftFromResolved', () => {
  it('shares one slot per person across every item that references them', () => {
    const draft = kellyDraft()
    expect(draft.slots).toHaveLength(2)

    const interaction = draft.items.find((i) => i.type === 'interaction')
    const fact = draft.items.find((i) => i.type === 'fact')
    const followUp = draft.items.find((i) => i.type === 'followUp')
    if (interaction?.type !== 'interaction' || fact?.type !== 'fact' || followUp?.type !== 'followUp')
      throw new Error('bad shape')

    expect(interaction.participantSlotIDs).toContain(fact.subjectSlotID)
    expect(followUp.personSlotIDs).toEqual([fact.subjectSlotID])
  })

  it('carries the parsed schedule into editable fields with its source phrase', () => {
    const followUp = kellyDraft().items.find((i) => i.type === 'followUp')
    if (followUp?.type !== 'followUp') throw new Error('bad shape')
    expect(followUp.schedule).toEqual({
      scheduleMode: 'deadline',
      localDate: '2026-08-10',
      localTime: '10:00',
      timeZone: 'America/Chicago',
    })
    expect(followUp.scheduleSource).toBe('Monday 10am CT')
  })
})

describe('reviewDraftReducer', () => {
  it('edits fields without mutating the previous draft', () => {
    const draft = kellyDraft()
    const fact = draft.items.find((i) => i.type === 'fact')!
    const next = reviewDraftReducer(draft, {
      type: 'update-fact',
      id: fact.id,
      changes: { value: 'Head of Industry Vertical' },
    })
    expect(next.revision).toBe(draft.revision + 1)
    const edited = next.items.find((i) => i.id === fact.id)
    if (edited?.type !== 'fact') throw new Error('bad shape')
    expect(edited.value).toBe('Head of Industry Vertical')
    const original = draft.items.find((i) => i.id === fact.id)
    if (original?.type !== 'fact') throw new Error('bad shape')
    expect(original.value).toBe('Head of Payer/Provider Industry Vertical')
  })

  it('remaps a slot for every item at once', () => {
    const existingKelly = person('Kelly T', { lastContactAt: new Date('2026-01-01T12:00:00') })
    const draft = kellyDraft()
    const fact = draft.items.find((i) => i.type === 'fact')
    if (fact?.type !== 'fact') throw new Error('bad shape')

    const next = reviewDraftReducer(draft, {
      type: 'resolve-person',
      slotID: fact.subjectSlotID,
      resolution: { ref: 'existing', person: existingKelly },
    })

    expect(slotPerson(next, fact.subjectSlotID)?.id).toBe(existingKelly.id)
    // The follow-up references the same slot, so it now points at the same person.
    const followUp = next.items.find((i) => i.type === 'followUp')
    if (followUp?.type !== 'followUp') throw new Error('bad shape')
    expect(slotPerson(next, followUp.personSlotIDs[0])?.id).toBe(existingKelly.id)
  })

  it('removes and restores items with stable IDs', () => {
    const draft = kellyDraft()
    const interaction = draft.items.find((i) => i.type === 'interaction')!
    const removed = reviewDraftReducer(draft, { type: 'remove-item', id: interaction.id })
    expect(activeItems(removed).some((i) => i.id === interaction.id)).toBe(false)
    const restored = reviewDraftReducer(removed, { type: 'restore-item', id: interaction.id })
    expect(activeItems(restored).some((i) => i.id === interaction.id)).toBe(true)
  })
})

describe('validateDraft', () => {
  it('accepts the well-formed Kelly draft', () => {
    expect(validateDraft(kellyDraft())).toEqual([])
  })

  it('blocks empty fact values and empty follow-up titles', () => {
    let draft = kellyDraft()
    const fact = draft.items.find((i) => i.type === 'fact')!
    const followUp = draft.items.find((i) => i.type === 'followUp')!
    draft = reviewDraftReducer(draft, { type: 'update-fact', id: fact.id, changes: { value: '  ' } })
    draft = reviewDraftReducer(draft, { type: 'update-follow-up', id: followUp.id, changes: { title: '' } })
    const problems = validateDraft(draft)
    expect(problems.some((p) => p.itemID === fact.id)).toBe(true)
    expect(problems.some((p) => p.itemID === followUp.id)).toBe(true)
  })

  it('ignores problems on removed items', () => {
    let draft = kellyDraft()
    const fact = draft.items.find((i) => i.type === 'fact')!
    draft = reviewDraftReducer(draft, { type: 'update-fact', id: fact.id, changes: { value: '' } })
    draft = reviewDraftReducer(draft, { type: 'remove-item', id: fact.id })
    expect(validateDraft(draft).some((p) => p.itemID === fact.id)).toBe(false)
  })

  it('blocks a self-relationship created by remapping', () => {
    const draft = kellyDraft()
    const relationship = draft.items.find((i) => i.type === 'relationship')
    if (relationship?.type !== 'relationship') throw new Error('bad shape')
    const kelly = slotPerson(draft, relationship.subjectSlotID)!
    const remapped = reviewDraftReducer(draft, {
      type: 'resolve-person',
      slotID: relationship.otherSlotID!,
      resolution: { ref: 'create', person: kelly },
    })
    expect(validateDraft(remapped).some((p) => p.itemID === relationship.id)).toBe(true)
  })

  it('raises the temporal guard when a scheduled-sounding follow-up has no date', () => {
    let draft = kellyDraft()
    const followUp = draft.items.find((i) => i.type === 'followUp')!
    draft = reviewDraftReducer(draft, {
      type: 'update-follow-up',
      id: followUp.id,
      changes: { schedule: { scheduleMode: 'none', localDate: '', localTime: '', timeZone: '' } },
    })
    const problems = validateDraft(draft)
    expect(problems).toHaveLength(1)
    expect(problems[0].kind).toBe('temporal')

    // The explicit override clears it; so does editing the cue away.
    const overridden = reviewDraftReducer(draft, {
      type: 'update-follow-up',
      id: followUp.id,
      changes: { allowUnscheduled: true },
    })
    expect(validateDraft(overridden)).toEqual([])

    const reworded = reviewDraftReducer(draft, {
      type: 'update-follow-up',
      id: followUp.id,
      changes: { title: 'Attend the ZS meeting with Kelly Tsaur' },
    })
    expect(validateDraft(reworded)).toEqual([])
  })
})

describe('planFromReviewDraft', () => {
  it('synchronizes professional identity so a dictated role is visible in People immediately', () => {
    const { plan } = planFromReviewDraft(kellyDraft(), NOW, CHICAGO)
    const identityWrite = plan.find(
      (write) => write.collection === 'people' && write.op === 'update' && 'roleTitle' in write.data,
    )
    expect(identityWrite).toMatchObject({
      data: {
        profileFocus: 'professional',
        roleTitle: 'Head of Payer/Provider Industry Vertical',
        organizationName: 'ZS',
      },
    })
  })

  it('reviews and completes an existing follow-up by ID without creating a duplicate', () => {
    const reminder: Reminder = {
      id: 'reminder-denver', title: 'Book flights for Denver', notes: null, personIDs: ['ana'],
      responsibility: 'mine', sourceInteractionID: null, startAt: null, dueAt: null, isSomeday: false,
      status: 'open', completedAt: null, createdAt: NOW,
    }
    const proposal: CaptureProposal = {
      interaction: null, participantNames: [], facts: [], personContexts: [], relationships: [], followUps: [],
      reminderChanges: [{ reminderID: reminder.id, action: 'complete' }],
    }
    const draft = draftFromResolved(resolveProposal(proposal, [], NOW, { reminders: [reminder] }), NOW)
    expect(draft.items[0]).toMatchObject({ type: 'reminderChange', action: 'complete' })
    const { plan } = planFromReviewDraft(draft, NOW, CHICAGO)
    expect(plan.filter((write) => write.collection === 'reminders')).toEqual([
      { op: 'update', collection: 'reminders', id: reminder.id, data: { status: 'completed', completedAt: NOW } },
    ])
  })

  it('routes a dictated ownership transfer through the same commitment field as drag and drop', () => {
    const reminder: Reminder = {
      id: 'reminder-forecast', title: 'Finish the forecast', notes: null, personIDs: ['ana'],
      responsibility: 'mine', progress: 'notStarted', sourceInteractionID: null, startAt: null, dueAt: null,
      isSomeday: false, status: 'open', completedAt: null, createdAt: NOW,
    }
    const proposal: CaptureProposal = {
      interaction: null, participantNames: [], facts: [], personContexts: [], relationships: [], followUps: [],
      reminderChanges: [{ reminderID: reminder.id, action: 'update', responsibility: 'theirs' }],
    }
    const draft = draftFromResolved(resolveProposal(proposal, [], NOW, { reminders: [reminder] }), NOW)
    expect(draft.items[0]).toMatchObject({ type: 'reminderChange', responsibility: 'theirs' })
    const { plan } = planFromReviewDraft(draft, NOW, CHICAGO)
    expect(plan).toContainEqual({
      op: 'update', collection: 'reminders', id: reminder.id,
      data: { progress: 'notStarted', notes: null, responsibility: 'theirs' },
    })
  })

  it('writes the edited values, never the original proposal', () => {
    let draft = kellyDraft()
    const fact = draft.items.find((i) => i.type === 'fact')!
    draft = reviewDraftReducer(draft, { type: 'update-fact', id: fact.id, changes: { value: 'Vertical Head' } })

    const { plan } = planFromReviewDraft(draft, NOW, CHICAGO)
    const observations = plan.filter((w) => w.collection === 'observations' && w.op === 'set')
    const values = observations.map((w) => (w as { data: { value: string } }).data.value)
    expect(values).toContain('Vertical Head')
    expect(values).not.toContain('Head of Payer/Provider Industry Vertical')
  })

  it('never creates a person referenced only by removed items', () => {
    let draft = kellyDraft()
    // Remove everything that references Harbinder: interaction + relationship.
    for (const item of draft.items) {
      if (item.type === 'interaction' || item.type === 'relationship') {
        draft = reviewDraftReducer(draft, { type: 'remove-item', id: item.id })
      }
    }
    const { plan } = planFromReviewDraft(draft, NOW, CHICAGO)
    const createdNames = plan
      .filter((w) => w.collection === 'people' && w.op === 'set')
      .map((w) => (w as { data: { displayName: string } }).data.displayName)
    expect(createdNames).toEqual(['Kelly Tsaur'])
    expect(plan.some((w) => w.collection === 'interactions')).toBe(false)
    expect(plan.some((w) => w.collection === 'relationships')).toBe(false)
  })

  it('resolves the edited schedule and the edited occurred date', () => {
    let draft = kellyDraft()
    const interaction = draft.items.find((i) => i.type === 'interaction')!
    const followUp = draft.items.find((i) => i.type === 'followUp')!
    const occurredAt = new Date('2026-08-05T09:30:00')
    draft = reviewDraftReducer(draft, { type: 'update-interaction', id: interaction.id, changes: { occurredAt } })
    draft = reviewDraftReducer(draft, {
      type: 'update-follow-up',
      id: followUp.id,
      changes: { schedule: { scheduleMode: 'deadline', localDate: '2026-08-11', localTime: '14:00', timeZone: 'America/Chicago' } },
    })

    const { plan } = planFromReviewDraft(draft, NOW, CHICAGO)
    const interactionWrite = plan.find((w) => w.collection === 'interactions')
    expect((interactionWrite as { data: { occurredAt: Date } }).data.occurredAt).toEqual(occurredAt)
    const reminderWrite = plan.find((w) => w.collection === 'reminders')
    expect((reminderWrite as { data: { dueAt: Date } }).data.dueAt.toISOString()).toBe('2026-08-11T19:00:00.000Z')
  })

  it('folds edited attribute text through the curated registry', () => {
    let draft = kellyDraft()
    const fact = draft.items.find((i) => i.type === 'fact')!
    draft = reviewDraftReducer(draft, { type: 'update-fact', id: fact.id, changes: { attribute: 'Works at' } })
    const { plan } = planFromReviewDraft(draft, NOW, CHICAGO)
    const attributes = plan
      .filter((w) => w.collection === 'observations')
      .map((w) => (w as { data: { attribute: string } }).data.attribute)
    expect(attributes).toContain('employer')
  })

  it('reuses an existing person after remapping instead of creating a duplicate', () => {
    const existingKelly = person('Kelly Tsaur (ZS)')
    let draft = kellyDraft()
    const fact = draft.items.find((i) => i.type === 'fact')
    if (fact?.type !== 'fact') throw new Error('bad shape')
    draft = reviewDraftReducer(draft, {
      type: 'resolve-person',
      slotID: fact.subjectSlotID,
      resolution: { ref: 'existing', person: existingKelly },
    })

    const { plan } = planFromReviewDraft(draft, NOW, CHICAGO)
    const createdNames = plan
      .filter((w) => w.collection === 'people' && w.op === 'set')
      .map((w) => (w as { data: { displayName: string } }).data.displayName)
    expect(createdNames).toEqual(['Harbinder Raina'])
    const observation = plan.find((w) => w.collection === 'observations')
    expect((observation as { data: { subjectID: string } }).data.subjectID).toBe(existingKelly.id)
  })
})
