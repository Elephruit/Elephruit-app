import { useState } from 'react'
import { planConfirmObservation, planCorrection, planObservation } from '../../domain/capture'
import { planMemoryRecord } from '../../domain/memory'
import {
  CONFIDENCE_LABELS,
  CURATED_ATTRIBUTES,
  SENSITIVITY_LABELS,
  attributeLabel,
  capturePrompt,
  captureKind,
  currentValues,
  customAttribute,
  effectiveConfidence,
  confidenceNeedsLabel,
  history,
  isStale,
  populatedAttributes,
  type FactAttribute,
  type FactConfidence,
  type FactSensitivity,
  type Observation,
} from '../../domain/facts'
import type { Person } from '../../domain/person'
import { applyPlan } from '../../data/applyPlan'
import { useUID } from '../UserContext'
import { Icon } from '../components/Icon'
import { Dialog } from '../components/Dialog'
import { fromLocalInputValue, toLocalDateValue } from '../dateInput'

const CONFIDENCES: FactConfidence[] = ['stated', 'inferred', 'uncertain']
const SENSITIVITIES: FactSensitivity[] = ['normal', 'sensitive', 'restricted']

function AddFactSheet({
  person,
  sourceInteractionID = null,
  onClose,
}: {
  person: Person
  sourceInteractionID?: string | null
  onClose: () => void
}) {
  const uid = useUID()
  const [attribute, setAttribute] = useState<FactAttribute | null>(null)
  const [customText, setCustomText] = useState('')
  const [value, setValue] = useState('')
  const [confidence, setConfidence] = useState<FactConfidence>('stated')
  const [sensitivity, setSensitivity] = useState<FactSensitivity>('normal')
  const [observedOn, setObservedOn] = useState(() => toLocalDateValue(new Date()))
  const [saving, setSaving] = useState(false)

  // "Anything else" folds back into the curated set the moment it matches —
  // typing School gives the School card, not a second card beside it.
  const resolvedAttribute = customText.trim() ? customAttribute(customText) : attribute
  const valid = resolvedAttribute !== null && value.trim().length > 0

  async function save() {
    if (!valid || saving || resolvedAttribute === null) return
    setSaving(true)
    const now = new Date()
    const { plan, observation } = planObservation(
      {
        subjectID: person.id,
        attribute: resolvedAttribute,
        value,
        confidence,
        sensitivity,
        observedOn: fromLocalInputValue(`${observedOn}T12:00`),
        sourceInteractionID,
      },
      now,
    )
    const { plan: memoryPlan } = planMemoryRecord(
      {
        kind: 'manualUpdate',
        title: `Updated ${person.displayName}`,
        occurredAt: now,
        personIDs: [person.id],
        observationIDs: [observation.id],
        origin: 'manualFact',
      },
      now,
    )
    await applyPlan(uid, [...plan, ...memoryPlan])
    onClose()
  }

  return (
    <Dialog title={`Add a fact about ${person.displayName}`} onClose={onClose}>
      <label className="field-label">What kind of fact?</label>
      <div className="chip-row" role="radiogroup">
        {CURATED_ATTRIBUTES.map((a) => (
          <button
            key={a}
            type="button"
            className="chip"
            aria-pressed={resolvedAttribute === a && !customText.trim()}
            onClick={() => {
              setAttribute(a)
              setCustomText('')
            }}
          >
            {attributeLabel(a)}
          </button>
        ))}
      </div>
      <label className="field-label" htmlFor="fact-custom">
        Anything else
      </label>
      <input
        id="fact-custom"
        className="field"
        value={customText}
        onChange={(event) => setCustomText(event.target.value)}
        placeholder="Your own category — “allergy”, “book club”"
      />

      <label className="field-label" htmlFor="fact-value">
        {resolvedAttribute ? capturePrompt(resolvedAttribute) : 'The fact'}
      </label>
      <input
        id="fact-value"
        className="field"
        value={value}
        onChange={(event) => setValue(event.target.value)}
        inputMode={resolvedAttribute !== null && captureKind(resolvedAttribute) === 'wholeNumber' ? 'numeric' : undefined}
        placeholder="Verbatim, in their words"
      />

      <label className="field-label">How sure?</label>
      <div className="chip-row">
        {CONFIDENCES.map((c) => (
          <button key={c} type="button" className="chip" aria-pressed={confidence === c} onClick={() => setConfidence(c)}>
            {CONFIDENCE_LABELS[c]}
          </button>
        ))}
      </div>

      <label className="field-label">Sensitivity</label>
      <div className="chip-row">
        {SENSITIVITIES.map((s) => (
          <button key={s} type="button" className="chip" aria-pressed={sensitivity === s} onClick={() => setSensitivity(s)}>
            {SENSITIVITY_LABELS[s]}
          </button>
        ))}
      </div>

      <label className="field-label" htmlFor="fact-observed">
        When you heard it
      </label>
      <input
        id="fact-observed"
        className="field"
        type="date"
        value={observedOn}
        onChange={(event) => setObservedOn(event.target.value)}
      />

      <div className="sheet-actions">
        <button type="button" className="button button-quiet" onClick={onClose}>
          Cancel
        </button>
        <button type="button" className="button" disabled={!valid || saving} onClick={() => void save()}>
          Add fact
        </button>
      </div>
    </Dialog>
  )
}

