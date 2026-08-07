import { useEffect, useMemo, useRef, useState } from 'react'
import { applyPlan } from '../../data/applyPlan'
import { planDeleteReminder } from '../../domain/capture'
import {
  draftFromReminder,
  emptyFollowUpDraft,
  followUpNeedsTemporalGuard,
  validateFollowUpDraft,
  type FollowUpDraft,
} from '../../domain/followUpDraft'
import { planPersistFollowUp } from '../../domain/followUpPlan'
import type { Person } from '../../domain/person'
import type { Reminder } from '../../domain/reminders'
import { detectDeadlineFromText } from '../../domain/temporal'
import { useUID } from '../UserContext'
import { toLocalDateValue } from '../dateInput'
import { ParticipantPicker } from '../log/ParticipantPicker'
import { Avatar } from '../components/Avatar'
import { Button } from '../components/Button'
import { Icon } from '../components/Icon'
import { CategoryTagPicker } from './CategoryTagPicker'
import { categoryTintStyle } from './categoryStyle'

const USER_ZONE = Intl.DateTimeFormat().resolvedOptions().timeZone

type OpenPanel = 'people' | 'date' | 'categories' | null

function shiftedDate(days: number): string {
  const date = new Date()
  date.setDate(date.getDate() + days)
  return toLocalDateValue(date)
}

function nextMonday(): string {
  const date = new Date()
  date.setDate(date.getDate() + ((8 - date.getDay()) % 7 || 7))
  return toLocalDateValue(date)
}

function calendarLabel(localDate: string, includeWeekday = true): string {
  return new Intl.DateTimeFormat(undefined, {
    weekday: includeWeekday ? 'short' : undefined,
    month: 'short',
    day: 'numeric',
  }).format(new Date(`${localDate}T12:00:00`))
}

function formatDueDate(localDate: string): string {
  if (!localDate) return 'Due date'
  if (localDate === shiftedDate(0)) return 'Today'
  if (localDate === shiftedDate(1)) return 'Tomorrow'
  return calendarLabel(localDate)
}

function formatScheduleButton(draft: FollowUpDraft): string {
  if (draft.schedule.scheduleMode === 'someday') return 'Someday'
  if (draft.schedule.scheduleMode === 'start' && draft.schedule.localDate) {
    return `Starts ${formatDueDate(draft.schedule.localDate)}`
  }
  if (draft.schedule.scheduleMode === 'deadline') return formatDueDate(draft.schedule.localDate)
  return 'Due date'
}

function hasDraftContent(draft: FollowUpDraft): boolean {
  return (
    draft.title.trim().length > 0 ||
    draft.notes.trim().length > 0 ||
    draft.personIDs.size > 0 ||
    draft.categoryTags.size > 0 ||
    draft.schedule.scheduleMode !== 'none'
  )
}

