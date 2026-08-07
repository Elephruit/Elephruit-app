import { useMemo, useState } from 'react'
import { useNavigate, useSearchParams } from 'react-router-dom'
import { makePerson, planInteractionBundle, type InteractionDraft } from '../../domain/capture'
import { INTERACTION_KINDS, INTERACTION_KIND_LABELS, type InteractionKind } from '../../domain/interaction'
import { planMemoryRecord } from '../../domain/memory'
import type { Person } from '../../domain/person'
import type { WritePlan } from '../../domain/writePlan'
import { applyPlan } from '../../data/applyPlan'
import { usePeople } from '../../data/hooks'
import { useUID } from '../UserContext'
import { Icon } from '../components/Icon'
import { fromLocalInputValue, toLocalInputValue } from '../dateInput'
import { ParticipantPicker } from './ParticipantPicker'

export function LogPage() {
  const uid = useUID()
  const navigate = useNavigate()
  const [params] = useSearchParams()
  const people = usePeople(uid) ?? []

  const preselected = params.get('person')
  const prefilledText = params.get('text') ?? ''

  const [kind, setKind] = useState<InteractionKind>('in-person')
  const [selectedIDs, setSelectedIDs] = useState<Set<string>>(
    () => new Set(preselected ? [preselected] : []),
  )
  const [pendingNew, setPendingNew] = useState<Person[]>([])
  const [summary, setSummary] = useState('')
  const [occurredAt, setOccurredAt] = useState(() => toLocalInputValue(new Date()))
  const [discussion, setDiscussion] = useState(prefilledText)
  const [followUps, setFollowUps] = useState('')
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const participants = useMemo(() => {
    const byID = new Map<string, Person>()
    for (const person of [...people, ...pendingNew]) byID.set(person.id, person)
    return [...selectedIDs].map((id) => byID.get(id)).filter((p): p is Person => Boolean(p))
  }, [people, pendingNew, selectedIDs])

  const valid = summary.trim().length > 0 && participants.length > 0

  function toggle(id: string) {
    setSelectedIDs((current) => {
      const next = new Set(current)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  function createPending(name: string) {
    const person = makePerson({ displayName: name }, new Date())
    setPendingNew((current) => [...current, person])
    setSelectedIDs((current) => new Set(current).add(person.id))
  }

  async function save() {
    if (!valid || saving) return
    setSaving(true)
    setError(null)
    try {
      const now = new Date()
      const draft: InteractionDraft = {
        kind,
        participantIDs: participants.map((p) => p.id),
        summary,
        discussion,
        followUps,
        occurredAt: fromLocalInputValue(occurredAt),
      }
      const bundle = planInteractionBundle(draft, participants, now)
      // Inline-created people join the same batch, so cancelling the composer
      // can never leave a person behind and saving can never lose one.
      const creations: WritePlan = pendingNew
        .filter((person) => selectedIDs.has(person.id))
        .map((person) => ({ op: 'set', collection: 'people', id: person.id, data: person }))
      // Manual logging honors the same feed contract as capture: one memory
      // record naming everything this save writes.
      const { plan: memoryPlan } = planMemoryRecord(
        {
          kind: 'interaction',
          title: bundle.interaction.summary,
          occurredAt: bundle.interaction.occurredAt,
          personIDs: bundle.interaction.participantIDs,
          interactionID: bundle.interaction.id,
          reminderIDs: bundle.reminders.map((r) => r.id),
          origin: 'manualInteraction',
        },
        now,
      )
      await applyPlan(uid, [...creations, ...bundle.plan, ...memoryPlan])
      navigate(preselected ? `/people/${preselected}` : '/')
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Could not save.')
      setSaving(false)
    }
  }

  return (
    <main className="page">
      <h1 className="page-title">Log an interaction</h1>

      <div className="chip-row-scroll" role="radiogroup" aria-label="Kind">
        {INTERACTION_KINDS.map((k) => (
          <button
            key={k}
            type="button"
            className="chip"
            aria-pressed={kind === k}
            onClick={() => setKind(k)}
          >
            <Icon name={k} size={14} />
            {INTERACTION_KIND_LABELS[k]}
          </button>
        ))}
      </div>

      <label className="field-label" htmlFor="log-summary">
        What happened?
      </label>
      <input
        id="log-summary"
        className="field"
        value={summary}
        onChange={(event) => setSummary(event.target.value)}
        placeholder="Coffee at the market, caught up on the move"
      />

      <label className="field-label">People</label>
      <ParticipantPicker
        people={people}
        pendingNew={pendingNew}
        selectedIDs={selectedIDs}
        onToggle={toggle}
        onCreate={createPending}
      />

      <label className="field-label" htmlFor="log-when">
        When
      </label>
      <input
        id="log-when"
        className="field"
        type="datetime-local"
        value={occurredAt}
        onChange={(event) => setOccurredAt(event.target.value)}
      />

      <label className="field-label" htmlFor="log-discussion">
        Discussion
      </label>
      <textarea
        id="log-discussion"
        className="field"
        value={discussion}
        onChange={(event) => setDiscussion(event.target.value)}
        placeholder="What you talked about — optional"
      />

      <label className="field-label" htmlFor="log-followups">
        Follow-ups — one per line
      </label>
      <textarea
        id="log-followups"
        className="field"
        value={followUps}
        onChange={(event) => setFollowUps(event.target.value)}
        placeholder={'Send the neighborhood list\nIntroduce her to Sam'}
      />

      {error && <p role="alert">{error}</p>}

      <div className="sheet-actions">
        <button type="button" className="button button-quiet" onClick={() => navigate(-1)}>
          Cancel
        </button>
        <button type="button" className="button" disabled={!valid || saving} onClick={() => void save()}>
          Save
        </button>
      </div>
    </main>
  )
}
