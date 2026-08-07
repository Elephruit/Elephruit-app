import { useMemo, useRef, useState } from 'react'
import { useNavigate, useSearchParams } from 'react-router-dom'
import { followUpSuggestions, relativeDescription } from '../../domain/contact'
import { startOfDay, wholeDaysBetween } from '../../domain/dates'
import { foldedForMatching, type Person } from '../../domain/person'
import { professionalIdentityOf } from '../../domain/personSummary'
import type { Observation } from '../../domain/facts'
import { bucketFor, nextOpenReminderByPerson, type Reminder } from '../../domain/reminders'
import { useAllObservations, useAllRelationships, usePeople, useReminders } from '../../data/hooks'
import { useUID } from '../UserContext'
import { Avatar } from '../components/Avatar'
import { Button, IconButton } from '../components/Button'
import { EmptyState } from '../components/EmptyState'
import { Icon } from '../components/Icon'
import { SkeletonRows } from '../components/Skeleton'
import { PageHeader } from '../shell/PageHeader'
import { PageScaffold } from '../shell/PageScaffold'
import { CreatePersonSheet } from './CreatePersonSheet'

type SortOrder = 'name' | 'recent' | 'quiet'

const SORT_OPTIONS: Array<{ value: SortOrder; label: string }> = [
  { value: 'name', label: 'Name' },
  { value: 'recent', label: 'Recently contacted' },
  { value: 'quiet', label: 'Longest quiet' },
]

function subtitle(person: Person, observations: Observation[]): string | null {
  const identity = professionalIdentityOf(person, observations)
  if (identity.role && identity.organization) return `${identity.role} · ${identity.organization}`
  return identity.role ?? identity.organization
}

const COMPARATORS: Record<SortOrder, (a: Person, b: Person) => number> = {
  name: (a, b) => foldedForMatching(a.displayName).localeCompare(foldedForMatching(b.displayName)),
  // Most recently contacted first; the never-contacted sink to the bottom.
  recent: (a, b) => (b.lastContactAt?.getTime() ?? 0) - (a.lastContactAt?.getTime() ?? 0),
  // Longest quiet first; the never-contacted are the quietest of all.
  quiet: (a, b) => (a.lastContactAt?.getTime() ?? -1) - (b.lastContactAt?.getTime() ?? -1),
}

function NextFollowUp({ reminder, now }: { reminder: Reminder | undefined; now: Date }) {
  if (!reminder) return <span className="person-next person-next-none">—</span>
  const bucket = bucketFor(reminder, now)
  if (bucket === 'overdue' && reminder.dueAt) {
    const days = wholeDaysBetween(startOfDay(reminder.dueAt), startOfDay(now))
    return (
      <span className="person-next" data-tone="overdue">
        {reminder.title} · {days}d late
      </span>
    )
  }
  if (bucket === 'today') {
    return (
      <span className="person-next" data-tone="today">
        {reminder.title} · today
      </span>
    )
  }
  const date = reminder.dueAt ?? reminder.startAt
  return (
    <span className="person-next">
      {reminder.title}
      {date && ` · ${date.toLocaleDateString(undefined, { month: 'short', day: 'numeric' })}`}
    </span>
  )
}

