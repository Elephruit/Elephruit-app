import { useMemo, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { relativeDescription } from '../../domain/contact'
import { startOfDay, wholeDaysBetween } from '../../domain/dates'
import { foldedForMatching, type Person } from '../../domain/person'
import { bucketFor, nextOpenReminderByPerson, type Reminder } from '../../domain/reminders'
import { usePeople, useReminders } from '../../data/hooks'
import { useUID } from '../UserContext'
import { Avatar } from '../components/Avatar'
import { Button } from '../components/Button'
import { EmptyState } from '../components/EmptyState'
import { SkeletonRows } from '../components/Skeleton'
import { PageHeader } from '../shell/PageHeader'
import { PageScaffold } from '../shell/PageScaffold'
import { CreatePersonSheet } from './CreatePersonSheet'

type SortOrder = 'name' | 'recent' | 'quiet'

function subtitle(person: Person): string | null {
  if (person.roleTitle && person.organizationName) return `${person.roleTitle} · ${person.organizationName}`
  return person.roleTitle ?? person.organizationName
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
  const people = usePeople(uid)
  const reminders = useReminders(uid)
  const [creating, setCreating] = useState(false)
  const [query, setQuery] = useState('')
  const [order, setOrder] = useState<SortOrder>('name')
  const now = new Date()

  // Placeholders stay off the list — they surface on the pages of the people
  // they belong to, and in the to-fill-in queue, same as the Mac app.
  const listed = useMemo(() => {
    if (!people) return undefined
    const folded = foldedForMatching(query)
    const matches = people.filter(
      (person) =>
        !person.isPlaceholder && (!folded || foldedForMatching(person.displayName).includes(folded)),
    )
    return [...matches].sort(COMPARATORS[order])
  }, [people, query, order])

  const nextByPerson = useMemo(() => nextOpenReminderByPerson(reminders ?? []), [reminders])

  return (
    <PageScaffold width="wide">
      <PageHeader
        title="People"
        subtitle={people ? `${people.filter((p) => !p.isPlaceholder).length} on record` : undefined}
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
            <select
              className="field field-inline field-select"
              aria-label="Sort order"
              value={order}
              onChange={(event) => setOrder(event.target.value as SortOrder)}
            >
              <option value="name">By name</option>
              <option value="recent">Recently contacted</option>
              <option value="quiet">Longest quiet</option>
            </select>
            <Button variant="primary" icon="plus" onClick={() => setCreating(true)}>
              New person
            </Button>
          </>
        }
      />

      {listed === undefined && <SkeletonRows avatar count={8} />}

      {listed && listed.length === 0 && !query && (
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
              <Avatar name={person.displayName} colorName={person.colorName} />
              <span className="person-main">
                <span className="row-title">{person.displayName}</span>
                {subtitle(person) && <span className="row-subtitle">{subtitle(person)}</span>}
              </span>
              <span className="person-last">
                {person.lastContactAt ? relativeDescription(person.lastContactAt, now) : 'never'}
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
