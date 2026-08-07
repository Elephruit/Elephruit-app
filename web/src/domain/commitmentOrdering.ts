import type { Reminder } from './reminders'
import type { WritePlan } from './writePlan'

export type CommitmentOwner = 'mine' | 'theirs'

/**
 * Cross a lane boundary only after the pointer clears a dead band. Because
 * each direction uses the opposite edge of the band, a stationary pointer
 * can never make ownership oscillate between lanes.
 */
export function ownerAcrossBoundary(
  current: CommitmentOwner,
  pointer: number,
  boundary: number,
  hysteresis: number,
): CommitmentOwner {
  if (current === 'mine' && pointer > boundary + hysteresis) return 'theirs'
  if (current === 'theirs' && pointer < boundary - hysteresis) return 'mine'
  return current
}

export function reminderOwner(reminder: Reminder): CommitmentOwner {
  return reminder.responsibility ?? 'mine'
}

export function orderedCommitments(
  reminders: Reminder[],
  personID: string,
  owner: CommitmentOwner,
): Reminder[] {
  return reminders
    .map((reminder, sourceIndex) => ({ reminder, sourceIndex }))
    .filter(({ reminder }) =>
      reminder.status === 'open' && reminder.personIDs.includes(personID) && reminderOwner(reminder) === owner,
    )
    .sort((a, b) => {
      const aOrder = a.reminder.personOrder?.[personID]
      const bOrder = b.reminder.personOrder?.[personID]
      if (aOrder !== undefined && bOrder !== undefined && aOrder !== bOrder) return aOrder - bOrder
      if (aOrder !== undefined) return -1
      if (bOrder !== undefined) return 1
      return a.sourceIndex - b.sourceIndex
    })
    .map(({ reminder }) => reminder)
}

export interface CommitmentPlacement {
  reminderID: string
  owner: CommitmentOwner
  index: number
}

export function previewCommitmentPlacement(
  reminders: Reminder[],
  personID: string,
  placement: CommitmentPlacement,
): Record<CommitmentOwner, Reminder[]> {
  const moved = reminders.find((reminder) => reminder.id === placement.reminderID)
  if (!moved) return { mine: [], theirs: [] }

  const lanes: Record<CommitmentOwner, Reminder[]> = {
    mine: orderedCommitments(reminders, personID, 'mine').filter((reminder) => reminder.id !== moved.id),
    theirs: orderedCommitments(reminders, personID, 'theirs').filter((reminder) => reminder.id !== moved.id),
  }
  const target = lanes[placement.owner]
  target.splice(Math.max(0, Math.min(placement.index, target.length)), 0, moved)
  return lanes
}

/// Persist both lanes as one normalized sequence per lane. Normalization keeps
/// ordering deterministic after arbitrarily many moves and makes one drop one
/// atomic write plan. Other people's order keys remain untouched.
export function planCommitmentPlacement(
  reminders: Reminder[],
  personID: string,
  placement: CommitmentPlacement,
): WritePlan {
  const lanes = previewCommitmentPlacement(reminders, personID, placement)
  const plan: WritePlan = []
  for (const owner of ['mine', 'theirs'] as const) {
    lanes[owner].forEach((reminder, index) => {
      const nextOrder = index * 1024
      const nextPersonOrder = { ...(reminder.personOrder ?? {}), [personID]: nextOrder }
      const changes: Partial<Reminder> = { personOrder: nextPersonOrder }
      if (reminder.id === placement.reminderID && reminderOwner(reminder) !== owner) {
        changes.responsibility = owner
      }
      if (
        reminder.personOrder?.[personID] !== nextOrder ||
        (changes.responsibility !== undefined && changes.responsibility !== reminderOwner(reminder))
      ) {
        plan.push({ op: 'update', collection: 'reminders', id: reminder.id, data: changes })
      }
    })
  }
  return plan
}
