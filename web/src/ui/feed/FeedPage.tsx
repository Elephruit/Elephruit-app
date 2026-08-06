import { useMemo } from 'react'
import { useNavigate } from 'react-router-dom'
import { startOfDay, wholeDaysBetween } from '../../domain/dates'
import {
  entryFromInteraction,
  entryIsContact,
  groupByDay,
  provenanceLine,
  type TimelineEntry,
} from '../../domain/timeline'
import { useFeed, usePeople } from '../../data/hooks'
import { useUID } from '../UserContext'
import { EmptyState } from '../components/EmptyState'
import { Icon } from '../components/Icon'
import { TimelineDayHeader, TimelineRow } from '../components/TimelineRow'

export function dayLabel(day: Date, now: Date): string {
  const days = wholeDaysBetween(day, startOfDay(now))
  if (days === 0) return 'Today'
  if (days === 1) return 'Yesterday'
  return day.toLocaleDateString(undefined, { weekday: 'long', month: 'long', day: 'numeric' })
}

function timeLabel(date: Date): string {
  return date.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' })
}

export function FeedRowContent({ entry }: { entry: TimelineEntry }) {
  return (
    <>
      <div className="timeline-title-line">
        <span className="timeline-title">{entry.title}</span>
        <span className="timeline-time">{timeLabel(entry.date)}</span>
      </div>
      <p className="timeline-subtitle">{provenanceLine(entry)}</p>
      {entry.excerpt && <p className="timeline-excerpt">{entry.excerpt}</p>}
    </>
  )
}

export function FeedPage() {
  const uid = useUID()
  const navigate = useNavigate()
  const interactions = useFeed(uid)
  const people = usePeople(uid)

  const groups = useMemo(() => {
    if (!interactions || !people) return undefined
    const byID = new Map(people.map((p) => [p.id, p]))
    return groupByDay(interactions.map((i) => entryFromInteraction(i, byID, null)))
  }, [interactions, people])

  return (
    <main className="page">
      <h1 className="page-title">Feed</h1>

      {groups && groups.length === 0 && (
        <EmptyState
          icon="feed"
          headline="Nothing logged yet"
          message="Interactions you log will read here as one continuous thread."
        />
      )}

      {groups?.map((group, groupIndex) => (
        <section key={group.day.getTime()}>
          <TimelineDayHeader title={dayLabel(group.day, new Date())} first={groupIndex === 0} />
          {group.entries.map((entry, index) => {
            const isLastRow =
              groupIndex === groups.length - 1 && index === group.entries.length - 1
            return (
              <TimelineRow
                key={entry.id}
                rail={isLastRow ? 'tail' : 'line'}
                tint={entryIsContact(entry) ? 'var(--color-accent)' : 'var(--color-personal)'}
                badge={<Icon name={entry.interactionKind ?? 'other'} size={14} />}
              >
                <div
                  role="button"
                  tabIndex={0}
                  style={{ cursor: entry.otherPeople.length > 0 ? 'pointer' : 'default' }}
                  onClick={() => {
                    const first = entry.otherPeople[0]
                    if (first) navigate(`/people/${first.id}`)
                  }}
                  onKeyDown={(event) => {
                    if (event.key === 'Enter' && entry.otherPeople[0]) {
                      navigate(`/people/${entry.otherPeople[0].id}`)
                    }
                  }}
                >
                  <FeedRowContent entry={entry} />
                </div>
              </TimelineRow>
            )
          })}
        </section>
      ))}
    </main>
  )
}
