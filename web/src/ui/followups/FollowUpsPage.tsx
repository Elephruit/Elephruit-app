import { useMemo, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { Avatar } from '../components/Avatar'
import { Button } from '../components/Button'
import { MetricTile } from '../components/MetricTile'
import { SegmentedControl } from '../components/SegmentedControl'
import { SkeletonRows } from '../components/Skeleton'
import { PageHeader } from '../shell/PageHeader'
import { PageScaffold } from '../shell/PageScaffold'
import { planCompleteReminder, planQuickReschedule, planReopenReminder, planUpdateReminder } from '../../domain/capture'
import { relativeDescription } from '../../domain/contact'
import { startOfDay } from '../../domain/dates'
import { BUCKET_TITLES, bucketFor, completedList, sections, type Reminder } from '../../domain/reminders'
import { formatScheduleSummary } from '../../domain/temporal'
import { applyPlan } from '../../data/applyPlan'
import { usePeople, useReminders } from '../../data/hooks'
import { useUID } from '../UserContext'
import { EmptyState } from '../components/EmptyState'
import { Icon } from '../components/Icon'
import { FollowUpSheet } from './FollowUpSheet'

/// The structured schedule chip — never the title's embedded phrase. Someday
/// rows sit under their heading, so the chip is redundant there.
function dateChip(reminder: Reminder, now: Date): { text: string; tone: 'overdue' | 'today' | null } | null {
  if (reminder.isSomeday) return null
  const text = formatScheduleSummary(reminder)
  if (!text) return null
  const bucket = bucketFor(reminder, now)
  if (bucket === 'overdue') return { text, tone: 'overdue' }
  if (bucket === 'today') return { text, tone: 'today' }
  return { text, tone: null }
}

/// The quick action follows the schedule mode: a deadline moves, a start-only
/// item starts, an unscheduled one gets scheduled — the copy says which.
function quickAction(reminder: Reminder): { label: string; kind: 'deadline' | 'start' } {
  if (reminder.dueAt) return { label: 'Move to tomorrow', kind: 'deadline' }
  if (reminder.startAt) return { label: 'Start tomorrow', kind: 'start' }
  return { label: 'Schedule tomorrow', kind: 'deadline' }
}

export function FollowUpsPage() {
  const uid = useUID()
  const navigate = useNavigate()
  const reminders = useReminders(uid)
  const people = usePeople(uid)
  const [view, setView] = useState<'open' | 'completed'>('open')
  const [editing, setEditing] = useState<Reminder | null>(null)
  const [creating, setCreating] = useState(false)
  // One clock per mount — a fresh Date each render silently drifted past the memo.
  const [now] = useState(() => new Date())

  const groups = useMemo(() => (reminders ? sections(reminders, now) : undefined), [reminders, now])
  const done = useMemo(() => (reminders ? completedList(reminders) : []), [reminders])
  const peopleByID = useMemo(() => new Map((people ?? []).map((p) => [p.id, p])), [people])

  const counts = useMemo(() => {
    const byBucket = new Map((groups ?? []).map((group) => [group.bucket, group.reminders.length]))
    return {
      overdue: byBucket.get('overdue') ?? 0,
      today: byBucket.get('today') ?? 0,
      upcoming: byBucket.get('upcoming') ?? 0,
      unscheduled: (byBucket.get('anytime') ?? 0) + (byBucket.get('someday') ?? 0),
    }
  }, [groups])

  async function complete(reminder: Reminder) {
    await applyPlan(uid, planCompleteReminder(reminder.id, new Date()).plan)
  }

  async function reopen(reminder: Reminder) {
    await applyPlan(uid, planReopenReminder(reminder.id).plan)
  }

  async function rescheduleTomorrow(reminder: Reminder) {
    const tomorrow = new Date(startOfDay(new Date()))
    tomorrow.setDate(tomorrow.getDate() + 1)
    const action = quickAction(reminder)
    if (action.kind === 'start') {
      await applyPlan(uid, planQuickReschedule(reminder.id, tomorrow).plan)
      return
    }
    // Deadline moves stay date-granular; a timed deadline pushed to tomorrow
    // becomes a date-only one rather than inventing a time.
    await applyPlan(
      uid,
      planUpdateReminder(reminder.id, {
        dueAt: tomorrow,
        isSomeday: false,
        duePrecision: 'date',
        scheduleTimeZone: null,
      }).plan,
    )
  }

  return (
    <PageScaffold width="wide">
      <PageHeader
        title="Follow-ups"
        actions={
          <>
            <SegmentedControl
              label="Open or completed"
              options={[
                { value: 'open', label: 'Open' },
                { value: 'completed', label: 'Completed' },
              ]}
              value={view}
              onChange={setView}
            />
            <Button variant="primary" icon="plus" onClick={() => setCreating(true)}>
              New follow-up
            </Button>
          </>
        }
      />

      <div className="task-inbox">
        {view === 'open' && groups && (
          <div className="metric-tiles metric-tiles-four">
            <MetricTile value={counts.overdue} label="Overdue" tone={counts.overdue > 0 ? 'overdue' : 'neutral'} />
            <MetricTile value={counts.today} label="Today" tone={counts.today > 0 ? 'today' : 'neutral'} />
            <MetricTile value={counts.upcoming} label="Upcoming" />
            <MetricTile value={counts.unscheduled} label="Unscheduled" />
          </div>
        )}

        {groups === undefined && <SkeletonRows count={5} />}

        {view === 'open' && groups && groups.length === 0 && (
          <EmptyState
            icon="bell"
            headline="Nothing owed"
            message="Follow-ups from logged interactions gather here, bucketed by what their dates actually say."
            action={
              <Button variant="primary" icon="plus" onClick={() => navigate('/?capture=1')}>
                Quick capture
              </Button>
            }
            hint="End a capture with what you owe — “need to send her the list” becomes a follow-up."
          />
        )}

        {view === 'open' &&
          groups?.map((group) => (
            <section key={group.bucket}>
              <h2 className="section-header" data-tone={group.bucket === 'overdue' ? 'overdue' : undefined}>
                {BUCKET_TITLES[group.bucket]}
              </h2>
              {group.reminders.map((reminder) => {
                const chip = dateChip(reminder, now)
                return (
                  <div key={reminder.id} className="task-row">
                    <button
                      type="button"
                      className="complete-ring"
                      aria-label={`Complete ${reminder.title}`}
                      onClick={() => void complete(reminder)}
                    />
                    <button type="button" className="task-main" onClick={() => setEditing(reminder)}>
                      <span className="row-title">{reminder.title}</span>
                      <span className="task-meta">
                        {chip && (
                          <span
                            className={
                              chip.tone === 'overdue'
                                ? 'chip chip-status-overdue'
                                : chip.tone === 'today'
                                  ? 'chip chip-status-today'
                                  : 'chip'
                            }
                          >
                            {chip.text}
                          </span>
                        )}
                        {reminder.personIDs.map((id) => {
                          const person = peopleByID.get(id)
                          if (!person) return null
                          return (
                            <span
                              key={id}
                              role="link"
                              tabIndex={0}
                              className="task-person"
                              onClick={(event) => {
                                event.stopPropagation()
                                navigate(`/people/${id}`)
                              }}
                              onKeyDown={(event) => event.key === 'Enter' && navigate(`/people/${id}`)}
                            >
                              <Avatar name={person.displayName} colorName={person.colorName} small />
                              {person.displayName}
                            </span>
                          )
                        })}
                      </span>
                    </button>
                    <span className="task-actions">
                      <Button variant="ghost" small onClick={() => void rescheduleTomorrow(reminder)}>
                        {quickAction(reminder).label}
                      </Button>
                      <Button variant="ghost" small onClick={() => setEditing(reminder)}>
                        Edit
                      </Button>
                    </span>
                  </div>
                )
              })}
            </section>
          ))}

        {view === 'completed' && (
          <section>
            {done.length === 0 && <p className="row-subtitle">Nothing completed yet.</p>}
            {done.map((reminder) => (
              <div key={reminder.id} className="task-row task-row-done">
                <button
                  type="button"
                  className="button button-plain"
                  style={{ padding: 0, color: 'var(--color-completed)', height: 'auto' }}
                  aria-label={`Reopen ${reminder.title}`}
                  onClick={() => void reopen(reminder)}
                >
                  <Icon name="check-circle" size={20} />
                </button>
                <span className="row-title">{reminder.title}</span>
                {reminder.completedAt && (
                  <span className="row-trailing">{relativeDescription(reminder.completedAt, now)}</span>
                )}
              </div>
            ))}
          </section>
        )}
      </div>

      {(creating || editing) && people && (
        <FollowUpSheet
          existing={editing}
          people={people}
          onClose={() => {
            setCreating(false)
            setEditing(null)
          }}
        />
      )}
    </PageScaffold>
  )
}
