/// Two pickers for the two person questions a review raises.
///
/// PersonSlotPicker answers "who IS this proposed person?" for one slot —
/// match them to somebody on record, create them (with a correctable name),
/// or keep the parser's proposal. Resolving here updates every draft item
/// sharing the slot.
///
/// SlotSelect answers "which person does this field point at?" for one item —
/// choose among the people already in this memory or anybody on record,
/// without touching the shared slot resolutions.

import { useState } from 'react'
import { makePerson } from '../../../domain/capture'
import { foldedForMatching, type Person } from '../../../domain/person'
import type { PersonSlotEntry, PersonSlotResolution } from '../../../domain/reviewDraft'
import { Avatar } from '../../components/Avatar'

export function PersonSlotPicker({
  slot,
  people,
  onResolve,
}: {
  slot: PersonSlotEntry
  people: Person[]
  onResolve: (resolution: PersonSlotResolution) => void
}) {
  const [open, setOpen] = useState(false)
  const [search, setSearch] = useState('')
  const [rename, setRename] = useState(slot.resolution.person.displayName)

  const current = slot.resolution.person
  const isNew = slot.resolution.ref === 'create'
  const folded = foldedForMatching(search)
  const matches = (
    folded ? people.filter((p) => foldedForMatching(p.displayName).includes(folded)) : people
  ).slice(0, 6)

  if (!open) {
    return (
      <span className="slot-chip">
        <Avatar name={current.displayName} colorName={current.colorName} small />
        <span>{current.displayName}</span>
        <button
          type="button"
          className={isNew ? 'chip chip-selected' : 'chip'}
          onClick={() => {
            setRename(current.displayName)
            setOpen(true)
          }}
        >
          {isNew ? 'new — change' : 'change'}
        </button>
      </span>
    )
  }

  return (
    <div className="slot-picker" role="group" aria-label={`Who is ${slot.proposedName}?`}>
      <p className="field-label">Who is “{slot.proposedName}”?</p>
      <input
        className="field"
        placeholder="Search people on record"
        value={search}
        onChange={(event) => setSearch(event.target.value)}
        autoFocus
      />
      <div className="slot-options">
        {matches.map((person) => (
          <button
            key={person.id}
            type="button"
            className="combobox-option"
            onClick={() => {
              onResolve({ ref: 'existing', person })
              setOpen(false)
            }}
          >
            <Avatar name={person.displayName} colorName={person.colorName} small />
            <span className="combobox-option-name">{person.displayName}</span>
            {(person.roleTitle || person.organizationName) && (
              <span className="combobox-option-detail">{person.roleTitle ?? person.organizationName}</span>
            )}
          </button>
        ))}
        <div className="slot-create-row">
          <input
            className="field"
            aria-label="Name for the new person"
            value={rename}
            onChange={(event) => setRename(event.target.value)}
          />
          <button
            type="button"
            className="button button-secondary button-small"
            disabled={rename.trim().length === 0}
            onClick={() => {
              // A fresh record under the corrected name; the slot keeps its
              // identity so every referencing item follows.
              onResolve({ ref: 'create', person: makePerson({ displayName: rename }, new Date()) })
              setOpen(false)
            }}
          >
            Create “{rename.trim() || '…'}”
          </button>
        </div>
      </div>
      <button type="button" className="button button-quiet button-small" onClick={() => setOpen(false)}>
        Keep as is
      </button>
    </div>
  )
}

export function SlotSelect({
  value,
  slots,
  people,
  label,
  onPickSlot,
  onPickPerson,
}: {
  value: string
  slots: PersonSlotEntry[]
  people: Person[]
  label: string
  onPickSlot: (slotID: string) => void
  /// An existing person not yet in the memory — the caller adds a slot.
  onPickPerson: (person: Person) => void
}) {
  const slottedPersonIDs = new Set(slots.map((slot) => slot.resolution.person.id))
  const others = people.filter((p) => !slottedPersonIDs.has(p.id))

  return (
    <select
      className="field field-select"
      aria-label={label}
      value={`slot:${value}`}
      onChange={(event) => {
        const [kind, id] = event.target.value.split(/:(.*)/, 2)
        if (kind === 'slot') onPickSlot(id)
        else {
          const person = others.find((p) => p.id === id)
          if (person) onPickPerson(person)
        }
      }}
    >
      <optgroup label="In this memory">
        {slots.map((slot) => (
          <option key={slot.slotID} value={`slot:${slot.slotID}`}>
            {slot.resolution.person.displayName}
            {slot.resolution.ref === 'create' ? ' (new)' : ''}
          </option>
        ))}
      </optgroup>
      {others.length > 0 && (
        <optgroup label="People on record">
          {others.map((person) => (
            <option key={person.id} value={`person:${person.id}`}>
              {person.displayName}
            </option>
          ))}
        </optgroup>
      )}
    </select>
  )
}
