import { useEffect, useRef, useState } from 'react'
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

export function FactsSection({
  person,
  observations,
  addSignal = 0,
  title = 'Profile details',
  includeAttributes,
  emphasis = 'secondary',
  hideWhenEmpty = false,
}: {
  person: Person
  observations: Observation[]
  /// Bumping this from outside opens the add dialog — the header overflow.
  addSignal?: number
  title?: string
  includeAttributes?: FactAttribute[]
  emphasis?: 'primary' | 'secondary'
  /// Keep the dialog host mounted without adding an empty section to the page.
  hideWhenEmpty?: boolean
}) {
  const uid = useUID()
  const now = new Date()
  const [adding, setAdding] = useState(false)
  useEffect(() => {
    if (addSignal > 0) setAdding(true)
  }, [addSignal])
  const [inlineCorrection, setInlineCorrection] = useState<{ observation: Observation; value: string } | null>(null)
  const committing = useRef<Set<string>>(new Set())
  const [historyFor, setHistoryFor] = useState<FactAttribute | null>(null)
  const [revealed, setRevealed] = useState<Set<string>>(new Set())

  const attributes = populatedAttributes(observations).filter(
    (attribute) => includeAttributes === undefined || includeAttributes.includes(attribute),
  )

  async function confirm(observation: Observation) {
    const { plan } = planConfirmObservation(observation, new Date())
    await applyPlan(uid, plan)
  }

  async function commitInlineCorrection(observation: Observation, value: string) {
    const next = value.trim()
    if (!next || next === observation.value || committing.current.has(observation.id)) {
      setInlineCorrection(null)
      return
    }
    committing.current.add(observation.id)
    setInlineCorrection(null)
    try {
      await applyPlan(uid, planCorrection(observation, { value: next }, '', new Date()).plan)
    } finally {
      committing.current.delete(observation.id)
    }
  }

  if (hideWhenEmpty && attributes.length === 0 && !adding) return null

  return (
    <section className="rail-section remember-facts context-facts" data-emphasis={emphasis}>
      <div className="aside-panel-head">
        <h2 className="rail-section-title">{title}</h2>
        <button type="button" className="button button-plain button-small" onClick={() => setAdding(true)}>
          Add a fact
        </button>
      </div>

      {attributes.length === 0 && <p className="row-subtitle">Nothing recorded in this section yet.</p>}

      {attributes.map((attribute) => {
        const values = currentValues(observations, attribute)
        const past = history(observations, attribute)
        return (
          <div key={attribute} className="fact-group">
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
                  ) : inlineCorrection?.observation.id === observation.id ? (
                    <input
                      className="inline-text-editor"
                      aria-label={`Edit ${attributeLabel(attribute)}`}
                      value={inlineCorrection.value}
                      onChange={(event) => setInlineCorrection({ observation, value: event.target.value })}
                      onBlur={(event) => void commitInlineCorrection(observation, event.target.value)}
                      onKeyDown={(event) => {
                        if (event.key === 'Enter') {
                          event.preventDefault()
                          void commitInlineCorrection(observation, event.currentTarget.value)
                        }
                        if (event.key === 'Escape') setInlineCorrection(null)
                      }}
                      autoFocus
                    />
                  ) : (
                    <button
                      type="button"
                      className="inline-fact-value"
                      title={`Edit ${attributeLabel(attribute)}`}
                      onClick={() => setInlineCorrection({ observation, value: observation.value })}
                    >
                      {observation.value}
                    </button>
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
                  </span>
                </div>
              )
            })}
          </div>
        )
      })}

      {adding && <AddFactSheet person={person} onClose={() => setAdding(false)} />}
      {historyFor && (
        <HistorySheet attribute={historyFor} observations={observations} onClose={() => setHistoryFor(null)} />
      )}
    </section>
  )
}
