/// The focused follow-up sheet: a right-anchored panel from 900px, a bottom
/// sheet below, built on Sheet. One question per section — what, for whom,
/// when — with mutually exclusive schedule modes and the temporal safeguard
/// on save. The same draft model as AI review; the underlying list stays
/// visible behind the standard backdrop.

import { useMemo, useRef, useState } from 'react'
import { applyPlan } from '../../data/applyPlan'
import { planDeleteReminder } from '../../domain/capture'
import type { Folder } from '../../domain/folder'
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
import { Button } from '../components/Button'
import { FormField } from '../components/FormField'
import { Sheet } from '../components/Sheet'
import { ParticipantPicker } from '../log/ParticipantPicker'
import { ScheduleEditor } from '../capture/editors/ScheduleEditor'
import { SegmentedControl } from '../components/SegmentedControl'
import { FolderPicker } from '../folders/FolderPicker'
import { CategoryTagPicker } from './CategoryTagPicker'

const USER_ZONE = Intl.DateTimeFormat().resolvedOptions().timeZone

export function FollowUpSheet({
  existing,
  people,
  folders = [],
  defaultFolderID = null,
  tagSuggestions = [],
  onClose,
}: {
  existing: Reminder | null
  people: Person[]
  folders?: Folder[]
  defaultFolderID?: string | null
  tagSuggestions?: string[]
  onClose: () => void
}) {
  const uid = useUID()
  const [draft, setDraft] = useState<FollowUpDraft>(() =>
    existing ? draftFromReminder(existing, USER_ZONE) : emptyFollowUpDraft(USER_ZONE, defaultFolderID),
  )
  const [notesOpen, setNotesOpen] = useState(draft.notes.length > 0)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [guardActive, setGuardActive] = useState(false)
  const [confirmingDelete, setConfirmingDelete] = useState(false)
  const guardRef = useRef<HTMLDivElement>(null)
  const titleRef = useRef<HTMLTextAreaElement>(null)

  const detected = useMemo(
    () => (guardActive ? detectDeadlineFromText(`${draft.title} ${draft.notes}`, { now: new Date(), timeZone: USER_ZONE }) : null),
    [guardActive, draft.title, draft.notes],
  )

  function set(changes: Partial<FollowUpDraft>) {
    setDraft((current) => ({ ...current, ...changes }))
    setGuardActive(false)
  }

  async function persist(current: FollowUpDraft) {
    setSaving(true)
    setError(null)
    try {
      const now = new Date()
      await applyPlan(
        uid,
        planPersistFollowUp({ draft: current, existingID: existing?.id ?? null, people, now, timeZone: USER_ZONE }),
      )
      onClose()
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Could not save.')
      setSaving(false)
    }
  }

  async function save() {
    if (saving) return
    const problem = validateFollowUpDraft(draft)
    if (problem) {
      setError(problem)
      return
    }
    // The safeguard: explicit temporal language saved with No date needs an
    // explicit choice, not silence. First attempt blocks and focuses.
    if (followUpNeedsTemporalGuard(draft)) {
      setGuardActive(true)
      window.setTimeout(() => guardRef.current?.focus(), 50)
      return
    }
    await persist(draft)
  }

  async function remove() {
    if (!existing || saving) return
    setSaving(true)
    try {
      await applyPlan(uid, planDeleteReminder(existing.id).plan)
      onClose()
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Could not delete.')
      setSaving(false)
    }
  }

  return (
    <Sheet
      title={existing ? 'Edit follow-up' : 'New follow-up'}
      width={440}
      onClose={onClose}
      footer={
        confirmingDelete ? (
          <>
            <span className="sheet-confirm-text" role="alert">
              Delete this follow-up? It cannot be undone.
            </span>
            <Button variant="quiet" onClick={() => setConfirmingDelete(false)}>
              Keep it
            </Button>
            <Button variant="destructive" loading={saving} onClick={() => void remove()}>
              Delete
            </Button>
          </>
        ) : (
          <>
            {existing && (
              <button
                type="button"
                className="button button-destructive"
                style={{ marginRight: 'auto' }}
                onClick={() => setConfirmingDelete(true)}
              >
                Delete follow-up
              </button>
            )}
            <Button variant="quiet" onClick={onClose}>
              Cancel
            </Button>
            <Button variant="primary" loading={saving} disabled={!draft.title.trim()} onClick={() => void save()}>
              Save follow-up
            </Button>
          </>
        )
      }
    >
      <FormField label={draft.responsibility === 'mine' ? 'What is your next move?' : 'What are you waiting on?'} htmlFor="followup-title">
        <textarea
          id="followup-title"
          ref={titleRef}
          className="field followup-title"
          rows={2}
          value={draft.title}
          onChange={(event) => set({ title: event.target.value })}
          autoFocus={!existing}
        />
      </FormField>

      <FormField label="Ownership" help="Keep your commitments separate from work you delegated or requested.">
        <SegmentedControl
          label="Follow-up ownership"
          options={[
            { value: 'mine', label: 'My next move' },
            { value: 'theirs', label: 'Waiting on them' },
          ]}
          value={draft.responsibility}
          onChange={(responsibility) => set({ responsibility })}
        />
      </FormField>

      <FormField label="For">
        <ParticipantPicker
          people={people}
          pendingNew={[]}
          selectedIDs={draft.personIDs}
          allowCreate={false}
          onToggle={(id) =>
            set({
              personIDs: (() => {
                const next = new Set(draft.personIDs)
                if (next.has(id)) next.delete(id)
                else next.add(id)
                return next
              })(),
            })
          }
          onCreate={() => {}}
        />
      </FormField>

      {draft.responsibility === 'theirs' && (
        <FormField label="Current status" htmlFor="followup-progress">
          <select id="followup-progress" className="field field-select" value={draft.progress} onChange={(event) => set({ progress: event.target.value as FollowUpDraft['progress'] })}>
            <option value="notStarted">Not started</option>
            <option value="inProgress">In progress</option>
            <option value="blocked">Blocked</option>
          </select>
        </FormField>
      )}

      {folders.length > 0 && (
        <FormField label="In" help="A folder, when it belongs to one.">
          <FolderPicker
            folders={folders}
            value={draft.folderID}
            onChange={(folderID) => set({ folderID })}
            label="Folder"
            emptyLabel="Nothing — just a follow-up"
          />
        </FormField>
      )}

      <ScheduleEditor value={draft.schedule} userZone={USER_ZONE} onChange={(schedule) => set({ schedule })} />

      <FormField label="Tags">
        <CategoryTagPicker
          selected={draft.categoryTags}
          suggestions={tagSuggestions}
          onChange={(categoryTags) => set({ categoryTags })}
        />
      </FormField>

      {guardActive && (
        <div className="draft-problem" role="alert" tabIndex={-1} ref={guardRef}>
          <p>
            {detected
              ? `The title mentions ${detected.label}, but this follow-up has no deadline.`
              : 'This sounds scheduled, but no date was captured.'}
          </p>
          <span className="draft-problem-actions">
            {detected && (
              <button
                type="button"
                className="button button-secondary button-small"
                onClick={() => {
                  set({
                    schedule: {
                      scheduleMode: 'deadline',
                      localDate: detected.localDate,
                      localTime: detected.localTime ?? '',
                      timeZone: detected.timeZone ?? USER_ZONE,
                    },
                  })
                }}
              >
                Use {detected.label}
              </button>
            )}
            <button
              type="button"
              className="button button-quiet button-small"
              onClick={() => void persist(draft)}
            >
              Save without a date
            </button>
          </span>
        </div>
      )}

      {notesOpen ? (
        <FormField label="Notes" htmlFor="followup-notes">
          <textarea
            id="followup-notes"
            className="field"
            rows={3}
            value={draft.notes}
            onChange={(event) => set({ notes: event.target.value })}
          />
        </FormField>
      ) : (
        <button type="button" className="button button-plain" onClick={() => setNotesOpen(true)}>
          Add notes
        </button>
      )}

      {error && (
        <p className="field-error" role="alert">
          {error}
        </p>
      )}
    </Sheet>
  )
}
