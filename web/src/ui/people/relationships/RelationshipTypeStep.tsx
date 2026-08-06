/// Step 1 — who are they to the subject? Grouped selectable tiles with radio
/// semantics; the user's own word is an optional refinement beneath, and
/// "Other" requires one.

import { useId } from 'react'
import {
  GROUP_TITLES,
  RELATIONSHIP_GROUPS,
  RELATIONSHIP_KINDS,
  genderedKind,
  groupOf,
  kindLabel,
  type RelationshipKind,
} from '../../../domain/relationships'
import { FormField } from '../../components/FormField'
import { Icon } from '../../components/Icon'

const KIND_ICONS: Partial<Record<RelationshipKind, string>> = {
  partner: 'heart',
  child: 'people',
  parent: 'people',
  sibling: 'people',
  householdMember: 'in-person',
  pet: 'heart',
  petOwner: 'heart',
  colleague: 'email',
  manager: 'people',
  directReport: 'people',
  worksWith: 'email',
  friend: 'in-person',
  introducedBy: 'arrow-right',
  introduced: 'arrow-right',
}

export function RelationshipTypeStep({
  kind,
  word,
  onPickKind,
  onWordChange,
}: {
  kind: RelationshipKind | null
  word: string
  onPickKind: (kind: RelationshipKind) => void
  onWordChange: (word: string) => void
}) {
  const wordID = useId()

  return (
    <div>
      {RELATIONSHIP_GROUPS.map((group) => (
        <div key={group} role="radiogroup" aria-label={GROUP_TITLES[group]}>
          <h3 className="section-header">{GROUP_TITLES[group]}</h3>
          <div className="relationship-tiles">
            {RELATIONSHIP_KINDS.filter((k) => groupOf(k) === group && k !== 'petOwner').map((k) => (
              <button
                key={k}
                type="button"
                role="radio"
                aria-checked={kind === k}
                className="relationship-tile"
                onClick={() => onPickKind(k)}
              >
                <Icon name={KIND_ICONS[k] ?? 'people'} size={16} />
                <span>{kindLabel(k)}</span>
                {kind === k && <Icon name="check" size={14} />}
              </button>
            ))}
          </div>
        </div>
      ))}

      {kind && (
        <FormField
          label="What do you call this relationship?"
          htmlFor={wordID}
          help="For example: son, roommate, mentor. Optional."
        >
          <input
            id={wordID}
            className="field"
            value={word}
            onChange={(event) => {
              onWordChange(event.target.value)
              const inferred = genderedKind(event.target.value.trim())
              if (inferred) onPickKind(inferred)
            }}
          />
        </FormField>
      )}
    </div>
  )
}
