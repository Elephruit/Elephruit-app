import { useId, useRef, useState } from 'react'
import { foldedForMatching, type Person } from '../../domain/person'
import { Avatar } from '../components/Avatar'
import { Icon } from '../components/Icon'

/// Picks who was there, as a combobox: chosen people sit in the field as avatar
/// tokens, typing filters the list underneath, arrows and Enter drive it from
/// the keyboard, and Backspace on an empty query removes the last token. An
/// unknown name becomes a pending person created atomically with the
/// interaction on save — cancelling the composer leaves no orphaned records.
export function ParticipantPicker({
  people,
  pendingNew,
  selectedIDs,
  onToggle,
  onCreate,
  allowCreate = true,
  placeholder = 'Who was there?',
  ariaLabel = 'Search people',
  autoFocus = false,
  showSelected = true,
}: {
  people: Person[]
  pendingNew: Person[]
  selectedIDs: Set<string>
  onToggle: (id: string) => void
  onCreate: (name: string) => void
  allowCreate?: boolean
  placeholder?: string
  ariaLabel?: string
  autoFocus?: boolean
  showSelected?: boolean
}) {
  const [search, setSearch] = useState('')
  const [open, setOpen] = useState(false)
  const [activeIndex, setActiveIndex] = useState(0)
  const inputRef = useRef<HTMLInputElement>(null)
  const listID = useId()

  const folded = foldedForMatching(search)
  const candidates = [...people.filter((p) => !p.isPlaceholder), ...pendingNew]
  const selected = candidates.filter((p) => selectedIDs.has(p.id))
  const unselected = candidates.filter((p) => !selectedIDs.has(p.id))
  const visible = folded
    ? unselected.filter((p) => foldedForMatching(p.displayName).includes(folded))
    : unselected

  const exactMatch = candidates.some((p) => foldedForMatching(p.displayName) === folded)
  const offerCreate = allowCreate && folded.length > 0 && !exactMatch
  const optionCount = visible.length + (offerCreate ? 1 : 0)
  const clampedActive = Math.min(activeIndex, Math.max(0, optionCount - 1))

  function choose(index: number) {
    if (index < visible.length) {
      onToggle(visible[index].id)
    } else if (offerCreate) {
      onCreate(search.trim())
    }
    setSearch('')
    setActiveIndex(0)
    inputRef.current?.focus()
  }

  function onKeyDown(event: React.KeyboardEvent) {
    if (event.key === 'ArrowDown') {
      event.preventDefault()
      setOpen(true)
      setActiveIndex((index) => Math.min(index + 1, optionCount - 1))
    } else if (event.key === 'ArrowUp') {
      event.preventDefault()
      setActiveIndex((index) => Math.max(index - 1, 0))
    } else if (event.key === 'Enter') {
      if (open && optionCount > 0) {
        event.preventDefault()
        choose(clampedActive)
      }
    } else if (event.key === 'Escape' && open) {
      // Keep the dialog open when the user only meant to close the list.
      event.stopPropagation()
      setOpen(false)
    } else if (event.key === 'Backspace' && search === '' && selected.length > 0) {
      onToggle(selected[selected.length - 1].id)
    }
  }

  return (
    <div className="combobox">
      <div className="combobox-control" onClick={() => inputRef.current?.focus()}>
        {showSelected && selected.map((person) => (
          <span key={person.id} className="combobox-token tinted" style={tintStyle(person)}>
            <Avatar name={person.displayName} colorName={person.colorName} small />
            {person.displayName}
            <button
              type="button"
              className="combobox-token-remove"
              aria-label={`Remove ${person.displayName}`}
              onClick={(event) => {
                event.stopPropagation()
                onToggle(person.id)
              }}
            >
              <Icon name="x" size={12} />
            </button>
          </span>
        ))}
        <input
          ref={inputRef}
          className="combobox-input"
          role="combobox"
          aria-expanded={open}
          aria-controls={listID}
          aria-activedescendant={open && optionCount > 0 ? `${listID}-option-${clampedActive}` : undefined}
          aria-label={ariaLabel}
          value={search}
          placeholder={selected.length === 0 ? placeholder : undefined}
          autoFocus={autoFocus}
          onChange={(event) => {
            setSearch(event.target.value)
            setOpen(true)
            setActiveIndex(0)
          }}
          onFocus={() => setOpen(true)}
          onBlur={() => setOpen(false)}
          onKeyDown={onKeyDown}
        />
      </div>

      {open && optionCount > 0 && (
        <div className="combobox-list" role="listbox" id={listID} aria-label="People">
          {visible.map((person, index) => (
            <button
              key={person.id}
              id={`${listID}-option-${index}`}
              type="button"
              role="option"
              aria-selected={false}
              className="combobox-option"
              data-active={index === clampedActive || undefined}
              onMouseDown={(event) => event.preventDefault()}
              onMouseEnter={() => setActiveIndex(index)}
              onClick={() => choose(index)}
            >
              <Avatar name={person.displayName} colorName={person.colorName} small />
              <span className="combobox-option-name">{person.displayName}</span>
              {person.organizationName && <span className="combobox-option-detail">{person.organizationName}</span>}
            </button>
          ))}
          {offerCreate && (
            <button
              id={`${listID}-option-${visible.length}`}
              type="button"
              role="option"
              aria-selected={false}
              className="combobox-option"
              data-active={clampedActive === visible.length || undefined}
              onMouseDown={(event) => event.preventDefault()}
              onMouseEnter={() => setActiveIndex(visible.length)}
              onClick={() => choose(visible.length)}
            >
              <span className="avatar avatar-small">
                <Icon name="plus" size={14} />
              </span>
              <span className="combobox-option-name">Add “{search.trim()}”</span>
            </button>
          )}
        </div>
      )}
    </div>
  )
}

function tintStyle(person: Person): React.CSSProperties {
  return { '--tint': `var(--palette-${person.colorName})` } as React.CSSProperties
}
