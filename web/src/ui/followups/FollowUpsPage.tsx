import { useMemo, useState } from 'react'
import { useNavigate } from 'react-router-dom'
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
import { Sheet } from '../components/Sheet'
import { fromLocalInputValue, toLocalDateValue } from '../dateInput'
import { ParticipantPicker } from '../log/ParticipantPicker'

function atNoon(dateValue: string): Date {
  return fromLocalInputValue(`${dateValue}T12:00`)
}

function dateChip(reminder: Reminder, now: Date): { text: string; color?: string } | null {
  const bucket = bucketFor(reminder, now)
  if (reminder.dueAt) {
    const phrase = `due ${relativeDescription(reminder.dueAt, now)}`
    if (bucket === 'overdue') return { text: phrase, color: 'var(--color-overdue)' }
    if (bucket === 'today') return { text: 'due today', color: 'var(--color-due-today)' }
    return { text: phrase }
  }
  if (reminder.startAt) return { text: `starts ${relativeDescription(reminder.startAt, now)}` }
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
    <Sheet title={existing ? 'Edit follow-up' : 'New follow-up'} onClose={onClose}>
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
    </Sheet>
  )
}

export function FollowUpsPage() {
  const uid = useUID()
  const navigate = useNavigate()
  const reminders = useReminders(uid)
  const people = usePeople(uid)
  const [showCompleted, setShowCompleted] = useState(false)
  const [editing, setEditing] = useState<Reminder | null>(null)
  const [creating, setCreating] = useState(false)

  const now = new Date()
  const groups = useMemo(() => (reminders ? sections(reminders, now) : undefined), [reminders]) // eslint-disable-line react-hooks/exhaustive-deps
  const done = useMemo(() => (reminders ? completedList(reminders) : []), [reminders])
  const peopleByID = useMemo(() => new Map((people ?? []).map((p) => [p.id, p])), [people])

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
    <main className="page">
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <h1 className="page-title" style={{ marginBottom: 0 }}>
          Follow-ups
        </h1>
        <span>
          <button type="button" className="button button-plain" onClick={() => setShowCompleted((s) => !s)}>
            {showCompleted ? 'Hide completed' : 'Completed'}
          </button>
          <button type="button" className="button button-plain" onClick={() => setCreating(true)}>
            New
          </button>
        </span>
      </div>

      {groups && groups.length === 0 && !showCompleted && (
        <EmptyState
          icon="bell"
          headline="Nothing owed"
          message="Follow-ups from logged interactions gather here, bucketed by what their dates actually say."
        />
      )}

      {groups?.map((group) => (
        <section key={group.bucket}>
          <h2
            className="section-header"
            style={group.bucket === 'overdue' ? { color: 'var(--color-overdue)' } : undefined}
          >
            {BUCKET_TITLES[group.bucket]}
          </h2>
          {group.reminders.map((reminder) => {
            const chip = dateChip(reminder, now)
            return (
              <div key={reminder.id} className="row" style={{ cursor: 'default' }}>
                <button
                  type="button"
                  className="button button-plain"
                  style={{ padding: 0, color: 'var(--color-due-today)' }}
                  aria-label={`Complete ${reminder.title}`}
                  onClick={() => void complete(reminder)}
                >
                  <Icon name="circle" size={20} />
                </button>
                <button
                  type="button"
                  style={{ background: 'none', border: 0, padding: 0, textAlign: 'left', cursor: 'pointer', minWidth: 0, flex: 1 }}
                  onClick={() => setEditing(reminder)}
                >
                  <span className="row-title" style={{ display: 'block' }}>
                    {reminder.title}
                  </span>
                  <span className="row-subtitle" style={{ display: 'flex', gap: 'var(--space-small)', flexWrap: 'wrap' }}>
                    {chip && <span style={{ color: chip.color }}>{chip.text}</span>}
                    {reminder.personIDs.map((id) => {
                      const person = peopleByID.get(id)
                      if (!person) return null
                      return (
                        <span
                          key={id}
                          role="link"
                          tabIndex={0}
                          style={{ textDecoration: 'underline', cursor: 'pointer' }}
                          onClick={(event) => {
                            event.stopPropagation()
                            navigate(`/people/${id}`)
                          }}
                          onKeyDown={(event) => event.key === 'Enter' && navigate(`/people/${id}`)}
                        >
                          {person.displayName}
                        </span>
                      )
                    })}
                  </span>
                </button>
                <span className="row-trailing">
                  <button
                    type="button"
                    className="button button-plain"
                    style={{ padding: '2px 6px' }}
                    onClick={() => void startTomorrow(reminder)}
                  >
                    Tomorrow
                  </button>
                </span>
              </div>
            )
          })}
        </section>
      ))}

      {showCompleted && (
        <section>
          <h2 className="section-header">Completed</h2>
          {done.length === 0 && <p className="row-subtitle">Nothing completed yet.</p>}
          {done.map((reminder) => (
            <div key={reminder.id} className="row" style={{ cursor: 'default', opacity: 0.65 }}>
              <button
                type="button"
                className="button button-plain"
                style={{ padding: 0, color: 'var(--color-completed)' }}
                aria-label={`Reopen ${reminder.title}`}
                onClick={() => void reopen(reminder)}
              >
                <Icon name="check-circle" size={20} />
              </button>
              <span className="row-title">{reminder.title}</span>
            </div>
          ))}
        </section>
      )}

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
    </main>
  )
}
