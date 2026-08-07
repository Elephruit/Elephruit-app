/// The review as an editable draft. Every proposed item is an open row —
/// summary, visible Edit, Remove with Undo — grouped under Interaction, People
/// and facts, Relationships, and Follow-ups. No leading checkboxes: removal is
/// an action, editing is the point, and the write plan is built from the
/// edited draft at save time. Saving stays explicit and atomic.

import { useMemo, useReducer, useRef, useState } from 'react'
import { applyPlan } from '../../data/applyPlan'
import { useFolders, usePeople, useReminders } from '../../data/hooks'
import type { ResolvedCapture } from '../../domain/assist'
import { CONFIDENCE_LABELS, SENSITIVITY_LABELS, type FactConfidence, type FactSensitivity } from '../../domain/facts'
import { INTERACTION_KIND_LABELS } from '../../domain/interaction'
import { kindLabel, possessivePhrase } from '../../domain/relationships'
import {
  activeItems,
  draftFromResolved,
  draftItemSummary,
  planFromReviewDraft,
  reviewDraftReducer,
  slotByID,
  slotPerson,
  validateDraft,
  type PersonSlotEntry,
  type ResolvedCaptureDraft,
  type ReviewDraftItem,
} from '../../domain/reviewDraft'
import { formatScheduleSummary, resolveScheduleDraft } from '../../domain/temporal'
import { useUID } from '../UserContext'
import { useViewport } from '../breakpoints'
import { Button } from '../components/Button'
import { Icon } from '../components/Icon'
import { FormField } from '../components/FormField'
import { FactDraftEditor } from './editors/FactDraftEditor'
import { FollowUpDraftEditor } from './editors/FollowUpDraftEditor'
import { InteractionDraftEditor } from './editors/InteractionDraftEditor'
import { PersonContextDraftEditor } from './editors/PersonContextDraftEditor'
import { PersonSlotPicker } from './editors/PersonSlotPicker'
import { RelationshipDraftEditor } from './editors/RelationshipDraftEditor'

const USER_ZONE = Intl.DateTimeFormat().resolvedOptions().timeZone

function RowSummary({ draft, item }: { draft: ResolvedCaptureDraft; item: ReviewDraftItem }) {
  switch (item.type) {
    case 'interaction':
      return (
        <>
          <span className="draft-row-title">
            {INTERACTION_KIND_LABELS[item.kind]} — {item.summary || 'Untitled'}
          </span>
          <span className="draft-row-sub">
            with{' '}
            {item.participantSlotIDs
              .map((slotID) => slotPerson(draft, slotID)?.displayName ?? 'somebody')
              .join(', ') || 'nobody yet'}
          </span>
        </>
      )
    case 'fact': {
      const person = slotPerson(draft, item.subjectSlotID)
      return (
        <>
          <span className="draft-row-title">
            {item.attribute}: {item.value || '—'}
          </span>
          <span className="draft-row-sub">
            about {person?.displayName ?? 'somebody'}
            {item.confidence !== 'stated' && ` · ${CONFIDENCE_LABELS[item.confidence]}`}
          </span>
        </>
      )
    }
    case 'personContext': {
      const person = slotPerson(draft, item.subjectSlotID)
      const work = [item.roleTitle, item.organizationName].filter(Boolean).join(' at ')
      return <><span className="draft-row-title">{person?.displayName ?? 'Somebody'} · {item.profileFocus === 'professional' ? 'Professional' : 'Personal'} profile</span>{work && <span className="draft-row-sub">{work}</span>}</>
    }
    case 'relationship': {
      const subject = slotPerson(draft, item.subjectSlotID)
      const other = item.otherSlotID ? slotPerson(draft, item.otherSlotID) : null
      const word = item.label.trim() || kindLabel(item.kind)
      return (
        <>
          <span className="draft-row-title">
            {subject?.displayName ?? 'Somebody'} → {word} →{' '}
            {other?.displayName ??
              `“${possessivePhrase(subject?.displayName ?? 'their', item.kind, item.label.trim() || null)}” — unnamed`}
          </span>
          {item.facts.some((f) => f.value.trim()) && (
            <span className="draft-row-sub">
              {item.facts
                .filter((f) => f.value.trim())
                .map((f) => `${f.attribute}: ${f.value}`)
                .join(' · ')}
            </span>
          )}
        </>
      )
    }
    case 'followUp': {
      const schedule = formatScheduleSummary(resolveScheduleDraft(item.schedule, { timeZone: USER_ZONE }))
      const names = item.personSlotIDs
        .map((slotID) => slotPerson(draft, slotID)?.displayName)
        .filter(Boolean)
        .join(', ')
      return (
        <>
          <span className="draft-row-title">{item.responsibility === 'theirs' ? 'Waiting on: ' : ''}{item.title || 'Untitled follow-up'}</span>
          {(names || schedule) && (
            <span className="draft-row-sub">
              {names && `for ${names}`}
              {names && schedule && ' · '}
              {schedule}
            </span>
          )}
        </>
      )
    }
    case 'reminderChange':
      return <><span className="draft-row-title">{item.action === 'complete' ? 'Mark complete' : item.action === 'delete' ? 'Delete' : item.action === 'update' ? 'Update' : 'Reopen'} · {item.reminder.title}</span><span className="draft-row-sub">Existing follow-up{item.action === 'delete' ? ' · Cannot be undone after confirmation' : ''}</span></>
    case 'factChange':
      return <><span className="draft-row-title">{item.action === 'confirm' ? 'Confirm' : 'Correct'} · {item.observation.attribute}</span><span className="draft-row-sub">{item.observation.value}{item.action === 'correct' && item.value !== item.observation.value ? ` → ${item.value}` : ''}</span></>
    case 'relationshipChange':
      return <><span className="draft-row-title">Remove · {kindLabel(item.relationship.kind)}</span><span className="draft-row-sub">Existing relationship · Both sides will be removed after confirmation</span></>
  }
}

