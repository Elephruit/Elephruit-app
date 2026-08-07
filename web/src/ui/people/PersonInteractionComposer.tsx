import { useState } from 'react'
import { emptyInteractionDraft, planInteractionBundle, type InteractionDraft } from '../../domain/capture'
import { INTERACTION_KINDS, INTERACTION_KIND_LABELS } from '../../domain/interaction'
import type { Person } from '../../domain/person'
import { planMemoryRecord } from '../../domain/memory'
import { applyPlan } from '../../data/applyPlan'
import { useUID } from '../UserContext'
import { fromLocalInputValue, toLocalInputValue } from '../dateInput'
import { Button } from '../components/Button'

export function PersonInteractionComposer({ person, onClose }: { person: Person; onClose: () => void }) {
  const uid = useUID()
  const now = new Date()
  const [draft, setDraft] = useState<InteractionDraft>(() => ({
    ...emptyInteractionDraft(now),
    participantIDs: [person.id],
  }))
  const [occurredAt, setOccurredAt] = useState(() => toLocalInputValue(now))
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function save() {
    if (!draft.summary.trim() || saving) return
    setSaving(true)
    setError(null)
    const savedAt = new Date()
    try {
      const resolved = { ...draft, occurredAt: fromLocalInputValue(occurredAt) }
      const { plan, interaction, reminders } = planInteractionBundle(resolved, [person], savedAt)
      const { plan: memoryPlan } = planMemoryRecord({
        kind: 'interaction',
        title: interaction.summary,
        occurredAt: interaction.occurredAt,
        personIDs: [person.id],
        interactionID: interaction.id,
        reminderIDs: reminders.map((reminder) => reminder.id),
        origin: 'manualInteraction',
      }, savedAt)
      await applyPlan(uid, [...plan, ...memoryPlan])
      onClose()
    } catch (cause) {
      setSaving(false)
      setError(cause instanceof Error ? cause.message : 'Could not save this interaction.')
    }
  }

  return (
    <section className="person-interaction-composer" aria-label={`Log an interaction with ${person.displayName}`}>
      <div className="interaction-composer-head">
        <div>
          <h2>Log interaction</h2>
          <p>Capture what happened without leaving {person.displayName}'s workspace.</p>
        </div>
        <button type="button" className="icon-button" aria-label="Close interaction composer" onClick={onClose}>×</button>
      </div>

      <div className="interaction-kind-row" role="radiogroup" aria-label="Interaction type">
        {INTERACTION_KINDS.map((kind) => (
          <button
            key={kind}
            type="button"
            className="chip"
            aria-pressed={draft.kind === kind}
            onClick={() => setDraft({ ...draft, kind })}
          >
            {INTERACTION_KIND_LABELS[kind]}
          </button>
        ))}
      </div>

      <div className="interaction-summary-grid">
        <label>
          <span className="field-label">What happened?</span>
          <input
            className="field"
            value={draft.summary}
            onChange={(event) => setDraft({ ...draft, summary: event.target.value })}
            placeholder={`Coffee, call, introduction, meeting…`}
            autoFocus
          />
        </label>
        <label>
          <span className="field-label">When</span>
          <input className="field" type="datetime-local" value={occurredAt} onChange={(event) => setOccurredAt(event.target.value)} />
        </label>
      </div>

      <label>
        <span className="field-label">Notes</span>
        <textarea
          className="field interaction-notes"
          value={draft.discussion}
          onChange={(event) => setDraft({ ...draft, discussion: event.target.value })}
          placeholder="Key context, decisions, or details worth carrying into the next conversation"
        />
      </label>

      <label>
        <span className="field-label">Follow-ups</span>
        <textarea
          className="field interaction-followups"
          value={draft.followUps}
          onChange={(event) => setDraft({ ...draft, followUps: event.target.value })}
          placeholder="One next step per line — optional"
        />
      </label>

      {error && <p className="field-error" role="alert">{error}</p>}
      <div className="interaction-composer-actions">
        <Button variant="quiet" onClick={onClose}>Cancel</Button>
        <Button variant="primary" loading={saving} disabled={!draft.summary.trim()} onClick={() => void save()}>
          Save interaction
        </Button>
      </div>
    </section>
  )
}
