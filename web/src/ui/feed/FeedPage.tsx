import { useEffect, useMemo, useState } from 'react'
import { useNavigate, useSearchParams } from 'react-router-dom'
import { CaptureComposer } from '../capture/CaptureComposer'
import { useCaptureController } from '../capture/useCaptureController'
import { auth } from '../../data/firebase'
import { useFeed, usePeople, useReminders } from '../../data/hooks'
import { startOfDay, wholeDaysBetween } from '../../domain/dates'
import { feedOverview } from '../../domain/overview'
import { bucketFor, sections, type Reminder } from '../../domain/reminders'
import type { Person } from '../../domain/person'
import { Avatar } from '../components/Avatar'
import { Button } from '../components/Button'
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
import { SkeletonRows } from '../components/Skeleton'
import { TimelineDayHeader, TimelineRow } from '../components/TimelineRow'
import { PageScaffold } from '../shell/PageScaffold'
import { DayBriefPanel } from './DayBriefPanel'

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

function dueChip(reminder: Reminder, now: Date): { label: string; className: string } {
  const bucket = bucketFor(reminder, now)
  if (bucket === 'overdue') {
    const days = wholeDaysBetween(startOfDay(reminder.dueAt!), startOfDay(now))
    return { label: `${days}d late`, className: 'chip chip-status-overdue' }
  }
  if (bucket === 'today') return { label: 'today', className: 'chip chip-status-today' }
  const date = reminder.dueAt ?? reminder.startAt
  if (!date) return { label: 'anytime', className: 'chip' }
  const days = wholeDaysBetween(startOfDay(now), startOfDay(date))
  const label =
    days <= 6
      ? date.toLocaleDateString(undefined, { weekday: 'short' })
      : date.toLocaleDateString(undefined, { month: 'short', day: 'numeric' })
  return { label: reminder.dueAt ? label : `starts ${label}`, className: 'chip' }
}

