/// The relationships panel: every row is an identity — the person's name or
/// their relationship word with distinguishing facts — so two unnamed sons
/// are tellable apart without opening either. Unnamed rows carry Add name at
/// rest; possible duplicates surface a compare callout; creation goes through
/// the stepped side-sheet flow.

import { useMemo, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { applyPlan } from '../../data/applyPlan'
import { useAllObservations, useAllRelationships } from '../../data/hooks'
import { planNamePerson, planUnrelate } from '../../domain/capture'
import type { Observation } from '../../domain/facts'
import type { Person } from '../../domain/person'
import {
  relationshipIdentitySummary,
  unnamedPairSuggestions,
  type UnnamedPairSuggestion,
} from '../../domain/personIdentity'
import { GROUP_TITLES, RELATIONSHIP_GROUPS, groupOf, type Relationship } from '../../domain/relationships'
import { useUID } from '../UserContext'
import { Avatar } from '../components/Avatar'
import { Dialog } from '../components/Dialog'
import { Icon } from '../components/Icon'
import { IdentitySummary } from '../components/IdentitySummary'
import { AddRelationshipFlow } from './relationships/AddRelationshipFlow'
import { CompareUnnamedPeopleSheet } from './relationships/CompareUnnamedPeopleSheet'

/// The one relationship row — also the preview the add-flow shows, so what
/// the user confirms is exactly what renders afterward.
export function RelationshipIdentityRow({
  subject,
  other,
  relationship,
  observations,
  onOpen,
  onAddName,
  onRemove,
  highlight = false,
}: {
  subject: Person
  other: Person
  relationship: Relationship
  observations: Observation[]
  onOpen?: () => void
  onAddName?: () => void
  onRemove?: () => void
  highlight?: boolean
}) {
  const summary = relationshipIdentitySummary({ subject, other, relationship, observations })
  return (
    <div className="relationship-row" data-highlight={highlight || undefined}>
      <button
        type="button"
        className="relationship-row-main"
        aria-label={summary.accessibleLabel}
        onClick={onOpen}
        disabled={!onOpen}
      >
        <Avatar name={other.displayName} colorName={other.colorName} small unnamed={!other.hasStatedName} />
        <IdentitySummary
          primary={summary.primaryLabel}
          details={summary.details.map((d) => d.value)}
          accessibleLabel={summary.accessibleLabel}
        />
      </button>
      <span className="relationship-row-actions">
        {!other.hasStatedName && onAddName && (
          <button type="button" className="button button-plain" onClick={onAddName}>
            Add name
          </button>
        )}
        {onRemove && (
          <button
            type="button"
            className="icon-button"
            aria-label={`Remove relationship ${summary.accessibleLabel}`}
            onClick={onRemove}
          >
            <Icon name="x" size={14} />
          </button>
        )}
      </span>
    </div>
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
    <Dialog title="Add their name" onClose={onClose}>
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
  const observations = useAllObservations(uid)
  const allRelationships = useAllRelationships(uid) ?? []
  const [adding, setAdding] = useState(false)
  const [naming, setNaming] = useState<Person | null>(null)
  const [comparing, setComparing] = useState<UnnamedPairSuggestion | null>(null)
  const [newRelationshipID, setNewRelationshipID] = useState<string | null>(null)

  const peopleByID = useMemo(() => new Map(people.map((p) => [p.id, p])), [people])
  const observationsBySubject = useMemo(() => {
    const map = new Map<string, Observation[]>()
    for (const observation of observations ?? []) {
      map.set(observation.subjectID, [...(map.get(observation.subjectID) ?? []), observation])
    }
    return map
  }, [observations])

  const grouped = RELATIONSHIP_GROUPS.map((group) => ({
    group,
    rows: relationships.filter((r) => groupOf(r.kind) === group),
  })).filter((g) => g.rows.length > 0)

  const suggestions = useMemo(
    () =>
      unnamedPairSuggestions(relationships, peopleByID, new Set(person.dismissedComparisonKeys ?? [])),
    [relationships, peopleByID, person.dismissedComparisonKeys],
  )

  async function unrelate(forward: Relationship) {
    await applyPlan(uid, planUnrelate(forward).plan)
  }

  return (
    <section className="rail-section">
      <div className="aside-panel-head">
        <h2 className="rail-section-title">Relationships</h2>
        <button type="button" className="button button-plain button-small" onClick={() => setAdding(true)}>
          Add
        </button>
      </div>

      {grouped.length === 0 && <p className="row-subtitle">Nobody linked yet — a partner, a boss, an unnamed son.</p>}

      {grouped.map(({ group, rows }) => {
        const groupSuggestions = suggestions.filter((s) => groupOf(s.kind) === group)
        return (
          <div key={group}>
            <h3 className="relationship-group-title">{GROUP_TITLES[group]}</h3>
            {rows.map((relationship) => {
              const other = peopleByID.get(relationship.otherID)
              if (!other) return null
              return (
                <RelationshipIdentityRow
                  key={relationship.id}
                  subject={person}
                  other={other}
                  relationship={relationship}
                  observations={observationsBySubject.get(other.id) ?? []}
                  onOpen={() => navigate(`/people/${other.id}`)}
                  onAddName={() => setNaming(other)}
                  onRemove={() => void unrelate(relationship)}
                  highlight={relationship.id === newRelationshipID}
                />
              )
            })}
            {groupSuggestions.map((suggestion) => (
              <p key={suggestion.key} className="relationship-compare-callout">
                Two unnamed {suggestion.label ? `${suggestion.label}s` : 'people'} may be hard to tell apart.{' '}
                <button type="button" className="button-plain button" onClick={() => setComparing(suggestion)}>
                  Compare them
                </button>
              </p>
            ))}
          </div>
        )
      })}

      {adding && (
        <AddRelationshipFlow
          subject={person}
          people={people}
          existingRelationships={relationships}
          observationsBySubject={observationsBySubject}
          onClose={() => setAdding(false)}
          onCreated={(relationshipID) => {
            setAdding(false)
            setNewRelationshipID(relationshipID)
            window.setTimeout(() => setNewRelationshipID(null), 900)
          }}
        />
      )}
      {naming && <NameSheet person={naming} onClose={() => setNaming(null)} />}
      {comparing && (
        <CompareUnnamedPeopleSheet
          subject={person}
          suggestion={comparing}
          relationships={allRelationships}
          observationsBySubject={observationsBySubject}
          onAddName={(target) => {
            setComparing(null)
            setNaming(target)
          }}
          onClose={() => setComparing(null)}
        />
      )}
    </section>
  )
}
