import { useMemo, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import {
  planNamePerson,
  planObservation,
  planRelationshipPair,
  planRelativeCapture,
} from '../../domain/capture'
import { attributeLabel, capturePrompt, customAttribute, type FactAttribute } from '../../domain/facts'
import { foldedForMatching, type Person } from '../../domain/person'
import {
  GROUP_TITLES,
  RELATIONSHIP_GROUPS,
  RELATIONSHIP_KINDS,
  SUGGESTED_ATTRIBUTES,
  genderedKind,
  groupOf,
  kindLabel,
  type Relationship,
  type RelationshipKind,
} from '../../domain/relationships'
import type { WritePlan } from '../../domain/writePlan'
import { applyPlan } from '../../data/applyPlan'
import { useUID } from '../UserContext'
import { Avatar } from '../components/Avatar'
import { Icon } from '../components/Icon'
import { Dialog } from '../components/Dialog'
import { planUnrelate } from '../../domain/capture'

function AddRelationshipSheet({
  subject,
  people,
  onClose,
}: {
  subject: Person
  people: Person[]
  onClose: () => void
}) {
  const uid = useUID()
  const [word, setWord] = useState('')
  const [kind, setKind] = useState<RelationshipKind>('friend')
  const [who, setWho] = useState('')
  const [existing, setExisting] = useState<Person | null>(null)
  const [facts, setFacts] = useState<Record<string, string>>({})
  const [customFactName, setCustomFactName] = useState('')
  const [customFactValue, setCustomFactValue] = useState('')
  const [saving, setSaving] = useState(false)

  const matches = useMemo(() => {
    const folded = foldedForMatching(who)
    if (!folded || existing) return []
    return people
      .filter((p) => p.id !== subject.id && foldedForMatching(p.displayName).includes(folded))
      .slice(0, 5)
  }, [who, people, subject.id, existing])

  function onWordChange(text: string) {
    setWord(text)
    // The typed word can pick the kind — "son" selects child — but the word
    // itself is what gets stored. The app never infers gender from a name.
    const inferred = genderedKind(text.trim())
    if (inferred) setKind(inferred)
  }

  async function save() {
    if (saving) return
    setSaving(true)
    const now = new Date()
    const factList = [
      ...SUGGESTED_ATTRIBUTES[kind]
        .filter((a) => facts[a]?.trim())
        .map((a) => ({ attribute: a as FactAttribute, value: facts[a] })),
      ...(customFactName.trim() && customFactValue.trim() && customAttribute(customFactName)
        ? [{ attribute: customAttribute(customFactName)!, value: customFactValue }]
        : []),
    ]

    let plan: WritePlan
    if (existing) {
      const pair = planRelationshipPair(
        { subjectID: subject.id, otherID: existing.id, kind, customLabel: word || null },
        now,
      )
      plan = [...pair.plan]
      for (const fact of factList) {
        plan.push(...planObservation({ subjectID: existing.id, ...fact }, now).plan)
      }
    } else {
      plan = planRelativeCapture(
        subject,
        { kind, label: word || null, name: who.trim() || null, facts: factList },
        now,
      ).plan
    }
    await applyPlan(uid, plan)
    onClose()
  }

  return (
    <Dialog title={`Somebody in ${subject.displayName}'s life`} onClose={onClose}>
      <label className="field-label" htmlFor="rel-word">
        Your word for them — optional
      </label>
      <input
        id="rel-word"
        className="field"
        value={word}
        onChange={(event) => onWordChange(event.target.value)}
        placeholder="“son”, “boss”, “roommate”"
      />

      <label className="field-label" htmlFor="rel-kind">
        Relationship
      </label>
      <select id="rel-kind" className="field" value={kind} onChange={(event) => setKind(event.target.value as RelationshipKind)}>
        {RELATIONSHIP_GROUPS.map((group) => (
          <optgroup key={group} label={GROUP_TITLES[group]}>
            {RELATIONSHIP_KINDS.filter((k) => groupOf(k) === group).map((k) => (
              <option key={k} value={k}>
                {kindLabel(k)}
              </option>
            ))}
          </optgroup>
        ))}
      </select>

      <label className="field-label" htmlFor="rel-who">
        Who — leave blank if you don't know their name yet
      </label>
      {existing ? (
        <div className="chip-row">
          <span className="chip chip-selected">
            {existing.displayName}
            <button
              type="button"
              className="button-plain button"
              style={{ padding: 0 }}
              aria-label="Clear person"
              onClick={() => setExisting(null)}
            >
              <Icon name="x" size={12} />
            </button>
          </span>
        </div>
      ) : (
        <input
          id="rel-who"
          className="field"
          value={who}
          onChange={(event) => setWho(event.target.value)}
          placeholder="A name, or an existing person"
        />
      )}
      {matches.map((match) => (
        <button
          key={match.id}
          type="button"
          className="row"
          style={{ padding: 'var(--space-tight) 0' }}
          onClick={() => {
            setExisting(match)
            setWho('')
          }}
        >
          <Avatar name={match.displayName} colorName={match.colorName} small />
          <span className="row-title">{match.displayName}</span>
        </button>
      ))}

      <label className="field-label">Worth noting about them</label>
      {SUGGESTED_ATTRIBUTES[kind].map((attribute) => (
        <input
          key={attribute}
          className="field"
          style={{ marginBottom: 'var(--space-small)' }}
          value={facts[attribute] ?? ''}
          onChange={(event) => setFacts((current) => ({ ...current, [attribute]: event.target.value }))}
          placeholder={`${attributeLabel(attribute)} — ${capturePrompt(attribute)}`}
          aria-label={attributeLabel(attribute)}
        />
      ))}
      <div style={{ display: 'flex', gap: 'var(--space-small)' }}>
        <input
          className="field"
          value={customFactName}
          onChange={(event) => setCustomFactName(event.target.value)}
          placeholder="Anything else…"
          aria-label="Custom fact category"
        />
        <input
          className="field"
          value={customFactValue}
          onChange={(event) => setCustomFactValue(event.target.value)}
          placeholder="…and the fact"
          aria-label="Custom fact value"
        />
      </div>

      <div className="sheet-actions">
        <button type="button" className="button button-quiet" onClick={onClose}>
          Cancel
        </button>
        <button type="button" className="button" disabled={saving} onClick={() => void save()}>
          Record
        </button>
      </div>
    </Dialog>
  )
}

function NameSheet({ person, onClose }: { person: Person; onClose: () => void }) {
  const uid = useUID()
  const [name, setName] = useState('')
  const [saving, setSaving] = useState(false)

  async function save() {
    if (!name.trim() || saving) return
    setSaving(true)
    const { plan } = planNamePerson(person, name, new Date())
    await applyPlan(uid, plan)
    onClose()
  }

  return (
    <Dialog title={`Name ${person.displayName}`} onClose={onClose}>
      <p className="row-subtitle">Every fact and relationship they have stays attached.</p>
      <input
        className="field"
        style={{ marginTop: 'var(--space-medium)' }}
        value={name}
        onChange={(event) => setName(event.target.value)}
        placeholder="Their name"
        autoFocus
      />
      <div className="sheet-actions">
        <button type="button" className="button button-quiet" onClick={onClose}>
          Cancel
        </button>
        <button type="button" className="button" disabled={!name.trim() || saving} onClick={() => void save()}>
          Save name
        </button>
      </div>
    </Dialog>
  )
}

export function RelationshipsSection({
  person,
  relationships,
  people,
}: {
  person: Person
  relationships: Relationship[]
  people: Person[]
}) {
  const uid = useUID()
  const navigate = useNavigate()
  const [adding, setAdding] = useState(false)
  const [naming, setNaming] = useState<Person | null>(null)

  const peopleByID = useMemo(() => new Map(people.map((p) => [p.id, p])), [people])

  const grouped = RELATIONSHIP_GROUPS.map((group) => ({
    group,
    rows: relationships.filter((r) => groupOf(r.kind) === group),
  })).filter((g) => g.rows.length > 0)

  const unnamed = relationships
    .map((r) => peopleByID.get(r.otherID))
    .filter((p): p is Person => Boolean(p && !p.hasStatedName))

  async function unrelate(forward: Relationship) {
    await applyPlan(uid, planUnrelate(forward).plan)
  }

  return (
    <>
      <div style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between' }}>
        <h2 className="section-header">Relationships</h2>
        <button type="button" className="button button-plain" onClick={() => setAdding(true)}>
          Add
        </button>
      </div>

      {grouped.length === 0 && (
        <p className="row-subtitle">Nobody linked yet — a partner, a boss, an unnamed son.</p>
      )}

      {grouped.map(({ group, rows }) => (
        <div key={group}>
          <p className="row-subtitle" style={{ marginTop: 'var(--space-small)', fontWeight: 600 }}>
            {GROUP_TITLES[group]}
          </p>
          {rows.map((relationship) => {
            const other = peopleByID.get(relationship.otherID)
            if (!other) return null
            return (
              <div key={relationship.id} className="row" style={{ cursor: 'default' }}>
                <button
                  type="button"
                  style={{ display: 'flex', alignItems: 'center', gap: 'var(--space-medium)', background: 'none', border: 0, padding: 0, cursor: 'pointer', minWidth: 0 }}
                  onClick={() => navigate(`/people/${other.id}`)}
                >
                  <Avatar name={other.displayName} colorName={other.colorName} small />
                  <span style={{ textAlign: 'left' }}>
                    <span className="row-title" style={{ display: 'block' }}>
                      {other.displayName}
                    </span>
                    <span className="row-subtitle">{relationship.customLabel ?? kindLabel(relationship.kind)}</span>
                  </span>
                </button>
                <span className="row-trailing">
                  <button
                    type="button"
                    className="button button-plain"
                    style={{ padding: '2px 6px', color: 'var(--color-text-tertiary)' }}
                    aria-label={`Remove relationship with ${other.displayName}`}
                    onClick={() => void unrelate(relationship)}
                  >
                    <Icon name="x" size={14} />
                  </button>
                </span>
              </div>
            )
          })}
        </div>
      ))}

      {unnamed.length > 0 && (
        <>
          <h2 className="section-header">To fill in</h2>
          {unnamed.map((placeholder) => (
            <div key={placeholder.id} className="row" style={{ cursor: 'default' }}>
              <span className="row-title">{placeholder.displayName}</span>
              <span className="row-trailing">
                <button type="button" className="button button-plain" onClick={() => setNaming(placeholder)}>
                  Add name
                </button>
              </span>
            </div>
          ))}
        </>
      )}

      {adding && <AddRelationshipSheet subject={person} people={people} onClose={() => setAdding(false)} />}
      {naming && <NameSheet person={naming} onClose={() => setNaming(null)} />}
    </>
  )
}
