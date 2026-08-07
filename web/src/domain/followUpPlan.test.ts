import { describe, expect, it } from 'vitest'
import { emptyFollowUpDraft } from './followUpDraft'
import { planPersistFollowUp } from './followUpPlan'
import { makePerson } from './capture'

const NOW = new Date('2026-08-06T15:00:00.000Z')
const ZONE = 'America/Chicago'

describe('planPersistFollowUp', () => {
  it('creates the reminder and its manual memory in one plan', () => {
    const person = { ...makePerson({ displayName: 'Kelly Tsaur' }, NOW), id: 'kelly' }
    const draft = emptyFollowUpDraft(ZONE, 'folder-project')
    draft.title = 'Send the notes'
    draft.personIDs.add(person.id)
    draft.categoryTags.add('work')
    draft.notes = 'Include the updated deck.'
    draft.checklist.push({ id: 'step-1', title: 'Attach the deck', isCompleted: false })

    const plan = planPersistFollowUp({ draft, existingID: null, people: [person], now: NOW, timeZone: ZONE })

    expect(plan).toHaveLength(2)
    expect(plan[0]).toMatchObject({
      op: 'set',
      collection: 'reminders',
      data: {
        title: 'Send the notes',
        notes: 'Include the updated deck.',
        checklist: [{ id: 'step-1', title: 'Attach the deck', isCompleted: false }],
        personIDs: ['kelly'],
        categoryTags: ['work'],
        folderID: 'folder-project',
      },
    })
    expect(plan[1]).toMatchObject({
      op: 'set',
      collection: 'memories',
      data: { title: 'Added a follow-up for Kelly Tsaur', personIDs: ['kelly'] },
    })
  })

  it('updates an existing reminder without creating a second memory', () => {
    const draft = emptyFollowUpDraft(ZONE)
    draft.title = 'Send the revised notes'
    draft.categoryTags.add('waiting')

    const plan = planPersistFollowUp({ draft, existingID: 'rem-1', people: [], now: NOW, timeZone: ZONE })

    expect(plan).toEqual([
      expect.objectContaining({
        op: 'update',
        collection: 'reminders',
        id: 'rem-1',
        data: expect.objectContaining({ title: 'Send the revised notes', categoryTags: ['waiting'] }),
      }),
    ])
  })
})
