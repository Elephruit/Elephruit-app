import { useId, useRef, useState } from 'react'
import { categoryKey, uniqueCategoryTags } from '../../domain/categoryTags'
import { Icon } from '../components/Icon'
import { categoryTintStyle } from './categoryStyle'

function folded(value: string): string {
  return categoryKey(value)
}

export function CategoryTagPicker({
  selected,
  suggestions,
  onChange,
  autoFocus = false,
  showSelected = true,
  onTabBackward,
  onTabForward,
}: {
  selected: Set<string>
  suggestions: string[]
  onChange: (next: Set<string>) => void
  autoFocus?: boolean
  showSelected?: boolean
  onTabBackward?: () => void
  onTabForward?: () => void
}) {
  const [search, setSearch] = useState('')
  const [open, setOpen] = useState(false)
  const [activeIndex, setActiveIndex] = useState(0)
  const inputRef = useRef<HTMLInputElement>(null)
  const listID = useId()

  const selectedKeys = new Set([...selected].map(folded))
  const candidates = uniqueCategoryTags(suggestions)
  const visible = candidates.filter(
    (tag) => !selectedKeys.has(folded(tag)) && (!search.trim() || folded(tag).includes(folded(search))),
  )
  const exactMatch = [...selected, ...candidates].some((tag) => folded(tag) === folded(search))
  const offerCreate = search.trim().length > 0 && !exactMatch
  const optionCount = visible.length + (offerCreate ? 1 : 0)
  const clampedActive = Math.min(activeIndex, Math.max(optionCount - 1, 0))

  function add(tag: string) {
    const value = tag.trim()
    if (!value) return
    onChange(new Set(uniqueCategoryTags([...selected, value])))
    setSearch('')
    setActiveIndex(0)
    inputRef.current?.focus()
  }

  function choose(index: number) {
    if (index < visible.length) add(visible[index])
    else if (offerCreate) add(search)
  }

  function remove(tag: string) {
    const next = new Set(selected)
    next.delete(tag)
    onChange(next)
  }

  function onKeyDown(event: React.KeyboardEvent<HTMLInputElement>) {
    if (event.key === 'Tab' && (onTabBackward || onTabForward)) {
      event.preventDefault()
      setOpen(false)
      if (event.shiftKey) onTabBackward?.()
      else onTabForward?.()
    } else if (event.key === 'ArrowDown') {
      event.preventDefault()
      setOpen(true)
      setActiveIndex((index) => Math.min(index + 1, optionCount - 1))
    } else if (event.key === 'ArrowUp') {
      event.preventDefault()
      setActiveIndex((index) => Math.max(index - 1, 0))
    } else if (event.key === 'Enter' || event.key === ',') {
      if (optionCount > 0) {
        event.preventDefault()
        choose(clampedActive)
      }
    } else if (event.key === 'Escape' && open) {
      event.stopPropagation()
      setOpen(false)
    } else if (event.key === 'Backspace' && !search && selected.size > 0) {
      remove([...selected][selected.size - 1])
    }
  }

  return (
    <div className="combobox category-combobox">
      <div className="combobox-control" onClick={() => inputRef.current?.focus()}>
        {showSelected && [...selected].map((tag) => (
          <span key={tag} className="combobox-token category-token" style={categoryTintStyle(tag)}>
            {tag}
            <button
              type="button"
              className="combobox-token-remove"
              aria-label={`Remove ${tag}`}
              onClick={(event) => {
                event.stopPropagation()
                remove(tag)
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
          aria-label="Add a category"
          placeholder={selected.size === 0 || !showSelected ? 'Type or choose a category' : undefined}
          autoFocus={autoFocus}
          value={search}
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
        <div className="combobox-list" id={listID} role="listbox" aria-label="Categories">
          {visible.map((tag, index) => (
            <button
              key={tag}
              id={`${listID}-option-${index}`}
              type="button"
              role="option"
              aria-selected={false}
              className="combobox-option"
              style={categoryTintStyle(tag)}
              data-active={index === clampedActive || undefined}
              onMouseDown={(event) => event.preventDefault()}
              onMouseEnter={() => setActiveIndex(index)}
              onClick={() => choose(index)}
            >
              <span className="category-option-dot" aria-hidden="true" />
              <span className="combobox-option-name">{tag}</span>
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
              onClick={() => add(search)}
            >
              <Icon name="plus" size={15} />
              <span className="combobox-option-name">Create “{search.trim()}”</span>
            </button>
          )}
        </div>
      )}
    </div>
  )
}
