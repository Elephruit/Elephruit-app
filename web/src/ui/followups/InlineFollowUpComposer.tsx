import { useMemo, useRef, useState } from 'react'
import { applyPlan } from '../../data/applyPlan'
import {
  emptyFollowUpDraft,
  followUpNeedsTemporalGuard,
  validateFollowUpDraft,
  type FollowUpDraft,
} from '../../domain/followUpDraft'
import { planPersistFollowUp } from '../../domain/followUpPlan'
import type { Person } from '../../domain/person'
import { detectDeadlineFromText } from '../../domain/temporal'
import { useUID } from '../UserContext'
import { toLocalDateValue } from '../dateInput'
import { ParticipantPicker } from '../log/ParticipantPicker'
import { Button } from '../components/Button'
import { Icon } from '../components/Icon'
import { CategoryTagPicker } from './CategoryTagPicker'

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
}: {
  people: Person[]
  tagSuggestions: string[]
}) {
  const uid = useUID()
  const [active, setActive] = useState(false)
  const [draft, setDraft] = useState(() => emptyFollowUpDraft(USER_ZONE))
  const [openPanel, setOpenPanel] = useState<OpenPanel>(null)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [guardActive, setGuardActive] = useState(false)
  const [escapeArmed, setEscapeArmed] = useState(false)
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

  function reset(keepActive: boolean) {
    setDraft(emptyFollowUpDraft(USER_ZONE))
    setOpenPanel(null)
    setError(null)
    setGuardActive(false)
    setEscapeArmed(false)
    setActive(keepActive)
    if (keepActive) window.setTimeout(() => titleRef.current?.focus(), 0)
  }

  async function persist(current: FollowUpDraft, continueCreating: boolean) {
    if (saving) return false
    setSaving(true)
    setError(null)
    try {
      const now = new Date()
      await applyPlan(
        uid,
        planPersistFollowUp({ draft: current, existingID: null, people, now, timeZone: USER_ZONE }),
      )
      reset(continueCreating)
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

  function togglePanel(panel: Exclude<OpenPanel, null>) {
    setOpenPanel((current) => (current === panel ? null : panel))
    setEscapeArmed(false)
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

  function handleEscape() {
    if (openPanel) {
      setOpenPanel(null)
      titleRef.current?.focus()
      return
    }
    if (!hasDraftContent(draft) || escapeArmed) {
      reset(false)
      return
    }
    setEscapeArmed(true)
    setError('Press Escape again to discard this follow-up.')
  }

  function handleBlur(event: React.FocusEvent<HTMLDivElement>) {
    const next = event.relatedTarget
    if (next instanceof Node && event.currentTarget.contains(next)) return
    window.setTimeout(() => {
      if (composerRef.current?.contains(document.activeElement)) return
      if (!hasDraftContent(draft)) {
        reset(false)
      } else if (draft.title.trim()) {
        void save(false)
      } else {
        setError('Say what you need to do.')
      }
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

  return (
    <div
      ref={composerRef}
      className="inline-followup-composer"
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
            void save(!(event.metaKey || event.ctrlKey))
          }}
        />

        <div className="inline-followup-toolbar" aria-label="Follow-up details">
          <button
            type="button"
            className="inline-detail-button"
            aria-expanded={openPanel === 'people'}
            data-selected={draft.personIDs.size > 0 || undefined}
            onClick={() => togglePanel('people')}
          >
            <Icon name="people" size={16} />
            {draft.personIDs.size > 0 ? `${draft.personIDs.size} tagged` : 'People'}
          </button>
          <button
            type="button"
            className="inline-detail-button"
            aria-expanded={openPanel === 'date'}
            data-selected={Boolean(dueDate) || undefined}
            onClick={() => togglePanel('date')}
          >
            <Icon name="calendar" size={16} />
            {dueDate || 'Due date'}
          </button>
          <button
            type="button"
            className="inline-detail-button"
            aria-expanded={openPanel === 'categories'}
            data-selected={draft.categoryTags.size > 0 || undefined}
            onClick={() => togglePanel('categories')}
          >
            <Icon name="tag" size={16} />
            {draft.categoryTags.size > 0 ? `${draft.categoryTags.size} categories` : 'Categories'}
          </button>
          <span className="inline-followup-spacer" />
          <Button variant="quiet" small onClick={() => reset(false)}>
            Cancel
          </Button>
          <Button variant="primary" small loading={saving} disabled={!draft.title.trim()} onClick={() => void save(false)}>
            Add
          </Button>
        </div>

        {openPanel === 'people' && (
          <div className="inline-followup-panel">
            <ParticipantPicker
              people={people}
              pendingNew={[]}
              selectedIDs={draft.personIDs}
              allowCreate={false}
              placeholder="Tag people"
              ariaLabel="Tag people"
              onToggle={(id) => {
                const personIDs = new Set(draft.personIDs)
                if (personIDs.has(id)) personIDs.delete(id)
                else personIDs.add(id)
                set({ personIDs })
              }}
              onCreate={() => {}}
            />
          </div>
        )}

        {openPanel === 'date' && (
          <div className="inline-followup-panel inline-date-panel">
            <div className="inline-date-quick">
              <button type="button" className="chip" onClick={() => setDueDate(shiftedDate(0))}>
                Today
              </button>
              <button type="button" className="chip" onClick={() => setDueDate(shiftedDate(1))}>
                Tomorrow
              </button>
              <button type="button" className="chip" onClick={() => setDueDate(nextMonday())}>
                Next Monday
              </button>
            </div>
            <input
              type="date"
              className="field inline-date-input"
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
        )}

        {openPanel === 'categories' && (
          <div className="inline-followup-panel">
            <CategoryTagPicker
              selected={draft.categoryTags}
              suggestions={tagSuggestions}
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
                Add without a date
              </button>
            </span>
          </div>
        )}

        {error && !guardActive && (
          <p className="inline-followup-error" role="alert">
            {error}
          </p>
        )}
        <p className="inline-followup-hint">Enter adds another · ⌘Enter finishes · Escape cancels</p>
      </div>
    </div>
  )
}
