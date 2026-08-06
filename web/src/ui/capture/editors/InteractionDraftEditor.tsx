/// Every field of the proposed interaction, editable: kind, summary,
/// discussion, participants, and when it actually happened.

import { useId } from 'react'
import { makePerson } from '../../../domain/capture'
import { INTERACTION_KINDS, INTERACTION_KIND_LABELS, type InteractionKind } from '../../../domain/interaction'
import type { Person } from '../../../domain/person'
import type { InteractionDraftItem, ResolvedCaptureDraft, ReviewDraftAction } from '../../../domain/reviewDraft'
import { fromLocalInputValue, toLocalInputValue } from '../../dateInput'
import { FormField } from '../../components/FormField'
import { ParticipantPicker } from '../../log/ParticipantPicker'

export function InteractionDraftEditor({
  item,
  draft,
  people,
  dispatch,
}: {
  item: InteractionDraftItem
  draft: ResolvedCaptureDraft
  people: Person[]
  dispatch: (action: ReviewDraftAction) => void
}) {
  const id = useId()
  const update = (changes: Partial<Omit<InteractionDraftItem, 'id' | 'type' | 'removed'>>) =>
    dispatch({ type: 'update-interaction', id: item.id, changes })

  const slotPersonIDs = new Map(draft.slots.map((slot) => [slot.resolution.person.id, slot.slotID]))
  const selectedIDs = new Set(
    item.participantSlotIDs
      .map((slotID) => draft.slots.find((slot) => slot.slotID === slotID)?.resolution.person.id)
      .filter((personID): personID is string => Boolean(personID)),
  )
  const pendingNew = draft.slots
    .filter((slot) => slot.resolution.ref === 'create')
    .map((slot) => slot.resolution.person)

  function togglePerson(personID: string) {
    const slotID = slotPersonIDs.get(personID)
    if (slotID) {
      const has = item.participantSlotIDs.includes(slotID)
      update({
        participantSlotIDs: has
          ? item.participantSlotIDs.filter((sid) => sid !== slotID)
          : [...item.participantSlotIDs, slotID],
      })
      return
    }
    const person = people.find((p) => p.id === personID)
    if (!person) return
    dispatch({
      type: 'add-person-slot',
      slot: { slotID: person.id, resolution: { ref: 'existing', person }, proposedName: person.displayName },
    })
    update({ participantSlotIDs: [...item.participantSlotIDs, person.id] })
  }

  function createPerson(name: string) {
    const person = makePerson({ displayName: name }, new Date())
    dispatch({
      type: 'add-person-slot',
      slot: { slotID: person.id, resolution: { ref: 'create', person }, proposedName: person.displayName },
    })
    update({ participantSlotIDs: [...item.participantSlotIDs, person.id] })
  }

  return (
    <div className="draft-editor">
      <FormField label="Kind" htmlFor={`${id}-kind`}>
        <select
          id={`${id}-kind`}
          className="field field-select"
          value={item.kind}
          onChange={(event) => update({ kind: event.target.value as InteractionKind })}
        >
          {INTERACTION_KINDS.map((kind) => (
            <option key={kind} value={kind}>
              {INTERACTION_KIND_LABELS[kind]}
            </option>
          ))}
        </select>
      </FormField>

      <FormField label="Summary" htmlFor={`${id}-summary`}>
        <input
          id={`${id}-summary`}
          className="field"
          value={item.summary}
          onChange={(event) => update({ summary: event.target.value })}
        />
      </FormField>

      <FormField label="Discussion" htmlFor={`${id}-discussion`}>
        <textarea
          id={`${id}-discussion`}
          className="field"
          rows={3}
          value={item.discussion}
          onChange={(event) => update({ discussion: event.target.value })}
        />
      </FormField>

      <FormField label="Who was there">
        <ParticipantPicker
          people={people}
          pendingNew={pendingNew}
          selectedIDs={selectedIDs}
          onToggle={togglePerson}
          onCreate={createPerson}
        />
      </FormField>

      <FormField label="When it happened" htmlFor={`${id}-occurred`}>
        <input
          id={`${id}-occurred`}
          type="datetime-local"
          className="field"
          value={toLocalInputValue(item.occurredAt)}
          onChange={(event) => {
            if (event.target.value) update({ occurredAt: fromLocalInputValue(event.target.value) })
          }}
        />
      </FormField>
    </div>
  )
}