const SECTIONS: Array<{ title: string; types: Array<ReviewDraftItem['type']> }> = [
  { title: 'Interaction', types: ['interaction'] },
  { title: 'Person profile', types: ['personContext'] },
  { title: 'People and facts', types: ['fact'] },
  { title: 'Relationships', types: ['relationship'] },
  { title: 'Follow-ups', types: ['followUp'] },
  { title: 'Changes to existing follow-ups', types: ['reminderChange'] },
  { title: 'Changes to existing facts', types: ['factChange'] },
  { title: 'Changes to relationships', types: ['relationshipChange'] },
]

export function EditableReviewPanel({
  resolved,
  onClose,
  onSaved,
}: {
  resolved: ResolvedCapture
  onClose: () => void
  onSaved: () => void
}) {
  const uid = useUID()
  const people = usePeople(uid) ?? []
  const folders = useFolders(uid) ?? []
  const reminders = useReminders(uid)
  const tagSuggestions = useMemo(
    () => (reminders ?? []).flatMap((reminder) => reminder.categoryTags ?? []),
    [reminders],
  )
  const viewport = useViewport()
  const [draft, dispatch] = useReducer(reviewDraftReducer, resolved, (r) => draftFromResolved(r, new Date()))
  const [expanded, setExpanded] = useState<Set<string>>(new Set())
  const [saving, setSaving] = useState(false)
  const [saveError, setSaveError] = useState<string | null>(null)
  const [announcement, setAnnouncement] = useState('')
  const problemRefs = useRef(new Map<string, HTMLElement>())

  const problems = useMemo(() => validateDraft(draft), [draft])
  const problemsByItem = useMemo(() => {
    const map = new Map<string, typeof problems>()
    for (const problem of problems) {
      map.set(problem.itemID, [...(map.get(problem.itemID) ?? []), problem])
    }
    return map
  }, [problems])

  const active = activeItems(draft)
  const readyCount = active.filter((item) => !problemsByItem.has(item.id)).length
  const fieldProblems = problems.some((p) => p.kind === 'field')

  // Slots referenced by any active item, in first-use order — the people this
  // save touches, each offering the interactive new-badge resolution.
  const referencedSlots = useMemo(() => {
    const ids: string[] = []
    for (const item of active) {
      const refs =
        item.type === 'interaction'
          ? item.participantSlotIDs
          : item.type === 'personContext'
            ? [item.subjectSlotID, ...(item.introducedBySlotID ? [item.introducedBySlotID] : [])]
          : item.type === 'fact'
            ? [item.subjectSlotID]
              : item.type === 'relationship'
                ? [item.subjectSlotID, ...(item.otherSlotID ? [item.otherSlotID] : [])]
              : item.type === 'followUp'
                ? item.personSlotIDs
                : []
      for (const slotID of refs) if (!ids.includes(slotID)) ids.push(slotID)
    }
    return ids.map((slotID) => slotByID(draft, slotID)).filter((slot): slot is PersonSlotEntry => Boolean(slot))
  }, [active, draft])

  function toggleExpand(id: string) {
    setExpanded((current) => {
      const next = new Set(viewport === 'mobile' ? [] : current)
      if (current.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  function removeItem(item: ReviewDraftItem) {
    dispatch({ type: 'remove-item', id: item.id })
    setExpanded((current) => {
      const next = new Set(current)
      next.delete(item.id)
      return next
    })
    setAnnouncement(`Removed ${draftItemSummary(draft, item)}`)
  }

  async function save() {
    if (saving) return
    if (problems.length > 0) {
      // A blocked attempt focuses the first problem instead of failing silently.
      const first = problems[0]
      setExpanded((current) => new Set(viewport === 'mobile' ? [first.itemID] : [...current, first.itemID]))
      window.setTimeout(() => problemRefs.current.get(first.itemID)?.focus(), 50)
      return
    }
    const { plan } = planFromReviewDraft(draft, new Date(), { timeZone: USER_ZONE })
    if (plan.length === 0) return
    setSaving(true)
    setSaveError(null)
    try {
      await applyPlan(uid, plan)
      onSaved()
    } catch (cause) {
      setSaveError(cause instanceof Error ? cause.message : 'Could not save.')
      setSaving(false)
    }
  }

  return (
    <div className="editable-review">
      <p className="editable-review-subtitle">Edit anything that was misunderstood. Nothing is saved until you confirm.</p>

      <label className="field-label" htmlFor="memory-title">
        Update title
      </label>
      <input
        id="memory-title"
        className="field"
        value={draft.title}
        onChange={(event) => dispatch({ type: 'update-title', title: event.target.value })}
      />

      <p className="visually-hidden" aria-live="polite">
        {announcement}
      </p>

      {draft.warnings.map((warning) => (
        <p key={warning} className="draft-warning">
          {warning}
        </p>
      ))}

      {referencedSlots.some((slot) => slot.resolution.ref === 'create') && (
        <div className="draft-people">
          <h3 className="section-header">New people this will create</h3>
          {referencedSlots
            .filter((slot) => slot.resolution.ref === 'create')
            .map((slot) => (
              <div key={slot.slotID} className="draft-people-row">
                <PersonSlotPicker
                  slot={slot}
                  people={people}
                  onResolve={(resolution) => dispatch({ type: 'resolve-person', slotID: slot.slotID, resolution })}
                />
              </div>
            ))}
        </div>
      )}

      {active.length === 0 && draft.items.length === 0 && (
        <p className="row-subtitle">Nothing structured was found in that update.</p>
      )}

      {SECTIONS.map((section) => {
        const rows = draft.items.filter((item) => section.types.includes(item.type))
        if (rows.length === 0) return null
        return (
          <div key={section.title}>
            <h3 className="section-header">{section.title}</h3>
            {rows.map((item) => {
              const itemProblems = problemsByItem.get(item.id) ?? []
              if (item.removed) {
                return (
                  <div key={item.id} className="draft-row draft-row-removed" role="status">
                    <span className="draft-row-sub">Removed {draftItemSummary(draft, item)} · </span>
                    <button
                      type="button"
                      className="button button-plain"
                      onClick={() => dispatch({ type: 'restore-item', id: item.id })}
                    >
                      Undo
                    </button>
                  </div>
                )
              }
              const isExpanded = expanded.has(item.id)
              return (
                <div key={item.id} className="draft-row" data-expanded={isExpanded || undefined}>
                  <div className="draft-row-line">
                    <div className="draft-row-main">
                      <RowSummary draft={draft} item={item} />
                    </div>
                    <span className="draft-row-actions">
                      <button
                        type="button"
                        className="button button-plain"
                        aria-expanded={isExpanded}
                        aria-label={`Edit ${draftItemSummary(draft, item)}`}
                        onClick={() => toggleExpand(item.id)}
                      >
                        {isExpanded ? 'Done' : 'Edit'}
                      </button>
                      <button
                        type="button"
                        className="icon-button"
                        aria-label={`Remove ${draftItemSummary(draft, item)}`}
                        onClick={() => removeItem(item)}
                      >
                        <Icon name="x" size={14} />
                      </button>
                    </span>
                  </div>

                  {itemProblems.map((problem) => (
                    <div
                      key={problem.message}
                      className="draft-problem"
                      role="alert"
                      tabIndex={-1}
                      ref={(node) => {
                        if (node) problemRefs.current.set(item.id, node)
                      }}
                    >
                      <p>{problem.message}</p>
                      {problem.kind === 'temporal' && item.type === 'followUp' && (
                        <span className="draft-problem-actions">
                          <button
                            type="button"
                            className="button button-secondary button-small"
                            onClick={() => {
                              setExpanded((current) => new Set(viewport === 'mobile' ? [item.id] : [...current, item.id]))
                            }}
                          >
                            Add date
                          </button>
                          <button
                            type="button"
                            className="button button-quiet button-small"
                            onClick={() =>
                              dispatch({ type: 'update-follow-up', id: item.id, changes: { allowUnscheduled: true } })
                            }
                          >
                            Save without date
                          </button>
                        </span>
                      )}
                    </div>
                  ))}

                  {isExpanded && (
                    <div className="draft-row-editor">
                      {item.type === 'interaction' && (
                        <InteractionDraftEditor item={item} draft={draft} people={people} dispatch={dispatch} />
                      )}
                      {item.type === 'fact' && (
                        <FactDraftEditor item={item} draft={draft} people={people} dispatch={dispatch} />
                      )}
                      {item.type === 'personContext' && (
                        <PersonContextDraftEditor item={item} draft={draft} people={people} dispatch={dispatch} />
                      )}
                      {item.type === 'relationship' && (
                        <RelationshipDraftEditor item={item} draft={draft} people={people} dispatch={dispatch} />
                      )}
                      {item.type === 'followUp' && (
                        <FollowUpDraftEditor
                          item={item}
                          draft={draft}
                          people={people}
                          folders={folders}
                          tagSuggestions={tagSuggestions}
                          userZone={USER_ZONE}
                          dispatch={dispatch}
                        />
                      )}
                      {item.type === 'reminderChange' && (
                        <div className="draft-editor">
                          <FormField label="Change">
                            <select className="field field-select" value={item.action} onChange={(event) => dispatch({ type: 'update-reminder-change', id: item.id, changes: { action: event.target.value as 'complete' | 'reopen' | 'delete' | 'update' } })}>
                              <option value="complete">Mark complete</option>
                              <option value="reopen">Reopen</option>
                              <option value="delete">Delete permanently</option>
                              <option value="update">Update progress</option>
                            </select>
                          </FormField>
                          {item.action === 'update' && <><div className="draft-editor-pair"><FormField label="Owner"><select className="field field-select" value={item.responsibility} onChange={(event) => dispatch({ type: 'update-reminder-change', id: item.id, changes: { responsibility: event.target.value as typeof item.responsibility } })}><option value="mine">My next move</option><option value="theirs">Waiting on them</option></select></FormField><FormField label="Current status"><select className="field field-select" value={item.progress} onChange={(event) => dispatch({ type: 'update-reminder-change', id: item.id, changes: { progress: event.target.value as typeof item.progress } })}><option value="notStarted">Not started</option><option value="inProgress">In progress</option><option value="blocked">Blocked</option></select></FormField></div><FormField label="Latest update"><textarea className="field" rows={2} value={item.notes} onChange={(event) => dispatch({ type: 'update-reminder-change', id: item.id, changes: { notes: event.target.value } })} /></FormField></>}
                        </div>
                      )}
                      {item.type === 'factChange' && (
                        <div className="draft-editor">
                          <div className="draft-editor-pair">
                            <FormField label="Change"><select className="field field-select" value={item.action} onChange={(event) => dispatch({ type: 'update-fact-change', id: item.id, changes: { action: event.target.value as 'confirm' | 'correct' } })}><option value="confirm">Confirm it still holds</option><option value="correct">Correct it</option></select></FormField>
                            <FormField label="Confidence"><select className="field field-select" value={item.confidence} onChange={(event) => dispatch({ type: 'update-fact-change', id: item.id, changes: { confidence: event.target.value as FactConfidence } })}>{(Object.keys(CONFIDENCE_LABELS) as FactConfidence[]).map((value) => <option key={value} value={value}>{CONFIDENCE_LABELS[value]}</option>)}</select></FormField>
                          </div>
                          {item.action === 'correct' && <><FormField label="Correct value"><input className="field" value={item.value} onChange={(event) => dispatch({ type: 'update-fact-change', id: item.id, changes: { value: event.target.value } })} /></FormField><div className="draft-editor-pair"><FormField label="Why it changed"><input className="field" value={item.correctionNote} onChange={(event) => dispatch({ type: 'update-fact-change', id: item.id, changes: { correctionNote: event.target.value } })} /></FormField><FormField label="Sensitivity"><select className="field field-select" value={item.sensitivity} onChange={(event) => dispatch({ type: 'update-fact-change', id: item.id, changes: { sensitivity: event.target.value as FactSensitivity } })}>{(Object.keys(SENSITIVITY_LABELS) as FactSensitivity[]).map((value) => <option key={value} value={value}>{SENSITIVITY_LABELS[value]}</option>)}</select></FormField></div></>}
                        </div>
                      )}
                      {item.type === 'relationshipChange' && (
                        <p className="field-help">This removes both reciprocal relationship records. Remove this review item if that is not what you intended.</p>
                      )}
                    </div>
                  )}
                </div>
              )
            })}
          </div>
        )
      })}

      {saveError && (
        <p className="field-error" role="alert">
          {saveError}
        </p>
      )}

      <div className="sheet-actions">
        <Button variant="quiet" onClick={onClose}>
          Back
        </Button>
        <Button variant="primary" loading={saving} disabled={active.length === 0 || fieldProblems} onClick={() => void save()}>
          Save {readyCount > 0 ? `${readyCount} item${readyCount === 1 ? '' : 's'}` : ''}
        </Button>
      </div>
    </div>
  )
}