export function PeopleListPage() {
  const uid = useUID()
  const navigate = useNavigate()
  const [searchParams] = useSearchParams()
  const people = usePeople(uid)
  const reminders = useReminders(uid)
  const observations = useAllObservations(uid)
  const relationships = useAllRelationships(uid)

  // Whether a never-contacted person has anything at all recorded — the row
  // says "No conversation yet" for a populated profile and "Nothing recorded"
  // only for a truly empty one.
  const hasProfileData = useMemo(() => {
    const populated = new Set<string>()
    for (const observation of observations ?? []) populated.add(observation.subjectID)
    for (const relationship of relationships ?? []) {
      populated.add(relationship.subjectID)
      populated.add(relationship.otherID)
    }
    for (const reminder of reminders ?? []) for (const id of reminder.personIDs) populated.add(id)
    return populated
  }, [observations, relationships, reminders])
  const [creating, setCreating] = useState(false)
  const [query, setQuery] = useState('')
  const [order, setOrder] = useState<SortOrder>('name')
  const [sortOpen, setSortOpen] = useState(false)
  const sortMenuRef = useRef<HTMLDivElement>(null)
  const [now] = useState(() => new Date())
  const quietOnly = searchParams.get('filter') === 'quiet'
  const quietSuggestions = useMemo(
    () =>
      followUpSuggestions(
        (people ?? [])
          .filter((person) => !person.isPlaceholder)
          .map((person) => ({
            personID: person.id,
            displayName: person.displayName,
            lastContactAt: person.lastContactAt,
          })),
        now,
      ),
    [now, people],
  )
  const quietIDs = useMemo(() => new Set(quietSuggestions.map((suggestion) => suggestion.personID)), [quietSuggestions])

  // Placeholders stay off the list — they surface on the pages of the people
  // they belong to, and in the to-fill-in queue, same as the Mac app.
  const listed = useMemo(() => {
    if (!people) return undefined
    const folded = foldedForMatching(query)
    const matches = people.filter(
      (person) =>
        !person.isPlaceholder &&
        (!quietOnly || quietIDs.has(person.id)) &&
        (!folded || foldedForMatching(person.displayName).includes(folded)),
    )
    return [...matches].sort(COMPARATORS[order])
  }, [people, query, quietIDs, quietOnly, order])

  const nextByPerson = useMemo(() => nextOpenReminderByPerson(reminders ?? []), [reminders])
  const observationsByPerson = useMemo(() => {
    const byPerson = new Map<string, Observation[]>()
    for (const observation of observations ?? []) {
      const rows = byPerson.get(observation.subjectID) ?? []
      rows.push(observation)
      byPerson.set(observation.subjectID, rows)
    }
    return byPerson
  }, [observations])

  return (
    <PageScaffold width="wide">
      <PageHeader
        title="People"
        subtitle={
          people
            ? quietOnly
              ? `${quietSuggestions.length} going quiet`
              : `${people.filter((p) => !p.isPlaceholder).length} on record`
            : undefined
        }
        actions={
          <>
            <input
              className="field field-inline"
              type="search"
              placeholder="Search people"
              aria-label="Search people"
              value={query}
              onChange={(event) => setQuery(event.target.value)}
            />
            <div
              ref={sortMenuRef}
              className="people-sort-menu"
              onBlur={(event) => {
                if (event.relatedTarget instanceof Node && sortMenuRef.current?.contains(event.relatedTarget)) return
                setSortOpen(false)
              }}
              onKeyDown={(event) => {
                if (event.key !== 'Escape' || !sortOpen) return
                event.stopPropagation()
                setSortOpen(false)
                sortMenuRef.current?.querySelector<HTMLButtonElement>('.people-sort-trigger')?.focus()
              }}
            >
              <IconButton
                className="people-sort-trigger"
                label={`Sort people: ${SORT_OPTIONS.find((option) => option.value === order)?.label}`}
                icon="sort"
                size={18}
                aria-expanded={sortOpen}
                aria-haspopup="menu"
                onClick={() => setSortOpen((open) => !open)}
              />
              {sortOpen && (
                <div className="people-sort-popover" role="menu" aria-label="Sort people">
                  <p className="people-sort-title">Sort by</p>
                  {SORT_OPTIONS.map((option) => (
                    <button
                      key={option.value}
                      type="button"
                      role="menuitemradio"
                      aria-checked={order === option.value}
                      onClick={() => {
                        setOrder(option.value)
                        setSortOpen(false)
                        window.setTimeout(() => {
                          sortMenuRef.current?.querySelector<HTMLButtonElement>('.people-sort-trigger')?.focus()
                        }, 0)
                      }}
                    >
                      <span>{option.label}</span>
                      {order === option.value && <Icon name="check" size={14} />}
                    </button>
                  ))}
                </div>
              )}
            </div>
            <IconButton
              className="page-header-add"
              label="New person"
              icon="plus"
              size={19}
              onClick={() => setCreating(true)}
            />
          </>
        }
      />

      {listed === undefined && <SkeletonRows avatar count={8} />}

      {listed && listed.length === 0 && !query && !quietOnly && (
        <EmptyState
          icon="people"
          headline="Nobody recorded yet"
          message="Add the people you talk to; everything else hangs off them."
          action={
            <Button variant="primary" icon="plus" onClick={() => setCreating(true)}>
              Add your first person
            </Button>
          }
        />
      )}

      {listed && listed.length === 0 && quietOnly && !query && (
        <p className="directory-empty">Nobody is going quiet.</p>
      )}

      {listed && listed.length === 0 && query && <p className="directory-empty">Nobody matches “{query}”.</p>}

      {listed && listed.length > 0 && (
        <div className="data-grid">
          <div className="data-grid-head" aria-hidden="true">
            <span />
            <span>Name</span>
            <span>Last contact</span>
            <span>Next follow-up</span>
          </div>
          {listed.map((person) => (
            <button key={person.id} type="button" className="person-row" onClick={() => navigate(`/people/${person.id}`)}>
              <Avatar name={person.displayName} colorName={person.colorName} unnamed={!person.hasStatedName} />
              <span className="person-main">
                <span className="row-title">{person.displayName}</span>
                {subtitle(person, observationsByPerson.get(person.id) ?? []) && (
                  <span className="row-subtitle">{subtitle(person, observationsByPerson.get(person.id) ?? [])}</span>
                )}
              </span>
              <span className="person-last">
                {person.lastContactAt
                  ? relativeDescription(person.lastContactAt, now)
                  : hasProfileData.has(person.id)
                    ? 'No conversation yet'
                    : 'Nothing recorded'}
              </span>
              <NextFollowUp reminder={nextByPerson.get(person.id)} now={now} />
            </button>
          ))}
        </div>
      )}

      {creating && (
        <CreatePersonSheet
          onClose={() => setCreating(false)}
          onCreated={(person) => {
            setCreating(false)
            navigate(`/people/${person.id}`)
          }}
        />
      )}
    </PageScaffold>
  )
}
