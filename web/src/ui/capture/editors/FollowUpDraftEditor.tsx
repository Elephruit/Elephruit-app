/// One proposed follow-up: title, people, notes, and the structured schedule.
/// The temporal safeguard renders here — as affordances, not just an error.

import { useId } from 'react'
import { makePerson } from '../../../domain/capture'
import type { Person } from '../../../domain/person'
import type { FollowUpDraftItem, ResolvedCaptureDraft, ReviewDraftAction } from '../../../domain/reviewDraft'
import { FormField } from '../../components/FormField'
import { ParticipantPicker } from '../../log/ParticipantPicker'
import { ScheduleEditor } from './ScheduleEditor'

export function FollowUpDraftEditor({
  item,
  draft,
  people,
  userZone,
  dispatch,
}: {
  item: FollowUpDraftItem
  draft: ResolvedCaptureDraft
  people: Person[]
  userZone: string
  dispatch: (action: ReviewDraftAction) => void
}) {
  const id = useId()
  const update = (changes: Partial<Omit<FollowUpDraftItem, 'id' | 'type' | 'removed'>>) =>
    dispatch({ type: 'update-follow-up', id: item.id, changes })

  const slotPersonIDs = new Map(draft.slots.map((slot) => [slot.resolution.person.id, slot.slotID]))
  const selectedIDs = new Set(
    item.personSlotIDs
      .map((slotID) => draft.slots.find((slot) => slot.slotID === slotID)?.resolution.person.id)
      .filter((personID): personID is string => Boolean(personID)),
  )
  const pendingNew = draft.slots
    .filter((slot) => slot.resolution.ref === 'create')
    .map((slot) => slot.resolution.person)

  function togglePerson(personID: string) {
    const slotID = slotPersonIDs.get(personID)
    if (slotID) {
      const has = item.personSlotIDs.includes(slotID)
      update({
        personSlotIDs: has ? item.personSlotIDs.filter((sid) => sid !== slotID) : [...item.personSlotIDs, slotID],
      })
      return
    }
    const person = people.find((p) => p.id === personID)
    if (!person) return
    dispatch({
      type: 'add-person-slot',
      slot: { slotID: person.id, resolution: { ref: 'existing', person }, proposedName: person.displayName },
    })
    update({ personSlotIDs: [...item.personSlotIDs, person.id] })
  }

  function createPerson(name: string) {
    const person = makePerson({ displayName: name }, new Date())
    dispatch({
      type: 'add-person-slot',
      slot: { slotID: person.id, resolution: { ref: 'create', person }, proposedName: person.displayName },
    })
    update({ personSlotIDs: [...item.personSlotIDs, person.id] })
  }

  return (
    <div className="draft-editor">
      <FormField label="What do you need to do?" htmlFor={`${id}-title`}>
        <textarea
          id={`${id}-title`}
          className="field"
          rows={2}
          value={item.title}
          onChange={(event) => update({ title: event.target.value, allowUnscheduled: false })}
        />
      </FormField>

      <FormField label="Who is responsible?" htmlFor={`${id}-responsibility`}>
        <select id={`${id}-responsibility`} className="field field-select" value={item.responsibility} onChange={(event) => update({ responsibility: event.target.value as 'mine' | 'theirs' })}>
          <option value="mine">I am</option>
          <option value="theirs">They are — I’m waiting</option>
        </select>
      </FormField>

      <FormField label="For">
        <ParticipantPicker
          people={people}
          pendingNew={pendingNew}
          selectedIDs={selectedIDs}
          onToggle={togglePerson}
          onCreate={createPerson}
        />
      </FormField>

      <ScheduleEditor
        value={item.schedule}
        sourceText={item.scheduleSource}
        userZone={userZone}
        onChange={(schedule) => update({ schedule, allowUnscheduled: false })}
      />
      {item.scheduleConfidence === 'uncertain' && (
        <p className="field-help">The time zone in “{item.scheduleSource}” was ambiguous — confirm it above.</p>
      )}

      <FormField label="Notes" htmlFor={`${id}-notes`}>
        <textarea
          id={`${id}-notes`}
          className="field"
          rows={2}
          value={item.notes}
          onChange={(event) => update({ notes: event.target.value, allowUnscheduled: false })}
        />
      </FormField>
    </div>
  )
}
