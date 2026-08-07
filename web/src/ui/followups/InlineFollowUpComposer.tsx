import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
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
import { newID } from '../../domain/ids'
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
import { FollowUpDatePicker } from './FollowUpDatePicker'

const USER_ZONE = Intl.DateTimeFormat().resolvedOptions().timeZone

type OpenPanel = 'checklist' | 'people' | 'date' | 'categories' | null

function shiftedDate(days: number): string {
  const date = new Date()
  date.setDate(date.getDate() + days)
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
    return formatDueDate(draft.schedule.localDate)
  }
  if (draft.schedule.scheduleMode === 'deadline') return formatDueDate(draft.schedule.localDate)
  return 'Due date'
}

function hasDraftContent(draft: FollowUpDraft): boolean {
  return (
    draft.title.trim().length > 0 ||
    draft.notes.trim().length > 0 ||
    draft.checklist.some((item) => item.title.trim().length > 0) ||
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
  hideTrigger = false,
  onClose,
}: {
  people: Person[]
  tagSuggestions: string[]
  existing?: Reminder | null
  activationRequest?: number
  hideTrigger?: boolean
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
  const notesRef = useRef<HTMLTextAreaElement>(null)
  const checklistButtonRef = useRef<HTMLButtonElement>(null)
  const peopleButtonRef = useRef<HTMLButtonElement>(null)
  const dateButtonRef = useRef<HTMLButtonElement>(null)
  const categoryButtonRef = useRef<HTMLButtonElement>(null)
  const deleteButtonRef = useRef<HTMLButtonElement>(null)
  const cancelButtonRef = useRef<HTMLButtonElement>(null)
  const saveButtonRef = useRef<HTMLButtonElement>(null)
  const guardRef = useRef<HTMLDivElement>(null)
  const checklistItemRefs = useRef(new Map<string, HTMLInputElement>())
  const suppressBlurRef = useRef(false)

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

  useLayoutEffect(() => {
    if (existing || activationRequest === 0) return
    suppressBlurRef.current = true
    setActive(true)
    setOpenPanel(null)
    window.setTimeout(() => {
      composerRef.current?.scrollIntoView({ behavior: 'smooth', block: 'center' })
      titleRef.current?.focus()
      window.setTimeout(() => {
        suppressBlurRef.current = false
      }, 0)
    }, 0)
  }, [activationRequest, existing])

  useLayoutEffect(() => {
    const field = notesRef.current
    if (!field) return
    field.style.height = '0px'
    const height = Math.min(field.scrollHeight, 96)
    field.style.height = `${Math.max(height, 24)}px`
    field.style.overflowY = field.scrollHeight > 96 ? 'auto' : 'hidden'
  }, [active, draft.notes])

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

  function focusChecklistItem(id: string) {
    window.setTimeout(() => {
      const input = checklistItemRefs.current.get(id)
      input?.focus()
      input?.setSelectionRange(input.value.length, input.value.length)
    }, 0)
  }

  function addChecklistItem(title: string, afterID?: string) {
    const item = { id: newID(), title, isCompleted: false }
    const checklist = [...draft.checklist]
    const afterIndex = afterID ? checklist.findIndex((candidate) => candidate.id === afterID) : -1
    if (afterIndex >= 0) checklist.splice(afterIndex + 1, 0, item)
    else checklist.push(item)
    set({ checklist })
    setOpenPanel(null)
    focusChecklistItem(item.id)
  }

  function updateChecklistItem(id: string, changes: { title?: string; isCompleted?: boolean }) {
    set({
      checklist: draft.checklist.map((item) => (item.id === id ? { ...item, ...changes } : item)),
    })
  }

  function removeChecklistItem(id: string) {
    set({ checklist: draft.checklist.filter((item) => item.id !== id) })
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
    if (next instanceof Element && next.closest('[data-followup-create]')) return
    window.setTimeout(() => {
      if (suppressBlurRef.current) {
        suppressBlurRef.current = false
        return
      }
      if (composerRef.current?.contains(document.activeElement)) return
      if (!hasDraftContent(draft)) close()
      else if (draft.title.trim()) void save(false)
      else setError('Say what you need to do.')
    }, 0)
  }

  function moveOnTab(
    event: React.KeyboardEvent<HTMLElement>,
    backward: React.RefObject<HTMLElement | null>,
    forward: React.RefObject<HTMLElement | null>,
  ) {
    if (event.key !== 'Tab') return
    event.preventDefault()
    const target = event.shiftKey ? backward.current : forward.current
    target?.focus()
  }

  function closeDatePanelAndFocus(target: React.RefObject<HTMLElement | null>) {
    setOpenPanel(null)
    window.setTimeout(() => target.current?.focus(), 0)
  }

  function openPanelFromTab(panel: Exclude<OpenPanel, null>) {
    setOpenPanel(panel)
    setEscapeArmed(false)
    setConfirmingDelete(false)
  }

  if (!active) {
    if (hideTrigger) return null
    return (
      <button type="button" className="inline-followup-trigger" onClick={activate}>
        <span className="inline-followup-plus" aria-hidden="true">
          <Icon name="plus" size={17} />
        </span>
        <span>Add a follow-up</span>
      </button>
    )
  }

  const dueDate =
    draft.schedule.scheduleMode === 'deadline' || draft.schedule.scheduleMode === 'start'
      ? draft.schedule.localDate
      : ''

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
            if (event.key === 'Tab' && !event.shiftKey) {
              event.preventDefault()
              notesRef.current?.focus()
              return
            }
            if (event.key !== 'Enter' || event.nativeEvent.isComposing) return
            event.preventDefault()
            void save(existing ? false : !(event.metaKey || event.ctrlKey))
          }}
        />

        <div className="inline-followup-notes-area">
          <textarea
            ref={notesRef}
            className="inline-followup-notes"
            rows={1}
            value={draft.notes}
            placeholder="Notes"
            aria-label="Notes"
            disabled={saving}
            onChange={(event) => set({ notes: event.target.value })}
            onKeyDown={(event) => {
              if (event.key !== 'Tab') return
              event.preventDefault()
              if (event.shiftKey) titleRef.current?.focus()
              else openPanelFromTab('checklist')
            }}
          />

          {draft.checklist.length > 0 && (
            <div className="inline-followup-checklist" aria-label="Checklist">
              {draft.checklist.map((item, index) => (
                <div className="inline-checklist-row" data-completed={item.isCompleted || undefined} key={item.id}>
                  <button
                    type="button"
                    className="inline-checklist-toggle"
                    aria-label={`${item.isCompleted ? 'Mark incomplete' : 'Complete'} ${item.title || `item ${index + 1}`}`}
                    aria-pressed={item.isCompleted}
                    tabIndex={-1}
                    onClick={() => updateChecklistItem(item.id, { isCompleted: !item.isCompleted })}
                  >
                    {item.isCompleted && <Icon name="check" size={12} />}
                  </button>
                  <input
                    ref={(element) => {
                      if (element) checklistItemRefs.current.set(item.id, element)
                      else checklistItemRefs.current.delete(item.id)
                    }}
                    value={item.title}
                    aria-label={`Checklist item ${index + 1}`}
                    placeholder="Checklist item"
                    disabled={saving}
                    onChange={(event) => updateChecklistItem(item.id, { title: event.target.value })}
                    onBlur={() => {
                      if (!item.title.trim()) removeChecklistItem(item.id)
                    }}
                    onKeyDown={(event) => {
                      if (event.key === 'Enter' && !event.nativeEvent.isComposing) {
                        event.preventDefault()
                        if (item.title.trim()) addChecklistItem('', item.id)
                        return
                      }
                      if (event.key !== 'Tab') return
                      event.preventDefault()
                      if (!item.title.trim()) removeChecklistItem(item.id)
                      if (event.shiftKey) notesRef.current?.focus()
                      else openPanelFromTab('people')
                    }}
                  />
                  <button
                    type="button"
                    className="inline-checklist-remove"
                    aria-label={`Remove ${item.title || `item ${index + 1}`}`}
                    tabIndex={-1}
                    onClick={() => removeChecklistItem(item.id)}
                  >
                    <Icon name="x" size={13} />
                  </button>
                </div>
              ))}
            </div>
          )}
        </div>

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
            ref={checklistButtonRef}
            type="button"
            className="inline-detail-button"
            aria-expanded={openPanel === 'checklist'}
            data-selected={draft.checklist.some((item) => item.title.trim()) || undefined}
            onMouseDown={(event) => event.preventDefault()}
            onFocus={() => openPanelFromTab('checklist')}
            onClick={() => openPanelFromTab('checklist')}
            onKeyDown={(event) => {
              if (event.key !== 'Tab') return
              event.preventDefault()
              if (event.shiftKey) notesRef.current?.focus()
              else openPanelFromTab('people')
            }}
          >
            <Icon name="check-circle" size={16} />
            Checklist
          </button>
          <button
            ref={peopleButtonRef}
            type="button"
            className="inline-detail-button"
            aria-expanded={openPanel === 'people'}
            data-selected={draft.personIDs.size > 0 || undefined}
            onMouseDown={(event) => event.preventDefault()}
            onFocus={() => openPanelFromTab('people')}
            onClick={() => openPanelFromTab('people')}
            onKeyDown={(event) => {
              if (event.key !== 'Tab') return
              event.preventDefault()
              if (event.shiftKey) openPanelFromTab('checklist')
              else openPanelFromTab('date')
            }}
          >
            <Icon name="people" size={16} />
            People
          </button>
          <button
            ref={dateButtonRef}
            type="button"
            className="inline-detail-button"
            aria-expanded={openPanel === 'date'}
            data-selected={draft.schedule.scheduleMode !== 'none' || undefined}
            onMouseDown={(event) => event.preventDefault()}
            onFocus={() => openPanelFromTab('date')}
            onClick={() => openPanelFromTab('date')}
            onKeyDown={(event) => {
              if (event.key !== 'Tab') return
              event.preventDefault()
              openPanelFromTab(event.shiftKey ? 'people' : 'categories')
            }}
          >
            <Icon name="calendar" size={16} />
            {formatScheduleButton(draft)}
          </button>
          <button
            ref={categoryButtonRef}
            type="button"
            className="inline-detail-button"
            aria-expanded={openPanel === 'categories'}
            data-selected={draft.categoryTags.size > 0 || undefined}
            onMouseDown={(event) => event.preventDefault()}
            onFocus={() => openPanelFromTab('categories')}
            onClick={() => openPanelFromTab('categories')}
            onKeyDown={(event) => {
              if (event.key !== 'Tab') return
              event.preventDefault()
              if (event.shiftKey) openPanelFromTab('date')
              else (existing ? deleteButtonRef : cancelButtonRef).current?.focus()
            }}
          >
            <Icon name="tag" size={16} />
            Categories
          </button>
          {existing && !confirmingDelete && (
            <button
              ref={deleteButtonRef}
              type="button"
              className="inline-delete-button"
              onClick={() => setConfirmingDelete(true)}
              onKeyDown={(event) => moveOnTab(event, categoryButtonRef, cancelButtonRef)}
            >
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
              <Button
                buttonRef={cancelButtonRef}
                variant="quiet"
                small
                onClick={close}
                onKeyDown={(event) =>
                  moveOnTab(event, existing ? deleteButtonRef : categoryButtonRef, saveButtonRef)
                }
              >
                Cancel
              </Button>
              <Button
                buttonRef={saveButtonRef}
                variant="primary"
                small
                loading={saving}
                disabled={!draft.title.trim()}
                onClick={() => void save(false)}
                onKeyDown={(event) => moveOnTab(event, cancelButtonRef, titleRef)}
              >
                {existing ? 'Save' : 'Add'}
              </Button>
            </>
          )}
        </div>

        {openPanel === 'checklist' && (
          <div className="inline-followup-panel inline-checklist-panel">
            <input
              className="inline-checklist-add"
              aria-label="Add a checklist item"
              placeholder="Add a checklist item"
              autoFocus
              onChange={(event) => {
                if (event.target.value) addChecklistItem(event.target.value)
              }}
              onKeyDown={(event) => {
                if (event.key !== 'Tab') return
                event.preventDefault()
                if (event.shiftKey) notesRef.current?.focus()
                else openPanelFromTab('people')
              }}
            />
          </div>
        )}

        {openPanel === 'people' && (
          <div className="inline-followup-panel inline-people-panel">
            <ParticipantPicker
              people={people}
              pendingNew={[]}
              selectedIDs={draft.personIDs}
              allowCreate={false}
              placeholder="Search people"
              ariaLabel="Tag people"
              autoFocus
              showSelected={false}
              onTabBackward={() => {
                openPanelFromTab('checklist')
              }}
              onTabForward={() => openPanelFromTab('date')}
              onToggle={togglePerson}
              onCreate={() => {}}
            />
          </div>
        )}

        {openPanel === 'date' && (
          <div className="inline-followup-panel inline-date-panel">
            <FollowUpDatePicker
              value={dueDate}
              autoFocus
              onSelect={(localDate) => {
                setDueDate(localDate)
                closeDatePanelAndFocus(dateButtonRef)
              }}
              onClear={() => {
                setDueDate('')
                closeDatePanelAndFocus(dateButtonRef)
              }}
              onExitBackward={() => openPanelFromTab('people')}
              onExitForward={() => openPanelFromTab('categories')}
            />
          </div>
        )}

        {openPanel === 'categories' && (
          <div className="inline-followup-panel inline-category-panel">
            <CategoryTagPicker
              selected={draft.categoryTags}
              suggestions={tagSuggestions}
              autoFocus
              showSelected={false}
              onTabBackward={() => openPanelFromTab('date')}
              onTabForward={() => {
                setOpenPanel(null)
                window.setTimeout(
                  () => (existing ? deleteButtonRef : cancelButtonRef).current?.focus(),
                  0,
                )
              }}
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
      </div>
    </div>
  )
}
