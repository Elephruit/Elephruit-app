/// Step 3 — optional distinguishing details. Only the top three suggested
/// attributes show; everything else, including the custom category/value
/// pair, hides behind "Add another detail".

import { useState } from 'react'
import { attributeLabel, capturePrompt, FactAttributes } from '../../../domain/facts'
import { SUGGESTED_ATTRIBUTES, type RelationshipKind } from '../../../domain/relationships'

export function RelationshipDetailsStep({
  kind,
  facts,
  custom,
  onFactChange,
  onCustomChange,
}: {
  kind: RelationshipKind
  facts: Record<string, string>
  custom: { name: string; value: string }
  onFactChange: (attribute: string, value: string) => void
  onCustomChange: (custom: { name: string; value: string }) => void
}) {
  const [expanded, setExpanded] = useState(false)
  const primary = SUGGESTED_ATTRIBUTES[kind].filter((a) => a !== FactAttributes.quickFact).slice(0, 3)
  const secondary = SUGGESTED_ATTRIBUTES[kind].filter((a) => !primary.includes(a))

  return (
    <div>
      <p className="field-label">Anything that will help you remember them?</p>
      <p className="field-help">Optional—you can add or correct details later.</p>

      {primary.map((attribute) => (
        <input
          key={attribute}
          className="field"
          style={{ marginTop: 'var(--space-small)' }}
          value={facts[attribute] ?? ''}
          onChange={(event) => onFactChange(attribute, event.target.value)}
          placeholder={`${attributeLabel(attribute)} — ${capturePrompt(attribute)}`}
          aria-label={attributeLabel(attribute)}
        />
      ))}

      {!expanded ? (
        <button type="button" className="button button-plain" style={{ marginTop: 'var(--space-small)' }} onClick={() => setExpanded(true)}>
          Add another detail
        </button>
      ) : (
        <>
          {secondary.map((attribute) => (
            <input
              key={attribute}
              className="field"
              style={{ marginTop: 'var(--space-small)' }}
              value={facts[attribute] ?? ''}
              onChange={(event) => onFactChange(attribute, event.target.value)}
              placeholder={`${attributeLabel(attribute)} — ${capturePrompt(attribute)}`}
              aria-label={attributeLabel(attribute)}
            />
          ))}
          <div style={{ display: 'flex', gap: 'var(--space-small)', marginTop: 'var(--space-small)' }}>
            <input
              className="field"
              value={custom.name}
              onChange={(event) => onCustomChange({ ...custom, name: event.target.value })}
              placeholder="Anything else…"
              aria-label="Custom detail category"
            />
            <input
              className="field"
              value={custom.value}
              onChange={(event) => onCustomChange({ ...custom, value: event.target.value })}
              placeholder="…and the detail"
              aria-label="Custom detail value"
            />
          </div>
        </>
      )}
    </div>
  )
}
