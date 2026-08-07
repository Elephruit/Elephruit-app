/// The single write-plan path for a manually created or edited follow-up.
/// Both the sheet and inline composer use this so memory provenance and fields
/// cannot drift between creation surfaces.

import { planCreateReminder, planUpdateReminder } from './capture'
import { reminderFieldsFromDraft, type FollowUpDraft } from './followUpDraft'
import { planMemoryRecord } from './memory'
import type { Person } from './person'
import type { WritePlan } from './writePlan'

export function planPersistFollowUp({
  draft,
  existingID,
  people,
  now,
  timeZone,
}: {
  draft: FollowUpDraft
  existingID: string | null
  people: Person[]
  now: Date
  timeZone: string
}): WritePlan {
  const fields = reminderFieldsFromDraft(draft, { timeZone })
  if (existingID) return planUpdateReminder(existingID, fields).plan

  const { plan, reminder } = planCreateReminder(fields, now)
  const firstPerson = people.find((person) => fields.personIDs.includes(person.id))
  const { plan: memoryPlan } = planMemoryRecord(
    {
      kind: 'manualUpdate',
      title: firstPerson ? `Added a follow-up for ${firstPerson.displayName}` : 'Added a follow-up',
      occurredAt: now,
      personIDs: fields.personIDs,
      reminderIDs: [reminder.id],
      origin: 'manualReminder',
    },
    now,
  )
  return [...plan, ...memoryPlan]
}
