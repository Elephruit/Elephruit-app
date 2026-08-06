/// Step 2 — who is this? One searchable combobox: existing people with
/// context and conflict states, exact unrecognized text offers creation, and
/// "I don't know their name yet" is always present. Nothing is created here —
/// selection is state until the final confirmation.

import { useId, useState } from 'react'
import { foldedForMatching, type Person } from '../../../domain/person'
import { kindLabel, type Relationship } from '../../../domain/relationships'
import { Avatar } from '../../components/Avatar'
import { Icon } from '../../components/Icon'

export type PersonChoice =
  | { kind: 'existing'; person: Person }
  | { kind: 'new'; name: string }
  | { kind: 'unnamed' }

export function RelationshipPersonStep({
  subject,
  people,
  existingRelationships,
  choice,
  onChoose,
}: {
  subject: Person
  people: Person[]
  existingRelationships: Relationship[]
  choice: PersonChoice | null
  onChoose: (choice: PersonChoice) => void
}) {
  const [search, setSearch] = useState('')
  const listID = useId()
  const folded = foldedForMatching(search)

  const candidates = people.filter((p) => p.id !== subject.id && p.hasStatedName)
  const visible = folded
    ? candidates.filter((p) => foldedForMatching(p.displayName).includes(folded)).slice(0, 6)
    : candidates.slice(0, 6)
  const exact = candidates.some((p) => foldedForMatching(p.displayName) === folded)
  const relationshipWith = (person: Person) => existingRelationships.find((r) => r.otherID === person.id)

  return (
    <div>
      <p className="field-label">Who is this?</p>
      <input
        className="field"
        role="combobox"
        aria-expanded="true"
        aria-controls={listID}
        aria-label="Search people"
        placeholder="Search or type a new name"
        value={search}
        onChange={(event) => setSearch(event.target.value)}
        autoFocus
      />

      <div id={listID} className="relationship-person-options">
        {visible.map((person) => {
          const connected = relationshipWith(person)
          const selected = choice?.kind === 'existing' && choice.person.id === person.id
          return (
            <button
              key={person.id}
              type="button"
              className="combobox-option"
              data-active={selected || undefined}
              disabled={Boolean(connected)}
              onClick={() => onChoose({ kind: 'existing', person })}
            >
              <Avatar name={person.displayName} colorName={person.colorName} small />
              <span className="combobox-option-name">{person.displayName}</span>
              <span className="combobox-option-detail">
                {connected
                  ? `Already connected as ${connected.customLabel ?? kindLabel(connected.kind)}`
                  : (person.roleTitle ?? person.organizationName ?? '')}
              </span>
              {selected && <Icon name="check" size={14} />}
            </button>
          )
        })}

        {folded.length > 0 && !exact && (
          <button
            key="create"
            type="button"
            className="combobox-option"
            data-active={(choice?.kind === 'new' && choice.name === search.trim()) || undefined}
            onClick={() => onChoose({ kind: 'new', name: search.trim() })}
          >
            <span className="avatar avatar-small">
              <Icon name="plus" size={14} />
            </span>
            <span className="combobox-option-name">Create “{search.trim()}”</span>
            {choice?.kind === 'new' && choice.name === search.trim() && <Icon name="check" size={14} />}
          </button>
        )}

        <button
          type="button"
          className="combobox-option"
          data-active={choice?.kind === 'unnamed' || undefined}
          onClick={() => onChoose({ kind: 'unnamed' })}
        >
          <span className="avatar avatar-small">
            <Icon name="in-person" size={14} />
          </span>
          <span className="combobox-option-name">I don’t know their name yet</span>
          {choice?.kind === 'unnamed' && <Icon name="check" size={14} />}
        </button>
      </div>
    </div>
  )
}
