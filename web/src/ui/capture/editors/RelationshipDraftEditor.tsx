/// One proposed relationship: subject, generic kind, the user's own word for
/// it, who the other person is — existing, new, or explicitly unnamed — and
/// the distinguishing facts that came with them.

import { useId } from 'react'
import type { Person } from '../../../domain/person'
import { RELATIONSHIP_KINDS, kindLabel, possessivePhrase, type RelationshipKind } from '../../../domain/relationships'
import type { RelationshipDraftItem, ResolvedCaptureDraft, ReviewDraftAction } from '../../../domain/reviewDraft'
import { slotPerson } from '../../../domain/reviewDraft'
import { FormField } from '../../components/FormField'
import { SlotSelect } from './PersonSlotPicker'

export function RelationshipDraftEditor({
  item,
  draft,
  people,
  dispatch,
}: {
  item: RelationshipDraftItem
  draft: ResolvedCaptureDraft
  people: Person[]
  dispatch: (action: ReviewDraftAction) => void
}) {
  const id = useId()
  const update = (changes: Partial<Omit<RelationshipDraftItem, 'id' | 'type' | 'removed'>>) =>
    dispatch({ type: 'update-relationship', id: item.id, changes })

  const subject = slotPerson(draft, item.subjectSlotID)
  const named = item.otherSlotID !== null
  const firstOtherCandidate = draft.slots.find((slot) => slot.slotID !== item.subjectSlotID) ?? draft.slots[0]

  return (
    <div className="draft-editor">
      <FormField label="Who this is about">
        <SlotSelect
          value={item.subjectSlotID}
          slots={draft.slots}
          people={people}
          label="Relationship subject"
          onPickSlot={(slotID) => update({ subjectSlotID: slotID })}
          onPickPerson={(person) => {
            dispatch({
              type: 'add-person-slot',
              slot: { slotID: person.id, resolution: { ref: 'existing', person }, proposedName: person.displayName },
            })
            update({ subjectSlotID: person.id })
          }}
        />
      </FormField>

      <FormField label="Relationship" htmlFor={`${id}-kind`}>
        <select
          id={`${id}-kind`}
          className="field field-select"
          value={item.kind}
          onChange={(event) => update({ kind: event.target.value as RelationshipKind })}
        >
          {RELATIONSHIP_KINDS.map((kind) => (
            <option key={kind} value={kind}>
              {kindLabel(kind)}
            </option>
          ))}
        </select>
      </FormField>

      <FormField
        label="What do you call this relationship?"
        htmlFor={`${id}-label`}
        help="For example: son, roommate, mentor. Optional."
      >
        <input
          id={`${id}-label`}
          className="field"
          value={item.label}
          onChange={(event) => update({ label: event.target.value })}
        />
      </FormField>

      <fieldset className="draft-fieldset">
        <legend className="field-label">Who they are</legend>
        <label className="draft-radio">
          <input
            type="radio"
            name={`${id}-other`}
            checked={named}
            onChange={() => {
              if (!named && firstOtherCandidate) update({ otherSlotID: firstOtherCandidate.slotID })
            }}
          />
          <span>A person by name</span>
        </label>
        {named && item.otherSlotID && (
          <SlotSelect
            value={item.otherSlotID}
            slots={draft.slots}
            people={people}
            label="The other person"
            onPickSlot={(slotID) => update({ otherSlotID: slotID })}
            onPickPerson={(person) => {
              dispatch({
                type: 'add-person-slot',
                slot: { slotID: person.id, resolution: { ref: 'existing', person }, proposedName: person.displayName },
              })
              update({ otherSlotID: person.id })
            }}
          />
        )}
        <label className="draft-radio">
          <input type="radio" name={`${id}-other`} checked={!named} onChange={() => update({ otherSlotID: null })} />
          <span>
            I don’t know their name yet
            {!named && subject && (
              <em className="draft-radio-note">
                Creates “{possessivePhrase(subject.displayName, item.kind, item.label.trim() || null)}” to fill in later.
              </em>
            )}
          </span>
        </label>
      </fieldset>

      <FormField label="Details about them" help="Optional — anything that helps you tell them apart.">
        <div className="draft-fact-rows">
          {item.facts.map((fact, index) => (
            <div key={index} className="draft-fact-row">
              <input
                className="field"
                aria-label={`Detail ${index + 1} category`}
                placeholder="Category"
                value={fact.attribute}
                onChange={(event) =>
                  update({
                    facts: item.facts.map((f, i) => (i === index ? { ...f, attribute: event.target.value } : f)),
                  })
                }
              />
              <input
                className="field"
                aria-label={`Detail ${index + 1} value`}
                placeholder="Value"
                value={fact.value}
                onChange={(event) =>
                  update({
                    facts: item.facts.map((f, i) => (i === index ? { ...f, value: event.target.value } : f)),
                  })
                }
              />
              <button
                type="button"
                className="icon-button"
                aria-label={`Remove detail ${fact.attribute || index + 1}`}
                onClick={() => update({ facts: item.facts.filter((_, i) => i !== index) })}
              >
                ×
              </button>
            </div>
          ))}
          <button
            type="button"
            className="button button-plain"
            onClick={() => update({ facts: [...item.facts, { attribute: '', value: '' }] })}
          >
            Add another detail
          </button>
        </div>
      </FormField>
    </div>
  )
}
