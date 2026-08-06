/// One proposed fact, fully correctable: whose it is, what kind of fact it is
/// (curated or custom), the value, and how sure the speaker was.

import { useId } from 'react'
import {
  CONFIDENCE_LABELS,
  CURATED_ATTRIBUTES,
  SENSITIVITY_LABELS,
  attributeLabel,
  type FactConfidence,
  type FactSensitivity,
} from '../../../domain/facts'
import type { Person } from '../../../domain/person'
import type { FactDraftItem, ResolvedCaptureDraft, ReviewDraftAction } from '../../../domain/reviewDraft'
import { FormField } from '../../components/FormField'
import { SlotSelect } from './PersonSlotPicker'

export function FactDraftEditor({
  item,
  draft,
  people,
  dispatch,
}: {
  item: FactDraftItem
  draft: ResolvedCaptureDraft
  people: Person[]
  dispatch: (action: ReviewDraftAction) => void
}) {
  const id = useId()
  const update = (changes: Partial<Omit<FactDraftItem, 'id' | 'type' | 'removed'>>) =>
    dispatch({ type: 'update-fact', id: item.id, changes })

  return (
    <div className="draft-editor">
      <FormField label="About">
        <SlotSelect
          value={item.subjectSlotID}
          slots={draft.slots}
          people={people}
          label="Subject person"
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

      <FormField label="Category" htmlFor={`${id}-attribute`} help="Pick a suggestion or type your own.">
        <input
          id={`${id}-attribute`}
          className="field"
          list={`${id}-attributes`}
          value={item.attribute}
          onChange={(event) => update({ attribute: event.target.value })}
        />
        <datalist id={`${id}-attributes`}>
          {CURATED_ATTRIBUTES.map((attribute) => (
            <option key={attribute} value={attribute}>
              {attributeLabel(attribute)}
            </option>
          ))}
        </datalist>
      </FormField>

      <FormField label="Value" htmlFor={`${id}-value`}>
        <input
          id={`${id}-value`}
          className="field"
          value={item.value}
          onChange={(event) => update({ value: event.target.value })}
        />
      </FormField>

      <div className="draft-editor-pair">
        <FormField label="Confidence" htmlFor={`${id}-confidence`}>
          <select
            id={`${id}-confidence`}
            className="field field-select"
            value={item.confidence}
            onChange={(event) => update({ confidence: event.target.value as FactConfidence })}
          >
            {(Object.keys(CONFIDENCE_LABELS) as FactConfidence[]).map((confidence) => (
              <option key={confidence} value={confidence}>
                {CONFIDENCE_LABELS[confidence]}
              </option>
            ))}
          </select>
        </FormField>

        <FormField label="Sensitivity" htmlFor={`${id}-sensitivity`}>
          <select
            id={`${id}-sensitivity`}
            className="field field-select"
            value={item.sensitivity}
            onChange={(event) => update({ sensitivity: event.target.value as FactSensitivity })}
          >
            {(Object.keys(SENSITIVITY_LABELS) as FactSensitivity[]).map((sensitivity) => (
              <option key={sensitivity} value={sensitivity}>
                {SENSITIVITY_LABELS[sensitivity]}
              </option>
            ))}
          </select>
        </FormField>
      </div>
    </div>
  )
}