function CorrectFactSheet({ old, onClose }: { old: Observation; onClose: () => void }) {
  const uid = useUID()
  const [value, setValue] = useState('')
  const [note, setNote] = useState('')
  const [saving, setSaving] = useState(false)

  async function save() {
    if (!value.trim() || saving) return
    setSaving(true)
    const { plan } = planCorrection(old, { value }, note, new Date())
    await applyPlan(uid, plan)
    onClose()
  }

  return (
    <Dialog title={`Correct ${attributeLabel(old.attribute)}`} onClose={onClose}>
      <p className="row-subtitle">
        Was: “{old.value}”. Correcting appends — the old value stays in history.
      </p>
      <label className="field-label" htmlFor="correct-value">
        Now
      </label>
      <input
        id="correct-value"
        className="field"
        value={value}
        onChange={(event) => setValue(event.target.value)}
        autoFocus
      />
      <label className="field-label" htmlFor="correct-note">
        Why the change? — optional
      </label>
      <input
        id="correct-note"
        className="field"
        value={note}
        onChange={(event) => setNote(event.target.value)}
        placeholder="“I misheard this”"
      />
      <div className="sheet-actions">
        <button type="button" className="button button-quiet" onClick={onClose}>
          Cancel
        </button>
        <button type="button" className="button" disabled={!value.trim() || saving} onClick={() => void save()}>
          Correct
        </button>
      </div>
    </Dialog>
  )
}

function HistorySheet({
  attribute,
  observations,
  onClose,
}: {
  attribute: FactAttribute
  observations: Observation[]
  onClose: () => void
}) {
  const rows = history(observations, attribute)
  return (
    <Dialog title={`${attributeLabel(attribute)} — history`} onClose={onClose}>
      {rows.length === 0 && <p className="row-subtitle">No earlier values.</p>}
      {rows.map((o) => (
        <div key={o.id} style={{ padding: 'var(--space-small) 0', borderBottom: '1px solid var(--color-separator)' }}>
          <p className="row-title">{o.value}</p>
          <p className="row-subtitle">
            heard {o.observedOn.toLocaleDateString()}
            {o.correctionNote ? ` · “${o.correctionNote}”` : ''}
          </p>
        </div>
      ))}
      <div className="sheet-actions">
        <button type="button" className="button button-quiet" onClick={onClose}>
          Done
        </button>
      </div>
    </Dialog>
  )
}

export function FactsSection({ person, observations }: { person: Person; observations: Observation[] }) {
  const uid = useUID()
  const now = new Date()
  const [adding, setAdding] = useState(false)
  const [correcting, setCorrecting] = useState<Observation | null>(null)
  const [historyFor, setHistoryFor] = useState<FactAttribute | null>(null)
  const [revealed, setRevealed] = useState<Set<string>>(new Set())

  const attributes = populatedAttributes(observations)

  async function confirm(observation: Observation) {
    const { plan } = planConfirmObservation(observation, new Date())
    await applyPlan(uid, plan)
  }

  return (
    <div className="aside-panel">
      <div className="aside-panel-head">
        <h2 className="aside-title">Facts</h2>
        <button type="button" className="button button-plain button-small" onClick={() => setAdding(true)}>
          Add a fact
        </button>
      </div>

      {attributes.length === 0 && (
        <p className="row-subtitle">Nothing recorded. Facts you add keep their date and their source.</p>
      )}

      {attributes.map((attribute) => {
        const values = currentValues(observations, attribute)
        const past = history(observations, attribute)
        return (
          <div key={attribute} style={{ padding: 'var(--space-small) 0', borderBottom: '1px solid var(--color-separator)' }}>
            <div style={{ display: 'flex', alignItems: 'baseline', gap: 'var(--space-small)' }}>
              <span className="row-subtitle" style={{ minWidth: 0 }}>
                {attributeLabel(attribute)}
              </span>
              {past.length > 0 && (
                <button type="button" className="chip" onClick={() => setHistoryFor(attribute)}>
                  history
                </button>
              )}
            </div>
            {values.map((observation) => {
              const displayed = effectiveConfidence(observation, now)
              const hidden = observation.sensitivity === 'restricted' && !revealed.has(observation.id)
              return (
                <div key={observation.id} style={{ display: 'flex', alignItems: 'center', gap: 'var(--space-small)', marginTop: 2 }}>
                  {hidden ? (
                    <button
                      type="button"
                      className="chip"
                      onClick={() => setRevealed((current) => new Set(current).add(observation.id))}
                    >
                      <Icon name="circle" size={12} /> Private — tap to show
                    </button>
                  ) : (
                    <span className="row-title" style={{ minWidth: 0 }}>
                      {observation.value}
                    </span>
                  )}
                  {!hidden && confidenceNeedsLabel(displayed) && (
                    <span
                      className="chip"
                      style={{ cursor: 'default', color: displayed === 'uncertain' ? 'var(--color-due-today)' : undefined }}
                    >
                      {CONFIDENCE_LABELS[displayed]}
                    </span>
                  )}
                  <span style={{ marginLeft: 'auto', display: 'flex', gap: 2, flex: 'none' }}>
                    {isStale(observation, now) && (
                      <button type="button" className="button button-plain" style={{ padding: '2px 6px' }} onClick={() => void confirm(observation)}>
                        Still true
                      </button>
                    )}
                    <button
                      type="button"
                      className="button button-plain"
                      style={{ padding: '2px 6px' }}
                      aria-label={`Correct ${attributeLabel(attribute)}`}
                      onClick={() => setCorrecting(observation)}
                    >
                      <Icon name="pencil" size={14} />
                    </button>
                  </span>
                </div>
              )
            })}
          </div>
        )
      })}

      {adding && <AddFactSheet person={person} onClose={() => setAdding(false)} />}
      {correcting && <CorrectFactSheet old={correcting} onClose={() => setCorrecting(null)} />}
      {historyFor && (
        <HistorySheet attribute={historyFor} observations={observations} onClose={() => setHistoryFor(null)} />
      )}
    </div>
  )
}