export function InlineFollowUpComposer({
  people,
  tagSuggestions,
  existing = null,
  activationRequest = 0,
  onClose,
}: {
  people: Person[]
  tagSuggestions: string[]
  existing?: Reminder | null
  activationRequest?: number
  onClose?: () => void
}) {
  const uid = useUID()
  const existingID = existing?.id ?? null
  const [active, setActive] = useState(Boolean(existing))
  const [draft, setDraft] = useState(() =>
    existing ? draftFromReminder(existing, USER_ZONE) : emptyFollowUpDraft(USER_ZONE),
  )
  const [openPanel, setOpenPanel] = useState<OpenPanel>(null)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [guardActive, setGuardActive] = useState(false)
  const [escapeArmed, setEscapeArmed] = useState(false)
  const [confirmingDelete, setConfirmingDelete] = useState(false)
  const composerRef = useRef<HTMLDivElement>(null)
  const titleRef = useRef<HTMLInputElement>(null)
  const guardRef = useRef<HTMLDivElement>(null)

  const detected = useMemo(
    () =>
      guardActive
        ? detectDeadlineFromText(`${draft.title} ${draft.notes}`, { now: new Date(), timeZone: USER_ZONE })
        : null,
    [draft.notes, draft.title, guardActive],
  )
  const peopleByID = useMemo(() => new Map(people.map((person) => [person.id, person])), [people])

  useEffect(() => {
    if (!existingID) return
    window.setTimeout(() => titleRef.current?.focus(), 0)
  }, [existingID])

  useEffect(() => {
    if (existing || activationRequest === 0) return
    setActive(true)
    window.setTimeout(() => {
      composerRef.current?.scrollIntoView({ behavior: 'smooth', block: 'center' })
      titleRef.current?.focus()
    }, 0)
  }, [activationRequest, existing])

  function set(changes: Partial<FollowUpDraft>) {
    setDraft((current) => ({ ...current, ...changes }))
    setError(null)
    setGuardActive(false)
    setEscapeArmed(false)
  }

  function activate() {
    setActive(true)
    window.setTimeout(() => titleRef.current?.focus(), 0)
  }

  function close() {
    setOpenPanel(null)
    setError(null)
    setGuardActive(false)
    setEscapeArmed(false)
    setConfirmingDelete(false)
    if (existing) {
      onClose?.()
      return
    }
    setDraft(emptyFollowUpDraft(USER_ZONE))
    setActive(false)
  }

  function resetForAnother() {
    setDraft(emptyFollowUpDraft(USER_ZONE))
    setOpenPanel(null)
    setError(null)
    setGuardActive(false)
    setEscapeArmed(false)
    setConfirmingDelete(false)
    setActive(true)
    window.setTimeout(() => titleRef.current?.focus(), 0)
  }

  async function persist(current: FollowUpDraft, continueCreating: boolean) {
    if (saving) return false
    setSaving(true)
    setError(null)
    try {
      const now = new Date()
      await applyPlan(
        uid,
        planPersistFollowUp({
          draft: current,
          existingID,
          people,
          now,
          timeZone: USER_ZONE,
        }),
      )
      if (existing) onClose?.()
      else if (continueCreating) resetForAnother()
      else close()
      return true
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Could not save this follow-up.')
      return false
    } finally {
      setSaving(false)
    }
  }

  async function save(continueCreating: boolean) {
    if (saving) return false
    const problem = validateFollowUpDraft(draft)
    if (problem) {
      setError(problem)
      titleRef.current?.focus()
      return false
    }
    if (followUpNeedsTemporalGuard(draft)) {
      setGuardActive(true)
      window.setTimeout(() => guardRef.current?.focus(), 0)
      return false
    }
    return persist(draft, continueCreating)
  }

  async function remove() {
    if (!existing || saving) return
    setSaving(true)
    setError(null)
    try {
      await applyPlan(uid, planDeleteReminder(existing.id).plan)
      onClose?.()
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Could not delete this follow-up.')
      setSaving(false)
    }
  }

  function togglePanel(panel: Exclude<OpenPanel, null>) {
    setOpenPanel((current) => (current === panel ? null : panel))
    setEscapeArmed(false)
    setConfirmingDelete(false)
  }

  function setDueDate(localDate: string) {
    set({
      schedule: {
        scheduleMode: localDate ? 'deadline' : 'none',
        localDate,
        localTime: '',
        timeZone: USER_ZONE,
      },
    })
  }

  function togglePerson(id: string) {
    const personIDs = new Set(draft.personIDs)
    if (personIDs.has(id)) personIDs.delete(id)
    else personIDs.add(id)
    set({ personIDs })
  }

  function removeCategory(tag: string) {
    const categoryTags = new Set(draft.categoryTags)
    categoryTags.delete(tag)
    set({ categoryTags })
  }

  function handleEscape() {
    if (openPanel) {
      setOpenPanel(null)
      titleRef.current?.focus()
      return
    }
    if (!hasDraftContent(draft) || escapeArmed) {
      close()
      return
    }
    setEscapeArmed(true)
    setError(`Press Escape again to ${existing ? 'close without saving' : 'discard this follow-up'}.`)
  }

  function handleBlur(event: React.FocusEvent<HTMLDivElement>) {
    const next = event.relatedTarget
    if (next instanceof Node && event.currentTarget.contains(next)) return
    window.setTimeout(() => {
      if (composerRef.current?.contains(document.activeElement)) return
      if (!hasDraftContent(draft)) close()
      else if (draft.title.trim()) void save(false)
      else setError('Say what you need to do.')
    }, 0)
  }

  if (!active) {
    return (
      <button type="button" className="inline-followup-trigger" onClick={activate}>
        <span className="inline-followup-plus" aria-hidden="true">
          <Icon name="plus" size={17} />
        </span>
        <span>Add a follow-up</span>
      </button>
    )
  }

  const dueDate = draft.schedule.scheduleMode === 'deadline' ? draft.schedule.localDate : ''
  const quickDates = [
    { label: 'Today', value: shiftedDate(0) },
    { label: 'Tomorrow', value: shiftedDate(1) },
    { label: 'Next Monday', value: nextMonday() },
  ]

  return (
    <div
      ref={composerRef}
      className="inline-followup-composer"
      data-editing={existing ? true : undefined}
      onBlurCapture={handleBlur}
      onKeyDown={(event) => {
        if (event.key === 'Escape') handleEscape()
      }}
    >
      <span className="complete-ring inline-followup-ring" aria-hidden="true" />
      <div className="inline-followup-body">
        <input
          ref={titleRef}
          className="inline-followup-title"
          value={draft.title}
          placeholder="New follow-up"
          aria-label="Follow-up name"
          disabled={saving}
          onChange={(event) => set({ title: event.target.value })}
          onKeyDown={(event) => {
            if (event.key !== 'Enter' || event.nativeEvent.isComposing) return
            event.preventDefault()
            void save(existing ? false : !(event.metaKey || event.ctrlKey))
          }}
        />

        {(draft.personIDs.size > 0 || draft.categoryTags.size > 0) && (
          <div className="inline-followup-selections" aria-label="Selected details">
            {[...draft.personIDs].map((id) => {
              const person = peopleByID.get(id)
              if (!person) return null
              return (
                <button
                  key={id}
                  type="button"
                  className="inline-person-token"
                  aria-label={`Remove ${person.displayName}`}
                  onClick={() => togglePerson(id)}
                >
                  <Avatar name={person.displayName} colorName={person.colorName} small />
                  <span>{person.displayName}</span>
                  <Icon name="x" size={12} />
                </button>
              )
            })}
            {[...draft.categoryTags].map((tag) => (
              <button
                key={tag}
                type="button"
                className="category-token inline-category-token"
                style={categoryTintStyle(tag)}
                aria-label={`Remove ${tag}`}
                onClick={() => removeCategory(tag)}
              >
                <span className="category-option-dot" aria-hidden="true" />
                {tag}
                <Icon name="x" size={12} />
              </button>
            ))}
          </div>
        )}

        <div className="inline-followup-toolbar" aria-label="Follow-up details">
          <button
            type="button"
            className="inline-detail-button"
            aria-expanded={openPanel === 'people'}
            data-selected={draft.personIDs.size > 0 || undefined}
            onMouseDown={(event) => event.preventDefault()}
            onClick={() => togglePanel('people')}
          >
            <Icon name="people" size={16} />
            People
          </button>
          <button
            type="button"
            className="inline-detail-button"
            aria-expanded={openPanel === 'date'}
            data-selected={draft.schedule.scheduleMode !== 'none' || undefined}
            onMouseDown={(event) => event.preventDefault()}
            onClick={() => togglePanel('date')}
          >
            <Icon name="calendar" size={16} />
            {formatScheduleButton(draft)}
          </button>
          <button
            type="button"
            className="inline-detail-button"
            aria-expanded={openPanel === 'categories'}
            data-selected={draft.categoryTags.size > 0 || undefined}
            onMouseDown={(event) => event.preventDefault()}
            onClick={() => togglePanel('categories')}
          >
            <Icon name="tag" size={16} />
            Categories
          </button>
          {existing && !confirmingDelete && (
            <button type="button" className="inline-delete-button" onClick={() => setConfirmingDelete(true)}>
              Delete
            </button>
          )}
          <span className="inline-followup-spacer" />
          {confirmingDelete ? (
            <span className="inline-delete-confirm" role="alert">
              <span>Delete?</span>
              <Button variant="quiet" small onClick={() => setConfirmingDelete(false)}>
                Keep
              </Button>
              <Button variant="destructive" small loading={saving} onClick={() => void remove()}>
                Delete
              </Button>
            </span>
          ) : (
            <>
              <Button variant="quiet" small onClick={close}>
                Cancel
              </Button>
              <Button
                variant="primary"
                small
                loading={saving}
                disabled={!draft.title.trim()}
                onClick={() => void save(false)}
              >
                {existing ? 'Save' : 'Add'}
              </Button>
            </>
          )}
        </div>

        {openPanel === 'people' && (
          <div className="inline-followup-panel inline-people-panel">
            <div className="inline-panel-heading">
              <span className="inline-panel-icon"><Icon name="people" size={17} /></span>
              <span><strong>Tag people</strong><small>Who is this follow-up for?</small></span>
            </div>
            <ParticipantPicker
              people={people}
              pendingNew={[]}
              selectedIDs={draft.personIDs}
              allowCreate={false}
              placeholder="Search people"
              ariaLabel="Tag people"
              autoFocus
              showSelected={false}
              onToggle={togglePerson}
              onCreate={() => {}}
            />
          </div>
        )}

        {openPanel === 'date' && (
          <div className="inline-followup-panel inline-date-panel">
            <div className="inline-panel-heading">
              <span className="inline-panel-icon"><Icon name="calendar" size={17} /></span>
              <span><strong>{dueDate ? `Due ${formatDueDate(dueDate)}` : 'Choose a due date'}</strong><small>Only due dates can become overdue.</small></span>
            </div>
            <div className="inline-date-choices">
              {quickDates.map((choice) => (
                <button
                  key={choice.label}
                  type="button"
                  className="inline-date-choice"
                  aria-pressed={dueDate === choice.value}
                  onClick={() => setDueDate(choice.value)}
                >
                  <strong>{choice.label}</strong>
                  <span>{calendarLabel(choice.value)}</span>
                </button>
              ))}
            </div>
            <div className="inline-custom-date">
              <Icon name="calendar" size={16} />
              <label htmlFor={`followup-date-${existingID ?? 'new'}`}>Choose another date</label>
              <input
                id={`followup-date-${existingID ?? 'new'}`}
                type="date"
                aria-label="Due date"
                value={dueDate}
                onChange={(event) => setDueDate(event.target.value)}
              />
              {dueDate && (
                <button type="button" className="button button-plain button-small" onClick={() => setDueDate('')}>
                  Clear
                </button>
              )}
            </div>
          </div>
        )}

        {openPanel === 'categories' && (
          <div className="inline-followup-panel inline-category-panel">
            <div className="inline-panel-heading">
              <span className="inline-panel-icon"><Icon name="tag" size={17} /></span>
              <span><strong>Categories</strong><small>Group related follow-ups with color.</small></span>
            </div>
            <CategoryTagPicker
              selected={draft.categoryTags}
              suggestions={tagSuggestions}
              autoFocus
              showSelected={false}
              onChange={(categoryTags) => set({ categoryTags })}
            />
          </div>
        )}

        {guardActive && (
          <div className="draft-problem inline-followup-problem" role="alert" tabIndex={-1} ref={guardRef}>
            <p>
              {detected
                ? `The title mentions ${detected.label}, but this follow-up has no due date.`
                : 'This sounds scheduled, but no due date was captured.'}
            </p>
            <span className="draft-problem-actions">
              {detected && (
                <button
                  type="button"
                  className="button button-secondary button-small"
                  onClick={() => {
                    setDueDate(detected.localDate)
                    setOpenPanel('date')
                  }}
                >
                  Use {detected.label}
                </button>
              )}
              <button type="button" className="button button-quiet button-small" onClick={() => void persist(draft, false)}>
                {existing ? 'Save without a date' : 'Add without a date'}
              </button>
            </span>
          </div>
        )}

        {error && !guardActive && (
          <p className="inline-followup-error" role="alert">
            {error}
          </p>
        )}
        <p className="inline-followup-hint">
          {existing ? 'Enter saves · Escape closes' : 'Enter adds another · ⌘Enter finishes · Escape cancels'}
        </p>
      </div>
    </div>
  )
}
