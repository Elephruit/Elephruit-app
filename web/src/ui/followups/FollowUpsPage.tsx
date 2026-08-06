import { useMemo, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { Avatar } from '../components/Avatar'
import { Button } from '../components/Button'
import { MetricTile } from '../components/MetricTile'
import { SegmentedControl } from '../components/SegmentedControl'
import { SkeletonRows } from '../components/Skeleton'
import { PageHeader } from '../shell/PageHeader'
import { PageScaffold } from '../shell/PageScaffold'
import {
  planCompleteReminder,
  planCreateReminder,
  planQuickReschedule,
  planReopenReminder,
  planUpdateReminder,
} from '../../domain/capture'
import { relativeDescription } from '../../domain/contact'
import { startOfDay } from '../../domain/dates'
import type { Person } from '../../domain/person'
import { BUCKET_TITLES, bucketFor, completedList, sections, type Reminder } from '../../domain/reminders'
import { applyPlan } from '../../data/applyPlan'
import { usePeople, useReminders } from '../../data/hooks'
import { useUID } from '../UserContext'
import { EmptyState } from '../components/EmptyState'
import { Icon } from '../components/Icon'
import { Dialog } from '../components/Dialog'
import { fromLocalInputValue, toLocalDateValue } from '../dateInput'
import { ParticipantPicker } from '../log/ParticipantPicker'

function atNoon(dateValue: string): Date {
  return fromLocalInputValue(`${dateValue}T12:00`)
}

function dateChip(reminder: Reminder, now: Date): { text: string; tone: 'overdue' | 'today' | null } | null {
  const bucket = bucketFor(reminder, now)
  if (reminder.dueAt) {
    const phrase = `due ${relativeDescription(reminder.dueAt, now)}`
    if (bucket === 'overdue') return { text: phrase, tone: 'overdue' }
    if (bucket === 'today') return { text: 'due today', tone: 'today' }
    return { text: phrase, tone: null }
  }
  if (reminder.startAt) return { text: `starts ${relativeDescription(reminder.startAt, now)}`, tone: null }
  return null
}

function ReminderSheet({
  existing,
  people,
  onClose,
}: {
  existing: Reminder | null
  people: Person[]
  onClose: () => void
}) {
  const uid = useUID()
  const [title, setTitle] = useState(existing?.title ?? '')
  const [notes, setNotes] = useState(existing?.notes ?? '')
  const [startAt, setStartAt] = useState(existing?.startAt ? toLocalDateValue(existing.startAt) : '')
  const [dueAt, setDueAt] = useState(existing?.dueAt ? toLocalDateValue(existing.dueAt) : '')
  const [isSomeday, setIsSomeday] = useState(existing?.isSomeday ?? false)
  const [personIDs, setPersonIDs] = useState<Set<string>>(new Set(existing?.personIDs ?? []))
  const [saving, setSaving] = useState(false)

  async function save() {
    if (!title.trim() || saving) return
    setSaving(true)
    const fields = {
      title: title.trim(),
      notes: notes.trim() || null,
      startAt: startAt ? atNoon(startAt) : null,
      dueAt: dueAt ? atNoon(dueAt) : null,
      isSomeday,
      personIDs: [...personIDs],
    }
    const { plan } = existing
      ? planUpdateReminder(existing.id, fields)
      : planCreateReminder(fields, new Date())
    await applyPlan(uid, plan)
    onClose()
  }

  return (
    <Dialog title={existing ? 'Edit follow-up' : 'New follow-up'} onClose={onClose}>
      <label className="field-label" htmlFor="rem-title">
        What is owed
      </label>
      <input
        id="rem-title"
        className="field"
        value={title}
        onChange={(event) => setTitle(event.target.value)}
        autoFocus={!existing}
      />

      <label className="field-label" htmlFor="rem-notes">
        Notes
      </label>
      <input id="rem-notes" className="field" value={notes} onChange={(event) => setNotes(event.target.value)} />

      <label className="field-label" htmlFor="rem-start">
        Start — when it becomes available; never turns red
      </label>
      <input
        id="rem-start"
        className="field"
        type="date"
        value={startAt}
        onChange={(event) => setStartAt(event.target.value)}
      />

      <label className="field-label" htmlFor="rem-due">
        Deadline — the only date that can make it late
      </label>
      <input
        id="rem-due"
        className="field"
        type="date"
        value={dueAt}
        onChange={(event) => setDueAt(event.target.value)}
      />

      <label className="field-label" style={{ display: 'flex', alignItems: 'center', gap: 'var(--space-small)' }}>
        <input type="checkbox" checked={isSomeday} onChange={(event) => setIsSomeday(event.target.checked)} />
        Someday — deliberately parked
      </label>

      <label className="field-label">People</label>
      <ParticipantPicker
        people={people}
        pendingNew={[]}
        selectedIDs={personIDs}
        allowCreate={false}
        onToggle={(id) =>
          setPersonIDs((current) => {
            const next = new Set(current)
            if (next.has(id)) next.delete(id)
            else next.add(id)
            return next
          })
        }
        onCreate={() => {}}
      />

      <div className="sheet-actions">
        <button type="button" className="button button-quiet" onClick={onClose}>
          Cancel
        </button>
        <button type="button" className="button" disabled={!title.trim() || saving} onClick={() => void save()}>
          Save
        </button>
      </div>
    </Dialog>
  )
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

  async function startTomorrow(reminder: Reminder) {
    const tomorrow = new Date(startOfDay(new Date()).getTime() + 36 * 3_600_000)
    await applyPlan(uid, planQuickReschedule(reminder.id, tomorrow).plan)
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
              <Button variant="primary" icon="plus" onClick={() => navigate('/capture')}>
                Log an interaction
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
                      <Button variant="ghost" small onClick={() => void startTomorrow(reminder)}>
                        Tomorrow
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
        <ReminderSheet
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
