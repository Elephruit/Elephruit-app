/// ⌘K: one box that goes anywhere — the destinations, the capture action, and
/// now a search across everything the graph holds.
///
/// It used to match names and destinations only, and said so. That was honest
/// while there was nothing else to find; once a trip could be archived it
/// stopped being enough, because archiving something with no way to search for
/// it is just a slower kind of losing it. Archived matches therefore appear
/// here **without any token being typed**, under their own heading — out of the
/// way of today is not the same as out of reach.

import { useEffect, useMemo, useRef, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { useContainers, useNotes, usePeople, useReminders, useSearchableInteractions } from '../../data/hooks'
import type { Container } from '../../domain/container'
import type { Interaction } from '../../domain/interaction'
import type { Note } from '../../domain/note'
import { foldedForMatching, type Person } from '../../domain/person'
import type { Reminder } from '../../domain/reminders'
import { search, type HitKind, type SearchHit } from '../../domain/search'
import { useUID } from '../UserContext'
import { Avatar } from './Avatar'
import { Icon } from './Icon'

type Group = 'Actions' | 'Pages' | 'People' | 'Results' | 'Archived'

interface Command {
  id: string
  group: Group
  label: string
  detail?: string | null
  icon?: string
  person?: Person
  to: string
}

/// Stable identities for the not-yet-loaded case. A fresh `[]` on every render
/// is a new dependency every render, which turns the memo below into a
/// full re-search of every collection on every keystroke *and* on every
/// unrelated re-render.
const EMPTY_PEOPLE: Person[] = []
const EMPTY_CONTAINERS: Container[] = []
const EMPTY_REMINDERS: Reminder[] = []
const EMPTY_INTERACTIONS: Interaction[] = []
const EMPTY_NOTES: Note[] = []

const HIT_ICONS: Record<HitKind, string> = {
  person: 'people',
  container: 'project',
  reminder: 'bell',
  interaction: 'feed',
  note: 'note',
}

function routeFor(hit: SearchHit): string {
  switch (hit.kind) {
    case 'person':
      return `/people/${hit.id}`
    case 'container':
      return `/projects/${hit.id}`
    // A reminder opens where it lives; an unfiled one has only the list.
    case 'reminder':
      return '/followups'
    case 'note':
      return `/notes/${hit.id}`
    case 'interaction':
      return '/'
  }
}

const STATIC_COMMANDS: Command[] = [
  { id: 'action-capture', group: 'Actions', label: 'Log an interaction', icon: 'plus', to: '/capture' },
  { id: 'action-brief', group: 'Actions', label: 'Prepare my day', icon: 'sparkle', to: '/?brief=1' },
  { id: 'page-feed', group: 'Pages', label: 'Feed', icon: 'feed', to: '/' },
  { id: 'page-people', group: 'Pages', label: 'People', icon: 'people', to: '/people' },
  { id: 'page-projects', group: 'Pages', label: 'Projects', icon: 'project', to: '/projects' },
  { id: 'page-notes', group: 'Pages', label: 'Notes', icon: 'note', to: '/notes' },
  { id: 'page-followups', group: 'Pages', label: 'Follow-ups', icon: 'bell', to: '/followups' },
  { id: 'page-settings', group: 'Pages', label: 'Settings', icon: 'gear', to: '/settings' },
]

export function CommandPalette({ onClose }: { onClose: () => void }) {
  const uid = useUID()
  // Subscribed here rather than in the shell so the cost is paid only while the
  // palette is open, instead of on every page for a box nobody has opened.
  const people = usePeople(uid) ?? EMPTY_PEOPLE
  const containers = useContainers(uid) ?? EMPTY_CONTAINERS
  const notes = useNotes(uid) ?? EMPTY_NOTES
  const reminders = useReminders(uid) ?? EMPTY_REMINDERS
  const interactions = useSearchableInteractions(uid) ?? EMPTY_INTERACTIONS

  const ref = useRef<HTMLDialogElement>(null)
  const navigate = useNavigate()
  const [query, setQuery] = useState('')
  const [activeIndex, setActiveIndex] = useState(0)

  useEffect(() => {
    const dialog = ref.current
    if (dialog && !dialog.open) dialog.showModal()
    return () => dialog?.close()
  }, [])

  const peopleByID = useMemo(() => new Map(people.map((person) => [person.id, person])), [people])

  const commands = useMemo<Command[]>(() => {
    const folded = foldedForMatching(query)
    if (!folded) return STATIC_COMMANDS

    const pages = STATIC_COMMANDS.filter((command) =>
      foldedForMatching(command.label).includes(folded),
    )

    const { live, archived } = search(query, { people, containers, reminders, interactions, notes })
    const toCommand = (hit: SearchHit, group: Group): Command => ({
      id: `${hit.kind}-${hit.id}`,
      group,
      label: hit.title,
      detail: hit.detail,
      icon: HIT_ICONS[hit.kind],
      person: hit.kind === 'person' ? peopleByID.get(hit.id) : undefined,
      to: routeFor(hit),
    })

    return [
      ...pages,
      ...live.map((hit) => toCommand(hit, 'Results')),
      ...archived.map((hit) => toCommand(hit, 'Archived')),
    ]
  }, [people, containers, reminders, interactions, notes, peopleByID, query])

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
          aria-label="Search everything"
          placeholder="Search everything, or jump anywhere…"
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
              {header && (
                <p className="palette-group" data-archived={header === 'Archived' || undefined}>
                  {header === 'Archived' && <Icon name="archive" size={12} />}
                  {header}
                </p>
              )}
              <button
                type="button"
                role="option"
                aria-selected={index === clampedActive}
                className="palette-item"
                data-active={index === clampedActive || undefined}
                data-archived={command.group === 'Archived' || undefined}
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