function FeedAside({
  reminders,
  people,
  quiet,
  now,
}: {
  reminders: Reminder[]
  people: Person[]
  quiet: Array<{ personID: string; displayName: string; daysSinceContact: number }>
  now: Date
}) {
  const navigate = useNavigate()
  const byID = useMemo(() => new Map(people.map((p) => [p.id, p])), [people])
  const upcoming = useMemo(
    () =>
      sections(reminders, now)
        .filter((group) => group.bucket === 'overdue' || group.bucket === 'today' || group.bucket === 'upcoming')
        .flatMap((group) => group.reminders)
        .slice(0, 5),
    [reminders, now],
  )

  return (
    <aside className="feed-aside">
      {upcoming.length > 0 && (
        <div className="aside-panel">
          <h4 className="aside-title">Coming up</h4>
          {upcoming.map((reminder) => {
            const chip = dueChip(reminder, now)
            const first = reminder.personIDs.map((id) => byID.get(id)).find(Boolean)
            return (
              <button key={reminder.id} type="button" className="aside-row" onClick={() => navigate('/followups')}>
                <span className="aside-row-text">
                  <b>{reminder.title}</b>
                  {first && <span>with {first.displayName}</span>}
                </span>
                <span className={chip.className}>{chip.label}</span>
              </button>
            )
          })}
        </div>
      )}
      {quiet.length > 0 && (
        <div className="aside-panel">
          <h4 className="aside-title">Reconnect</h4>
          {quiet.slice(0, 3).map((suggestion) => {
            const person = byID.get(suggestion.personID)
            return (
              <div key={suggestion.personID} className="aside-row" data-static>
                {person && <Avatar name={person.displayName} colorName={person.colorName} />}
                <span className="aside-row-text">
                  <b>{suggestion.displayName}</b>
                  <span>{Math.floor(suggestion.daysSinceContact / 7)} weeks since you spoke</span>
                </span>
                <Button variant="ghost" small onClick={() => navigate(`/?capture=1&person=${suggestion.personID}`)}>
                  Remember
                </Button>
              </div>
            )
          })}
        </div>
      )}
    </aside>
  )
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
  const [briefOpen, setBriefOpen] = useState(false)
  const [searchParams, setSearchParams] = useSearchParams()
  const capture = useCaptureController()

  useEffect(() => {
    if (searchParams.get('brief') === '1') {
      setBriefOpen(true)
      setSearchParams({}, { replace: true })
    }
  }, [searchParams, setSearchParams])

  // The URL owns open/closed: ?capture=1 opens the composer (optionally with
  // ?person=<id> preselected), its absence collapses it. Opening pushes a
  // history entry so browser Back closes the composer; collapsing replaces so
  // Back from the feed never resurrects it.
  const captureOpen = searchParams.get('capture') === '1'
  useEffect(() => {
    if (captureOpen && capture.mode === 'collapsed') {
      capture.open(searchParams.get('person'))
    } else if (!captureOpen && capture.mode !== 'collapsed') {
      capture.collapse()
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [captureOpen, capture.mode])

  function openComposer() {
    if (!captureOpen) setSearchParams({ capture: '1' })
  }

  function closeComposer() {
    if (captureOpen) setSearchParams({}, { replace: true })
  }

  // The saved beat: hold the confirmation for 500ms, then collapse.
  useEffect(() => {
    if (capture.mode !== 'saved') return
    const timer = window.setTimeout(closeComposer, 500)
    return () => window.clearTimeout(timer)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [capture.mode])

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
    <PageScaffold width="wide">
      <div className="feed-layout">
        <div className="feed-main">
          <header className="feed-greeting">
        <div className="feed-greeting-text">
          <h1>{greeting(now)}</h1>
          <p>
            {dateLine}
            {summary && <> · {summary}</>}
          </p>
        </div>
        {!briefOpen && (
          <Button variant="secondary" icon="sparkle" onClick={() => setBriefOpen(true)}>
            Prepare my day
          </Button>
        )}
      </header>

      {briefOpen && people && reminders && interactions && (
        <DayBriefPanel
          people={people}
          reminders={reminders}
          interactions={interactions}
          onClose={() => setBriefOpen(false)}
        />
      )}

      <CaptureComposer controller={capture} onRequestOpen={openComposer} onRequestClose={closeComposer} />

      {overview && (
        <div className="feed-summary">
          <button
            type="button"
            className="feed-summary-item"
            data-tone={overview.overdue > 0 ? 'overdue' : 'neutral'}
            onClick={() => navigate('/followups')}
          >
            <b className="tabular">{overview.overdue}</b>
            <span>{overview.overdue === 1 ? 'Overdue follow-up' : 'Overdue follow-ups'}</span>
            <small>{overview.oldestOverdueDays !== null ? `oldest: ${overview.oldestOverdueDays} days` : 'all clear'}</small>
          </button>
          <button
            type="button"
            className="feed-summary-item"
            data-tone={overview.today > 0 ? 'today' : 'neutral'}
            onClick={() => navigate('/followups')}
          >
            <b className="tabular">{overview.today}</b>
            <span>Due today</span>
            <small>{overview.firstTodayTitle ?? 'nothing scheduled'}</small>
          </button>
          <button
            type="button"
            className="feed-summary-item"
            data-tone={overview.quiet.length > 0 ? 'accent' : 'neutral'}
            data-span
            onClick={() => navigate('/people')}
          >
            <b className="tabular">{overview.quiet.length}</b>
            <span>Going quiet</span>
            <small>
              {overview.quiet.length > 0
                ? overview.quiet
                    .slice(0, 2)
                    .map((s) => `${s.displayName.split(' ')[0]} · ${Math.floor(s.daysSinceContact / 7)}w`)
                    .join(', ')
                : 'everyone is current'}
            </small>
          </button>
        </div>
      )}

      {groups === undefined && <SkeletonRows avatar />}

      {groups && groups.length === 0 && (
        <EmptyState
          icon="feed"
          headline="Nothing logged yet"
          message="Interactions you log read here as one continuous thread — coffee with Ana, the call about the move, the photos from the lake."
          action={
            <>
              <Button variant="primary" icon="plus" onClick={() => setSearchParams({ capture: '1' })}>
                Record your first memory
              </Button>
              <Button variant="secondary" onClick={() => navigate('/people')}>
                Add a person
              </Button>
            </>
          }
          hint="Dictate or type one thought; the review shows exactly what will be saved."
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
                  className="timeline-click"
                  data-link={entry.otherPeople.length > 0 || undefined}
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
        </div>
        {reminders && people && overview && (
          <FeedAside reminders={reminders} people={people} quiet={overview.quiet} now={now} />
        )}
      </div>
    </PageScaffold>
  )
}
