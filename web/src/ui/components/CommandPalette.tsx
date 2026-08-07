/// ⌘K: one box that goes anywhere — the destinations, the capture action, and
/// every person by name. Same native-<dialog> machinery as Dialog, in a
/// top-aligned dress. Deliberately not full-text search; it matches names and
/// destinations, nothing inside interactions or facts.

import { useEffect, useMemo, useRef, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { foldedForMatching, type Person } from '../../domain/person'
import { Avatar } from './Avatar'
import { Icon } from './Icon'

interface Command {
  id: string
  group: 'Actions' | 'Pages' | 'People'
  label: string
  detail?: string | null
  icon?: string
  person?: Person
  to: string
}

const STATIC_COMMANDS: Command[] = [
  { id: 'action-capture', group: 'Actions', label: 'Log an interaction', icon: 'plus', to: '/capture' },
  { id: 'action-brief', group: 'Actions', label: 'Prepare my day', icon: 'sparkle', to: '/?brief=1' },
  { id: 'page-feed', group: 'Pages', label: 'Feed', icon: 'feed', to: '/' },
  { id: 'page-people', group: 'Pages', label: 'People', icon: 'people', to: '/people' },
  { id: 'page-followups', group: 'Pages', label: 'Follow-ups', icon: 'bell', to: '/followups' },
  { id: 'page-settings', group: 'Pages', label: 'Settings', icon: 'gear', to: '/settings' },
]

export function CommandPalette({ people, onClose }: { people: Person[]; onClose: () => void }) {
  const ref = useRef<HTMLDialogElement>(null)
  const navigate = useNavigate()
  const [query, setQuery] = useState('')
  const [activeIndex, setActiveIndex] = useState(0)

  useEffect(() => {
    const dialog = ref.current
    if (dialog && !dialog.open) dialog.showModal()
    return () => dialog?.close()
  }, [])

  const commands = useMemo<Command[]>(() => {
    const folded = foldedForMatching(query)
    const personCommands: Command[] = people
      .filter((person) => !person.isPlaceholder)
      .map((person) => ({
        id: `person-${person.id}`,
        group: 'People' as const,
        label: person.displayName,
        detail: [person.roleTitle, person.organizationName].filter(Boolean).join(' · ') || null,
        person,
        to: `/people/${person.id}`,
      }))
    if (!folded) return STATIC_COMMANDS
    return [...STATIC_COMMANDS, ...personCommands].filter((command) =>
      foldedForMatching(command.label).includes(folded),
    )
  }, [people, query])

  const clampedActive = Math.min(activeIndex, Math.max(0, commands.length - 1))

  function choose(command: Command | undefined) {
    if (!command) return
    onClose()
    navigate(command.to)
  }

  function onKeyDown(event: React.KeyboardEvent) {
    if (event.key === 'ArrowDown') {
      event.preventDefault()
      setActiveIndex((index) => Math.min(index + 1, commands.length - 1))
    } else if (event.key === 'ArrowUp') {
      event.preventDefault()
      setActiveIndex((index) => Math.max(index - 1, 0))
    } else if (event.key === 'Enter') {
      event.preventDefault()
      choose(commands[clampedActive])
    }
  }

  let lastGroup: Command['group'] | null = null

  return (
    <dialog
      ref={ref}
      className="palette"
      aria-label="Search and commands"
      onCancel={(event) => {
        event.preventDefault()
        onClose()
      }}
      onClick={(event) => {
        if (event.target === ref.current) onClose()
      }}
    >
      <div className="palette-input-row">
        <Icon name="search" size={16} />
        <input
          autoFocus
          className="palette-input"
          role="combobox"
          aria-expanded="true"
          aria-label="Search people and pages"
          placeholder="Search people, or jump anywhere…"
          value={query}
          onChange={(event) => {
            setQuery(event.target.value)
            setActiveIndex(0)
          }}
          onKeyDown={onKeyDown}
        />
        <kbd className="palette-kbd">esc</kbd>
      </div>
      <div className="palette-results" role="listbox" aria-label="Results">
        {commands.length === 0 && <p className="palette-empty">Nothing matches “{query}”.</p>}
        {commands.map((command, index) => {
          const header = command.group !== lastGroup ? command.group : null
          lastGroup = command.group
          return (
            <div key={command.id}>
              {header && <p className="palette-group">{header}</p>}
              <button
                type="button"
                role="option"
                aria-selected={index === clampedActive}
                className="palette-item"
                data-active={index === clampedActive || undefined}
                onMouseDown={(event) => event.preventDefault()}
                onMouseEnter={() => setActiveIndex(index)}
                onClick={() => choose(command)}
              >
                {command.person ? (
                  <Avatar name={command.person.displayName} colorName={command.person.colorName} small />
                ) : (
                  <span className="palette-item-icon">
                    <Icon name={command.icon ?? 'circle'} size={15} />
                  </span>
                )}
                <span className="palette-item-label">{command.label}</span>
                {command.detail && <span className="palette-item-detail">{command.detail}</span>}
              </button>
            </div>
          )
        })}
      </div>
    </dialog>
  )
}
