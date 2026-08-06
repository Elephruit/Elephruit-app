import { useMemo } from 'react'
import { useNavigate } from 'react-router-dom'
import { auth } from '../../data/firebase'
import { useFeed, usePeople, useReminders } from '../../data/hooks'
import { startOfDay, wholeDaysBetween } from '../../domain/dates'
import { feedOverview } from '../../domain/overview'
import {
  entryFromInteraction,
  entryIsContact,
  groupByDay,
  provenanceLine,
  type TimelineEntry,
} from '../../domain/timeline'
import { useUID } from '../UserContext'
import { EmptyState } from '../components/EmptyState'
import { Icon } from '../components/Icon'
import { MetricTile } from '../components/MetricTile'
import { TimelineDayHeader, TimelineRow } from '../components/TimelineRow'
import { PageScaffold } from '../shell/PageScaffold'

function dayLabel(day: Date, now: Date): string {
  const days = wholeDaysBetween(day, startOfDay(now))
  if (days === 0) return 'Today'
  if (days === 1) return 'Yesterday'
  return day.toLocaleDateString(undefined, { weekday: 'long', month: 'long', day: 'numeric' })
}

function timeLabel(date: Date): string {
  return date.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' })
}

function greeting(now: Date): string {
  const hour = now.getHours()
  const daypart = hour < 12 ? 'morning' : hour < 18 ? 'afternoon' : 'evening'
  const first = auth.currentUser?.displayName?.trim().split(/\s+/)[0]
  return first ? `Good ${daypart}, ${first}.` : `Good ${daypart}.`
}

function FeedRowContent({ entry }: { entry: TimelineEntry }) {
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
  const reminders = useReminders(uid)
  const now = new Date()

  const groups = useMemo(() => {
    if (!interactions || !people) return undefined
    const byID = new Map(people.map((p) => [p.id, p]))
    return groupByDay(interactions.map((i) => entryFromInteraction(i, byID, null)))
  }, [interactions, people])

  const overview = useMemo(
    () => (reminders && people ? feedOverview(reminders, people, now) : undefined),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [reminders, people],
  )

  const summary = useMemo(() => {
    if (!overview) return null
    const parts: string[] = []
    const owed = overview.overdue + overview.today
    if (owed > 0) parts.push(`${owed} follow-up${owed === 1 ? '' : 's'} need${owed === 1 ? 's' : ''} attention`)
    if (overview.quiet.length > 0)
      parts.push(`${overview.quiet.length} ${overview.quiet.length === 1 ? 'person is' : 'people are'} going quiet`)
    if (parts.length === 0) return 'Nothing is overdue and nobody has gone quiet.'
    return parts.join(' and ') + '.'
  }, [overview])

  const dateLine = now.toLocaleDateString(undefined, { weekday: 'long', month: 'long', day: 'numeric' })

  return (
    <PageScaffold width="reading">
      <header className="feed-greeting">
        <h1>{greeting(now)}</h1>
        <p>
          {dateLine}
          {summary && <> · {summary}</>}
        </p>
      </header>

      <button type="button" className="composer-entry" onClick={() => navigate('/capture')}>
        <Icon name="plus" size={17} />
        <span>What happened?</span>
        <span className="composer-entry-hint">open capture</span>
      </button>

      {overview && (
        <div className="metric-tiles">
          <MetricTile
            value={overview.overdue}
            label={overview.overdue === 1 ? 'Overdue follow-up' : 'Overdue follow-ups'}
            tone={overview.overdue > 0 ? 'overdue' : 'neutral'}
            detail={overview.oldestOverdueDays !== null ? `oldest: ${overview.oldestOverdueDays} days` : 'all clear'}
            onClick={() => navigate('/followups')}
          />
          <MetricTile
            value={overview.today}
            label="Due today"
            tone={overview.today > 0 ? 'today' : 'neutral'}
            detail={overview.firstTodayTitle ?? 'nothing scheduled'}
            onClick={() => navigate('/followups')}
          />
          <MetricTile
            value={overview.quiet.length}
            label="Going quiet"
            tone={overview.quiet.length > 0 ? 'accent' : 'neutral'}
            detail={
              overview.quiet.length > 0
                ? overview.quiet
                    .slice(0, 2)
                    .map((s) => `${s.displayName.split(' ')[0]} · ${Math.floor(s.daysSinceContact / 7)}w`)
                    .join(', ')
                : 'everyone is current'
            }
            onClick={() => navigate('/people')}
          />
        </div>
      )}

      {groups && groups.length === 0 && (
        <EmptyState
          icon="feed"
          headline="Nothing logged yet"
          message="Interactions you log will read here as one continuous thread."
        />
      )}

      {groups?.map((group, groupIndex) => (
        <section key={group.day.getTime()}>
          <TimelineDayHeader title={dayLabel(group.day, now)} first={groupIndex === 0} />
          {group.entries.map((entry, index) => {
            const isLastRow = groupIndex === groups.length - 1 && index === group.entries.length - 1
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
    </PageScaffold>
  )
}
