import { useMemo, useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { planCompleteReminder, planReopenReminder } from '../../domain/capture'
import { deriveLastContact, lastContactLine } from '../../domain/contact'
import {
  FILTER_LABELS,
  entryFromInteraction,
  entryFromObservation,
  entryFromReminder,
  entryIsContact,
  groupByMonth,
  matchesFilter,
  provenanceLine,
  type TimelineEntry,
  type TimelineFilter,
} from '../../domain/timeline'
import { applyPlan } from '../../data/applyPlan'
import {
  useObservationsFor,
  usePeople,
  usePerson,
  usePersonInteractions,
  useRemindersFor,
} from '../../data/hooks'
import { useUID } from '../UserContext'
import { Avatar } from '../components/Avatar'
import { Icon } from '../components/Icon'
import { TimelineRow } from '../components/TimelineRow'

const VISIBLE_FILTERS: TimelineFilter[] = ['everything', 'conversations', 'notes', 'commitments']

function monthLabel(month: Date): string {
  return month.toLocaleDateString(undefined, { month: 'long', year: 'numeric' })
}

function entryBadge(entry: TimelineEntry): { icon: string; tint: string } {
  if (entry.kind === 'interaction') {
    return { icon: entry.interactionKind ?? 'other', tint: 'var(--color-accent)' }
  }
  if (entry.kind === 'reminder') {
    return entry.isOpen
      ? { icon: 'circle', tint: 'var(--color-due-today)' }
      : { icon: 'check', tint: 'var(--color-completed)' }
  }
  return { icon: 'sparkle', tint: 'var(--color-capture)' }
}

export function PersonPage() {
  const uid = useUID()
  const navigate = useNavigate()
  const { personID } = useParams()
  const person = usePerson(uid, personID!)
  const people = usePeople(uid)
  const interactions = usePersonInteractions(uid, personID!)
  const observations = useObservationsFor(uid, personID!)
  const reminders = useRemindersFor(uid, personID!)
  const [filter, setFilter] = useState<TimelineFilter>('everything')

  const entries = useMemo(() => {
    if (!interactions || !observations || !reminders || !people) return undefined
    const byID = new Map(people.map((p) => [p.id, p]))
    return [
      ...interactions.map((i) => entryFromInteraction(i, byID, personID!)),
      ...observations.map(entryFromObservation),
      ...reminders.map(entryFromReminder),
    ]
  }, [interactions, observations, reminders, people, personID])

  const months = useMemo(
    () => (entries ? groupByMonth(entries.filter((e) => matchesFilter(filter, e))) : undefined),
    [entries, filter],
  )

  const openFollowUps = reminders?.filter((r) => r.status === 'open') ?? []

  if (person === undefined) return <main className="page" />
  if (person === null) {
    return (
      <main className="page">
        <p className="row-subtitle">This record no longer exists.</p>
      </main>
    )
  }

  // The page shows the truth, derived live; the list may lean on the cache.
  const derivedLastContact = interactions ? deriveLastContact(interactions, person.id) : person.lastContactAt
  const roleLine = [person.roleTitle, person.organizationName].filter(Boolean).join(' · ')

  async function toggleReminder(id: string, isOpen: boolean) {
    const { plan } = isOpen ? planCompleteReminder(id, new Date()) : planReopenReminder(id)
    await applyPlan(uid, plan)
  }

  return (
    <main className="page">
      <button type="button" className="button-plain button" onClick={() => navigate(-1)}>
        <Icon name="back" size={16} /> Back
      </button>

      <header
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: 'var(--space-large)',
          margin: 'var(--space-large) 0 var(--space-small)',
        }}
      >
        <span style={{ transform: 'scale(1.6)', transformOrigin: 'left center' }}>
          <Avatar name={person.displayName} colorName={person.colorName} />
        </span>
        <span>
          <h1 className="page-title" style={{ marginBottom: 2 }}>
            {person.displayName}
          </h1>
          {roleLine && <p className="row-subtitle">{roleLine}</p>}
          <p className="row-subtitle">{lastContactLine(derivedLastContact, new Date())}</p>
        </span>
      </header>

      <button
        type="button"
        className="button"
        style={{ margin: 'var(--space-medium) 0' }}
        onClick={() => navigate(`/log?person=${person.id}`)}
      >
        <Icon name="plus" size={16} /> Log an interaction
      </button>

      {openFollowUps.length > 0 && (
        <>
          <h2 className="section-header">Open follow-ups</h2>
          {openFollowUps.map((reminder) => (
            <div key={reminder.id} className="row" style={{ cursor: 'default' }}>
              <button
                type="button"
                className="button-plain button"
                style={{ padding: 0, color: 'var(--color-due-today)' }}
                aria-label={`Complete ${reminder.title}`}
                onClick={() => void toggleReminder(reminder.id, true)}
              >
                <Icon name="circle" size={20} />
              </button>
              <span className="row-title">{reminder.title}</span>
            </div>
          ))}
        </>
      )}

      <h2 className="section-header">History</h2>
      <div className="chip-row-scroll">
        {VISIBLE_FILTERS.map((f) => (
          <button
            key={f}
            type="button"
            className="chip"
            aria-pressed={filter === f}
            onClick={() => setFilter(f)}
          >
            {FILTER_LABELS[f]}
          </button>
        ))}
      </div>

      {months && months.length === 0 && (
        <p className="row-subtitle" style={{ padding: 'var(--space-large) 0' }}>
          Nothing here yet.
        </p>
      )}

      {months?.map((group, groupIndex) => (
        <section key={group.month.getTime()}>
          <div className="timeline-day-header">
            <div className="timeline-rail" />
            <h3 className="timeline-day-title" style={{ font: 'var(--text-section)', textTransform: 'uppercase', letterSpacing: '0.4px', color: 'var(--color-text-secondary)' }}>
              {monthLabel(group.month)}
            </h3>
          </div>
          {group.entries.map((entry, index) => {
            const badge = entryBadge(entry)
            const isLastRow = groupIndex === months.length - 1 && index === group.entries.length - 1
            return (
              <TimelineRow
                key={`${entry.kind}-${entry.id}`}
                rail={isLastRow ? 'tail' : 'line'}
                tint={entry.kind === 'interaction' && !entryIsContact(entry) ? 'var(--color-personal)' : badge.tint}
                badge={<Icon name={badge.icon} size={13} />}
                badgeLabel={
                  entry.kind === 'reminder'
                    ? entry.isOpen
                      ? `Complete ${entry.title}`
                      : `Reopen ${entry.title}`
                    : undefined
                }
                onBadgeClick={
                  entry.kind === 'reminder'
                    ? () => void toggleReminder(entry.id, entry.isOpen)
                    : undefined
                }
              >
                <div className="timeline-title-line">
                  <span className="timeline-title">{entry.title}</span>
                  <span className="timeline-time">
                    {entry.date.toLocaleDateString(undefined, { month: 'short', day: 'numeric' })}
                  </span>
                </div>
                <p className="timeline-subtitle">{provenanceLine(entry)}</p>
                {entry.excerpt && <p className="timeline-excerpt">{entry.excerpt}</p>}
              </TimelineRow>
            )
          })}
        </section>
      ))}
    </main>
  )
}
