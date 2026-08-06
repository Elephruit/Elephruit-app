import { useMemo, useState } from 'react'
import { planFromResolved, slotName, type PersonSlot, type ResolvedItem } from '../../domain/assist'
import { attributeLabel, CONFIDENCE_LABELS } from '../../domain/facts'
import { INTERACTION_KIND_LABELS } from '../../domain/interaction'
import { kindLabel, possessivePhrase } from '../../domain/relationships'
import { applyPlan } from '../../data/applyPlan'
import { useUID } from '../UserContext'
import { Button } from '../components/Button'

function SlotName({ slot }: { slot: PersonSlot }) {
  return (
    <>
      {slotName(slot)}
      {slot.ref === 'create' && (
        <span className="chip" style={{ cursor: 'default', marginLeft: 4 }}>
          new
        </span>
      )}
    </>
  )
}

function itemSummary(item: ResolvedItem): React.ReactNode {
  switch (item.type) {
    case 'interaction':
      return (
        <>
          <span className="row-title" style={{ display: 'block' }}>
            {INTERACTION_KIND_LABELS[item.kind]} — {item.summary}
          </span>
          <span className="row-subtitle">
            with{' '}
            {item.participants.map((slot, index) => (
              <span key={slot.person.id}>
                {index > 0 && ', '}
                <SlotName slot={slot} />
              </span>
            ))}
          </span>
          {item.discussion && (
            <span className="row-subtitle" style={{ display: 'block' }}>
              {item.discussion}
            </span>
          )}
        </>
      )
    case 'fact':
      return (
        <>
          <span className="row-title" style={{ display: 'block' }}>
            {attributeLabel(item.attribute)}: {item.value}
          </span>
          <span className="row-subtitle">
            about <SlotName slot={item.person} />
            {item.confidence !== 'stated' && ` · ${CONFIDENCE_LABELS[item.confidence]}`}
          </span>
        </>
      )
    case 'relationship': {
      const otherName = item.other
        ? slotName(item.other)
        : `“${possessivePhrase(slotName(item.subject), item.kind, item.label)}” — unnamed, will create`
      return (
        <>
          <span className="row-title" style={{ display: 'block' }}>
            <SlotName slot={item.subject} /> → {item.label ?? kindLabel(item.kind)} → {otherName}
          </span>
          {item.facts.length > 0 && (
            <span className="row-subtitle">
              {item.facts.map((f) => `${attributeLabel(f.attribute)}: ${f.value}`).join(' · ')}
            </span>
          )}
        </>
      )
    }
    case 'followUp':
      return (
        <>
          <span className="row-title" style={{ display: 'block' }}>
            {item.title}
          </span>
          {item.people.length > 0 && (
            <span className="row-subtitle">
              for{' '}
              {item.people.map((slot, index) => (
                <span key={slot.person.id}>
                  {index > 0 && ', '}
                  <SlotName slot={slot} />
                </span>
              ))}
            </span>
          )}
        </>
      )
  }
}

const TYPE_LABELS: Record<ResolvedItem['type'], string> = {
  interaction: 'Interaction',
  fact: 'Facts',
  relationship: 'Relationships',
  followUp: 'Follow-ups',
}

/// The confirmation gate, as pure content — the caller decides whether it sits
/// beside the text or inside a dialog. One tap accepts everything, but nothing
/// is written the user has not seen — each item shows exactly which person it
/// landed on, and unchecking removes it (and any person only it would have
/// created).
export function ReviewPanel({
  items,
  warnings,
  onClose,
  onSaved,
}: {
  items: ResolvedItem[]
  warnings: string[]
  onClose: () => void
  onSaved: () => void
}) {
  const uid = useUID()
  const [kept, setKept] = useState<Set<string>>(() => new Set(items.map((i) => i.id)))
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)

  // One plan for both the count and the save — planFromResolved mints fresh IDs
  // per call, so building it twice would save different records than counted.
  const plan = useMemo(() => planFromResolved(items, kept, new Date()), [items, kept])

  function toggle(id: string) {
    setKept((current) => {
      const next = new Set(current)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  async function save() {
    if (plan.length === 0 || saving) return
    setSaving(true)
    setError(null)
    try {
      await applyPlan(uid, plan)
      onSaved()
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Could not save.')
      setSaving(false)
    }
  }

  const sections = (['interaction', 'fact', 'relationship', 'followUp'] as const)
    .map((type) => ({ type, rows: items.filter((i) => i.type === type) }))
    .filter((s) => s.rows.length > 0)

  return (
    <>
      {warnings.map((warning) => (
        <p key={warning} className="row-subtitle" style={{ color: 'var(--color-due-today)' }}>
          {warning}
        </p>
      ))}

      {items.length === 0 && <p className="row-subtitle">Nothing structured was found in that update.</p>}

      {sections.map((section) => (
        <div key={section.type}>
          <h3 className="section-header">{TYPE_LABELS[section.type]}</h3>
          {section.rows.map((item) => (
            <label key={item.id} className="row" style={{ cursor: 'pointer', alignItems: 'flex-start' }}>
              <input
                type="checkbox"
                checked={kept.has(item.id)}
                onChange={() => toggle(item.id)}
                style={{ marginTop: 4 }}
              />
              <span style={{ minWidth: 0, opacity: kept.has(item.id) ? 1 : 0.45 }}>{itemSummary(item)}</span>
            </label>
          ))}
        </div>
      ))}

      {error && (
        <p className="field-error" role="alert">
          {error}
        </p>
      )}

      <div className="sheet-actions">
        <Button variant="quiet" onClick={onClose}>
          Back
        </Button>
        <Button variant="primary" loading={saving} disabled={plan.length === 0} onClick={() => void save()}>
          Save {kept.size > 0 ? `${kept.size} item${kept.size === 1 ? '' : 's'}` : ''}
        </Button>
      </div>
    </>
  )
}
