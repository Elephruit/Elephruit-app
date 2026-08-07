import { useEffect, useMemo, useState } from 'react'
import { useNavigate, useSearchParams } from 'react-router-dom'
import { CaptureComposer } from '../capture/CaptureComposer'
import { useCaptureController } from '../capture/useCaptureController'
import { auth } from '../../data/firebase'
import { useFeed, useMemoryFeed, usePeople, useReminders } from '../../data/hooks'
import { feedOverview } from '../../domain/overview'
import { sections, type Reminder } from '../../domain/reminders'
import { formatScheduleSummary } from '../../domain/temporal'
import type { Person } from '../../domain/person'
import { Button } from '../components/Button'
import { PersonIdentity } from '../components/PersonIdentity'
import { useUID } from '../UserContext'
import { EmptyState } from '../components/EmptyState'
import { SkeletonRows } from '../components/Skeleton'
import { PageScaffold } from '../shell/PageScaffold'
import { DayBriefPanel } from './DayBriefPanel'
import { FollowUpSheet } from '../followups/FollowUpSheet'
import { MemoryRail } from './MemoryRail'

function greeting(now: Date): string {
  const hour = now.getHours()
  const daypart = hour < 12 ? 'morning' : hour < 18 ? 'afternoon' : 'evening'
  const first = auth.currentUser?.displayName?.trim().split(/\s+/)[0]
  return first ? `Good ${daypart}, ${first}.` : `Good ${daypart}.`
}

function NextUpSection({
  reminders,
  people,
  now,
  onOpen,
  compact = false,
}: {
  reminders: Reminder[]
  people: Person[]
  now: Date
  onOpen: (reminder: Reminder) => void
  compact?: boolean
}) {
  const byID = useMemo(() => new Map(people.map((p) => [p.id, p])), [people])
  const upcoming = useMemo(
    () =>
      sections(reminders, now)
        .filter((group) => group.bucket !== 'someday')
        .flatMap((group) => group.reminders)
        .slice(0, 3),
    [reminders, now],
  )
  if (upcoming.length === 0) return null

  return (
    <section className={compact ? 'rail-section feed-inline-next' : 'rail-section'}>
      <h4 className="rail-section-title">Next up</h4>
      {upcoming.map((reminder) => {
        const person = reminder.personIDs.map((id) => byID.get(id)).find(Boolean)
        const schedule = formatScheduleSummary(reminder) ?? 'Anytime'
        return (
          <button key={reminder.id} type="button" className="rail-row" onClick={() => onOpen(reminder)}>
            <span className="rail-row-text">
              <b>{reminder.title}</b>
              {person && (
                <span className="rail-row-person">
                  <PersonIdentity person={person} />
                </span>
              )}
            </span>
            <span className="rail-row-when tabular">{schedule}</span>
          </button>
        )
      })}
    </section>
  )
}

function FeedAside({
  reminders,
  people,
  quiet,
  now,
  onOpenReminder,
}: {
  reminders: Reminder[]
  people: Person[]
  quiet: Array<{ personID: string; displayName: string; daysSinceContact: number }>
  now: Date
  onOpenReminder: (reminder: Reminder) => void
}) {
  const navigate = useNavigate()
  const byID = useMemo(() => new Map(people.map((p) => [p.id, p])), [people])

  return (
    <aside className="feed-aside">
      <NextUpSection reminders={reminders} people={people} now={now} onOpen={onOpenReminder} />

      {quiet.length > 0 && (
        <section className="rail-section">
          <h4 className="rail-section-title">Reconnect</h4>
          {quiet.slice(0, 2).map((suggestion) => {
            const person = byID.get(suggestion.personID)
            if (!person) return null
            return (
              <div key={suggestion.personID} className="rail-row" data-static>
                <span className="rail-row-text">
                  <PersonIdentity
                    person={person}
                    link
                    detail={`${Math.floor(suggestion.daysSinceContact / 7)} weeks since you spoke`}
                  />
                </span>
                <Button variant="ghost" small onClick={() => navigate(`/?capture=1&person=${suggestion.personID}`)}>
                  Remember
                </Button>
              </div>
            )
          })}
        </section>
      )}

      <section className="rail-section">
        <button type="button" className="rail-see-all" onClick={() => navigate('/followups')}>
          See all follow-ups
        </button>
      </section>
    </aside>
  )
}

export function FeedPage() {
  const uid = useUID()
  const navigate = useNavigate()
  const feed = useMemoryFeed(uid)
  const people = usePeople(uid)
  const reminders = useReminders(uid)
  const interactions = useFeed(uid)
  const now = new Date()
  const [briefOpen, setBriefOpen] = useState(false)
  const [editingReminder, setEditingReminder] = useState<Reminder | null>(null)
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

  const overview = useMemo(
    () => (reminders && people ? feedOverview(reminders, people, now) : undefined),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [reminders, people],
  )

  const openCount = useMemo(() => (reminders ?? []).filter((r) => r.status === 'open').length, [reminders])

  // The greeting never equates "nothing overdue" with "nothing recorded":
  // open follow-ups are acknowledged even when none is late.
  const summary = useMemo(() => {
    if (!overview) return null
    const parts: string[] = []
    const owed = overview.overdue + overview.today
    if (owed > 0) parts.push(`${owed} follow-up${owed === 1 ? '' : 's'} need${owed === 1 ? 's' : ''} attention`)
    else if (openCount > 0)
      parts.push(`${openCount} open follow-up${openCount === 1 ? '' : 's'} · nothing is overdue`)
    if (overview.quiet.length > 0)
      parts.push(`${overview.quiet.length} ${overview.quiet.length === 1 ? 'person is' : 'people are'} going quiet`)
    if (parts.length === 0) return 'Nothing is overdue and nobody has gone quiet.'
    return parts.join(' and ') + '.'
  }, [overview, openCount])

  const dateLine = now.toLocaleDateString(undefined, { weekday: 'long', month: 'long', day: 'numeric' })

  const inlineNextUp =
    reminders && people ? (
      <NextUpSection reminders={reminders} people={people} now={now} onOpen={setEditingReminder} compact />
    ) : null

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

          {feed.status === 'loading' && <SkeletonRows avatar />}

          {feed.status === 'error' && (
            <div className="feed-error" role="alert">
              <p>The feed could not load. Your memories are safe — this is a connection problem.</p>
              <Button variant="secondary" onClick={feed.retry}>
                Try again
              </Button>
            </div>
          )}

          {feed.status === 'ready' && feed.moments.length === 0 && (
            <EmptyState
              icon="feed"
              headline="Nothing logged yet"
              message="Memories you record read here as one continuous thread — coffee with Ana, the call about the move, the dossier that became a person."
              action={
                <>
                  <Button variant="primary" icon="plus" onClick={() => setSearchParams({ capture: '1' })}>
                    Add your first update
                  </Button>
                  <Button variant="secondary" onClick={() => navigate('/people')}>
                    Add a person
                  </Button>
                </>
              }
              hint="Dictate or type one thought; the review shows exactly what will be saved."
            />
          )}

          {feed.status === 'ready' && feed.moments.length > 0 && (
            <MemoryRail moments={feed.moments} now={now} inlineAfterFirstGroup={inlineNextUp} />
          )}
        </div>

        {reminders && people && overview && (
          <FeedAside
            reminders={reminders}
            people={people}
            quiet={overview.quiet}
            now={now}
            onOpenReminder={setEditingReminder}
          />
        )}
      </div>

      {editingReminder && people && (
        <FollowUpSheet existing={editingReminder} people={people} onClose={() => setEditingReminder(null)} />
      )}
    </PageScaffold>
  )
}
