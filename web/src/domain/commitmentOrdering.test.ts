import { describe, expect, it } from 'vitest'
import type { Reminder } from './reminders'
import { orderedCommitments, ownerAcrossBoundary, planCommitmentPlacement, previewCommitmentPlacement } from './commitmentOrdering'

const NOW = new Date('2026-08-07T12:00:00Z')
function reminder(id: string, responsibility: 'mine' | 'theirs', order?: number): Reminder {
  return {
    id, title: id, notes: null, personIDs: ['alex'], responsibility,
    personOrder: order === undefined ? undefined : { alex: order, other: order + 1 },
    sourceInteractionID: null, startAt: null, dueAt: null, isSomeday: false,
    status: 'open', completedAt: null, createdAt: NOW,
  }
}

describe('commitment ordering', () => {
  const reminders = [reminder('a', 'mine', 0), reminder('b', 'mine', 1024), reminder('c', 'theirs', 0)]

  it('projects live insertion in the target lane', () => {
    const lanes = previewCommitmentPlacement(reminders, 'alex', { reminderID: 'b', owner: 'theirs', index: 0 })
    expect(lanes.mine.map((item) => item.id)).toEqual(['a'])
    expect(lanes.theirs.map((item) => item.id)).toEqual(['b', 'c'])
  })

  it('persists cross-lane ownership and normalized per-person order atomically', () => {
    const plan = planCommitmentPlacement(reminders, 'alex', { reminderID: 'b', owner: 'theirs', index: 0 })
    const moved = plan.find((write) => write.id === 'b')
    expect(moved).toMatchObject({ op: 'update', collection: 'reminders', data: { responsibility: 'theirs', personOrder: { alex: 0, other: 1025 } } })
    expect(orderedCommitments(reminders, 'alex', 'mine').map((item) => item.id)).toEqual(['a', 'b'])
  })

  it('reorders within one lane without changing ownership', () => {
    const plan = planCommitmentPlacement(reminders, 'alex', { reminderID: 'b', owner: 'mine', index: 0 })
    const moved = plan.find((write) => write.id === 'b')
    expect(moved?.op).toBe('update')
    if (!moved || moved.op !== 'update') throw new Error('expected update')
    expect(moved.data).not.toHaveProperty('responsibility')
    expect(moved.data.personOrder).toMatchObject({ alex: 0 })
  })
})

describe('cross-lane hysteresis', () => {
  it('holds either lane while a stationary pointer is inside the dead band', () => {
    expect(ownerAcrossBoundary('mine', 510, 500, 28)).toBe('mine')
    expect(ownerAcrossBoundary('theirs', 490, 500, 28)).toBe('theirs')
  })

  it('changes lanes only after clearing the far edge', () => {
    expect(ownerAcrossBoundary('mine', 529, 500, 28)).toBe('theirs')
    expect(ownerAcrossBoundary('theirs', 471, 500, 28)).toBe('mine')
  })
})
