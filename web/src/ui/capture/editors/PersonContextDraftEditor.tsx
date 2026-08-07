import { useId } from 'react'
import type { Person } from '../../../domain/person'
import type { PersonContextDraftItem, ResolvedCaptureDraft, ReviewDraftAction } from '../../../domain/reviewDraft'
import { FormField } from '../../components/FormField'
import { SlotSelect } from './PersonSlotPicker'

export function PersonContextDraftEditor({
  item,
  draft,
  people,
  dispatch,
}: {
  item: PersonContextDraftItem
  draft: ResolvedCaptureDraft
  people: Person[]
  dispatch: (action: ReviewDraftAction) => void
}) {
  const id = useId()
  const update = (changes: Partial<Omit<PersonContextDraftItem, 'id' | 'type' | 'removed'>>) =>
    dispatch({ type: 'update-person-context', id: item.id, changes })

  return (
    <div className="draft-editor">
      <FormField label="Person">
        <SlotSelect
          value={item.subjectSlotID}
          slots={draft.slots}
          people={people}
          label="Person"
          onPickSlot={(subjectSlotID) => update({ subjectSlotID })}
          onPickPerson={(person) => {
            dispatch({ type: 'add-person-slot', slot: { slotID: person.id, resolution: { ref: 'existing', person }, proposedName: person.displayName } })
            update({ subjectSlotID: person.id })
          }}
        />
      </FormField>
      <div className="draft-editor-pair">
        <FormField label="Profile emphasis" htmlFor={`${id}-focus`}>
          <select id={`${id}-focus`} className="field field-select" value={item.profileFocus} onChange={(event) => update({ profileFocus: event.target.value as 'professional' | 'personal' })}>
            <option value="professional">Professional</option>
            <option value="personal">Personal</option>
          </select>
        </FormField>
        <FormField label="Connection" htmlFor={`${id}-status`}>
          <select id={`${id}-status`} className="field field-select" value={item.connectionStatus} onChange={(event) => update({ connectionStatus: event.target.value as PersonContextDraftItem['connectionStatus'] })}>
            <option value="met">Already met</option>
            <option value="introductionPlanned">Introduction planned</option>
            <option value="unknown">Not specified</option>
          </select>
        </FormField>
      </div>
      <div className="draft-editor-pair">
        <FormField label="Role" htmlFor={`${id}-role`}><input id={`${id}-role`} className="field" value={item.roleTitle} onChange={(event) => update({ roleTitle: event.target.value })} /></FormField>
        <FormField label="Organization" htmlFor={`${id}-org`}><input id={`${id}-org`} className="field" value={item.organizationName} onChange={(event) => update({ organizationName: event.target.value })} /></FormField>
      </div>
      <div className="draft-editor-pair">
        <FormField label={item.connectionStatus === 'introductionPlanned' ? 'First meeting' : 'First met'} htmlFor={`${id}-date`}>
          <input id={`${id}-date`} type="date" className="field" value={item.firstMetOn} onChange={(event) => update({ firstMetOn: event.target.value })} />
        </FormField>
        <FormField label="Introduced by" htmlFor={`${id}-introducer`}>
          <select id={`${id}-introducer`} className="field field-select" value={item.introducedBySlotID ?? ''} onChange={(event) => update({ introducedBySlotID: event.target.value || null })}>
            <option value="">Nobody recorded</option>
            {draft.slots.filter((slot) => slot.slotID !== item.subjectSlotID).map((slot) => <option key={slot.slotID} value={slot.slotID}>{slot.resolution.person.displayName}</option>)}
          </select>
        </FormField>
      </div>
      <FormField label="How you connected" htmlFor={`${id}-context`}>
        <input id={`${id}-context`} className="field" value={item.context} onChange={(event) => update({ context: event.target.value })} placeholder="Conference, project, dinner, mutual friend…" />
      </FormField>
    </div>
  )
}
