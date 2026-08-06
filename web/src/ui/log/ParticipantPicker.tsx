import { useState } from 'react'
import { foldedForMatching, type Person } from '../../domain/person'
import { Avatar } from '../components/Avatar'
import { Icon } from '../components/Icon'

/// Picks who was there. Existing people toggle; an unknown name becomes a
/// pending person created atomically with the interaction on save — cancelling
/// the composer leaves no orphaned records behind.
export function ParticipantPicker({
  people,
  pendingNew,
  selectedIDs,
  onToggle,
  onCreate,
}: {
  people: Person[]
  pendingNew: Person[]
  selectedIDs: Set<string>
  onToggle: (id: string) => void
  onCreate: (name: string) => void
}) {
  const [search, setSearch] = useState('')
  const folded = foldedForMatching(search)

  const candidates = [...people.filter((p) => !p.isPlaceholder), ...pendingNew]
  const visible = folded
    ? candidates.filter((p) => foldedForMatching(p.displayName).includes(folded))
    : candidates

  const exactMatch = candidates.some((p) => foldedForMatching(p.displayName) === folded)
  const offerCreate = folded.length > 0 && !exactMatch

  return (
    <div>
      <input
        className="field"
        value={search}
        onChange={(event) => setSearch(event.target.value)}
        placeholder="Who was there?"
        aria-label="Search people"
      />
      <div style={{ maxHeight: 220, overflowY: 'auto', marginTop: 'var(--space-small)' }}>
        {visible.map((person) => {
          const selected = selectedIDs.has(person.id)
          return (
            <button
              key={person.id}
              type="button"
              className="row"
              style={{ padding: 'var(--space-small) 0' }}
              aria-pressed={selected}
              onClick={() => onToggle(person.id)}
            >
              <Avatar name={person.displayName} colorName={person.colorName} small />
              <span className="row-title">{person.displayName}</span>
              <span className="row-trailing" style={{ color: selected ? 'var(--color-accent)' : undefined }}>
                {selected ? <Icon name="check" size={18} /> : null}
              </span>
            </button>
          )
        })}
        {offerCreate && (
          <button
            type="button"
            className="row"
            style={{ padding: 'var(--space-small) 0' }}
            onClick={() => {
              onCreate(search.trim())
              setSearch('')
            }}
          >
            <span className="avatar avatar-small">
              <Icon name="plus" size={14} />
            </span>
            <span className="row-title">Add “{search.trim()}”</span>
          </button>
        )}
      </div>
    </div>
  )
}
