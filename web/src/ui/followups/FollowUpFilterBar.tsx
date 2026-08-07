import { useRef, useState, type ReactNode } from 'react'
import type { Person } from '../../domain/person'
import { Avatar } from '../components/Avatar'
import { Icon } from '../components/Icon'
import { categoryTintStyle } from './categoryStyle'

export type FollowUpStatusFilter = 'all' | 'overdue' | 'today' | 'upcoming' | 'unscheduled'
export type FollowUpDueFilter = 'any' | 'today' | 'tomorrow' | 'next7' | 'none'

interface FilterOption {
  value: string
  label: string
  leading?: ReactNode
  style?: React.CSSProperties
}

function FilterMenu({
  label,
  icon,
  value,
  options,
  onChange,
}: {
  label: string
  icon: string
  value: string
  options: FilterOption[]
  onChange: (value: string) => void
}) {
  const [open, setOpen] = useState(false)
  const rootRef = useRef<HTMLDivElement>(null)
  const selected = options.find((option) => option.value === value) ?? options[0]
  const active = value !== options[0].value

  function focusOption(index: number) {
    const optionButtons = rootRef.current?.querySelectorAll<HTMLButtonElement>('[role="menuitemradio"]')
    if (!optionButtons?.length) return
    optionButtons[(index + optionButtons.length) % optionButtons.length].focus()
  }

  function openAndFocus(index: number) {
    setOpen(true)
    window.setTimeout(() => focusOption(index), 0)
  }

  function choose(nextValue: string) {
    onChange(nextValue)
    setOpen(false)
    window.setTimeout(() => {
      rootRef.current?.querySelector<HTMLButtonElement>('.followup-filter-menu-trigger')?.focus()
    }, 0)
  }

  return (
    <div
      ref={rootRef}
      className="followup-filter-menu"
      onBlur={(event) => {
        if (event.relatedTarget instanceof Node && rootRef.current?.contains(event.relatedTarget)) return
        setOpen(false)
      }}
      onKeyDown={(event) => {
        if (event.key !== 'Escape' || !open) return
        event.stopPropagation()
        setOpen(false)
        rootRef.current?.querySelector<HTMLButtonElement>('.followup-filter-menu-trigger')?.focus()
      }}
    >
      <button
        type="button"
        className="followup-filter-menu-trigger"
        data-active={active || undefined}
        aria-label={`${label}: ${selected.label}`}
        aria-expanded={open}
        onClick={() => setOpen((current) => !current)}
        onKeyDown={(event) => {
          if (event.key !== 'ArrowDown' && event.key !== 'ArrowUp') return
          event.preventDefault()
          const selectedIndex = Math.max(0, options.findIndex((option) => option.value === value))
          openAndFocus(event.key === 'ArrowDown' ? selectedIndex : selectedIndex - 1)
        }}
      >
        <Icon name={icon} size={15} />
        <span>{active ? selected.label : label}</span>
        <Icon name="chevron-down" size={12} />
      </button>
      {open && (
        <div className="followup-filter-popover" role="menu" aria-label={label}>
          {options.map((option, index) => (
            <button
              key={option.value}
              type="button"
              role="menuitemradio"
              aria-checked={option.value === value}
              style={option.style}
              onClick={() => choose(option.value)}
              onKeyDown={(event) => {
                if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
                  event.preventDefault()
                  focusOption(index + (event.key === 'ArrowDown' ? 1 : -1))
                } else if (event.key === 'Home' || event.key === 'End') {
                  event.preventDefault()
                  focusOption(event.key === 'Home' ? 0 : options.length - 1)
                }
              }}
            >
              <span className="followup-filter-option-leading">{option.leading}</span>
              <span>{option.label}</span>
              {option.value === value && <Icon name="check" size={14} />}
            </button>
          ))}
        </div>
      )}
    </div>
  )
}

export function FollowUpFilterBar({
  status,
  counts,
  personID,
  people,
  due,
  category,
  categories,
  onStatusChange,
  onPersonChange,
  onDueChange,
  onCategoryChange,
  onClear,
}: {
  status: FollowUpStatusFilter
  counts: Record<FollowUpStatusFilter, number>
  personID: string
  people: Person[]
  due: FollowUpDueFilter
  category: string
  categories: string[]
  onStatusChange: (value: FollowUpStatusFilter) => void
  onPersonChange: (value: string) => void
  onDueChange: (value: FollowUpDueFilter) => void
  onCategoryChange: (value: string) => void
  onClear: () => void
}) {
  const hasFilters = status !== 'all' || personID !== '' || due !== 'any' || category !== ''
  const statuses: Array<{ value: FollowUpStatusFilter; label: string }> = [
    { value: 'all', label: 'All' },
    { value: 'overdue', label: 'Overdue' },
    { value: 'today', label: 'Today' },
    { value: 'upcoming', label: 'Upcoming' },
    { value: 'unscheduled', label: 'Unscheduled' },
  ]
  const peopleOptions: FilterOption[] = [
    { value: '', label: 'Anyone', leading: <Icon name="people" size={15} /> },
    ...people.map((person) => ({
      value: person.id,
      label: person.displayName,
      leading: <Avatar name={person.displayName} colorName={person.colorName} small />,
    })),
  ]
  const dueOptions: FilterOption[] = [
    { value: 'any', label: 'Any due date', leading: <Icon name="calendar" size={15} /> },
    { value: 'today', label: 'Due today', leading: <Icon name="calendar" size={15} /> },
    { value: 'tomorrow', label: 'Due tomorrow', leading: <Icon name="calendar" size={15} /> },
    { value: 'next7', label: 'Next 7 days', leading: <Icon name="calendar" size={15} /> },
    { value: 'none', label: 'No due date', leading: <Icon name="calendar" size={15} /> },
  ]
  const categoryOptions: FilterOption[] = [
    { value: '', label: 'Any category', leading: <Icon name="tag" size={15} /> },
    ...categories.map((tag) => ({
      value: tag,
      label: tag,
      leading: <span className="category-option-dot" />,
      style: categoryTintStyle(tag),
    })),
  ]

  return (
    <div className="followup-filter-bar" aria-label="Filter follow-ups">
      <div className="followup-status-filters" role="group" aria-label="Status">
        {statuses.map((option) => (
          <button
            key={option.value}
            type="button"
            aria-pressed={status === option.value}
            data-tone={option.value === 'overdue' ? 'overdue' : undefined}
            onClick={() => onStatusChange(option.value)}
          >
            <span>{option.label}</span>
            <b>{counts[option.value]}</b>
          </button>
        ))}
      </div>
      <span className="followup-filter-divider" aria-hidden="true" />
      <div className="followup-facet-filters">
        <FilterMenu
          label="People"
          icon="people"
          value={personID}
          options={peopleOptions}
          onChange={onPersonChange}
        />
        <FilterMenu
          label="Due date"
          icon="calendar"
          value={due}
          options={dueOptions}
          onChange={(value) => onDueChange(value as FollowUpDueFilter)}
        />
        <FilterMenu
          label="Category"
          icon="tag"
          value={category}
          options={categoryOptions}
          onChange={onCategoryChange}
        />
        {hasFilters && (
          <button type="button" className="followup-filter-clear" onClick={onClear}>
            Clear
          </button>
        )}
      </div>
    </div>
  )
}
