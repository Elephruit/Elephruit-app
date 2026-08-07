/// Comparing two unnamed people who may be the same person — or may not be.
/// One column each: temporary label, distinguishing facts, interaction count,
/// created date. "They are different" persists the dismissal; merge shows a
/// preview and applies the atomic merge plan; Add a name hands off to the
/// naming sheet. Nothing merges automatically.

import { useMemo, useState } from 'react'
import { applyPlan } from '../../../data/applyPlan'
import { usePersonInteractions, useRemindersFor } from '../../../data/hooks'
import type { Observation } from '../../../domain/facts'
import type { Person } from '../../../domain/person'
import { defaultMergeTarget, planDismissComparison, planMergePeople } from '../../../domain/personMerge'
import type { UnnamedPairSuggestion } from '../../../domain/personIdentity'
import { relationshipIdentitySummary } from '../../../domain/personIdentity'
import type { Relationship } from '../../../domain/relationships'
import { useUID } from '../../UserContext'
import { Avatar } from '../../components/Avatar'
import { Button } from '../../components/Button'
import { Sheet } from '../../components/Sheet'

export function CompareUnnamedPeopleSheet({
  subject,
  suggestion,
  relationships,
  observationsBySubject,
  onAddName,
  onClose,
}: {
  subject: Person
  suggestion: UnnamedPairSuggestion
  /// Every relationship row in the account — merge needs both sides.
  relationships: Relationship[]
  observationsBySubject: Map<string, Observation[]>
  onAddName: (person: Person) => void
  onClose: () => void
}) {
  const uid = useUID()
  const [a, b] = suggestion.people
  const rawInteractionsA = usePersonInteractions(uid, a.id)
  const rawInteractionsB = usePersonInteractions(uid, b.id)
  const rawRemindersA = useRemindersFor(uid, a.id)
  const rawRemindersB = useRemindersFor(uid, b.id)
  const [merging, setMerging] = useState(false)
  const [busy, setBusy] = useState(false)

  const countA = rawInteractionsA?.length ?? 0
  const countB = rawInteractionsB?.length ?? 0

  const target = useMemo(
    () =>
      defaultMergeTarget(a, b, {
        factCount: (id) => (observationsBySubject.get(id) ?? []).length,
        interactionCount: (id) => (id === a.id ? countA : countB),
      }),
    [a, b, observationsBySubject, countA, countB],
  )
  const source = target.id === a.id ? b : a

  const relationshipFor = (person: Person) =>
    relationships.find((r) => r.subjectID === subject.id && r.otherID === person.id)

  const mergePlan = useMemo(() => {
    if (!merging) return null
    const involved = relationships.filter(
      (r) =>
        r.subjectID === source.id || r.otherID === source.id || r.subjectID === target.id || r.otherID === target.id,
    )
    return planMergePeople(
      {
        source,
        target,
        interactions: (source.id === a.id ? rawInteractionsA : rawInteractionsB) ?? [],
        observations: observationsBySubject.get(source.id) ?? [],
        reminders: (source.id === a.id ? rawRemindersA : rawRemindersB) ?? [],
        relationships: involved,
      },
      new Date(),
    )
  }, [merging, source, target, relationships, observationsBySubject, rawInteractionsA, rawInteractionsB, rawRemindersA, rawRemindersB, a.id])

  async function dismiss() {
    if (busy) return
    setBusy(true)
    await applyPlan(uid, planDismissComparison(subject, suggestion.key))
    onClose()
  }

  async function merge() {
    if (!mergePlan || busy) return
    setBusy(true)
    await applyPlan(uid, mergePlan.plan)
    onClose()
  }

  function column(person: Person, interactionCount: number) {
    const relationship = relationshipFor(person)
    const summary = relationship
      ? relationshipIdentitySummary({
          subject,
          other: person,
          relationship,
          observations: observationsBySubject.get(person.id) ?? [],
        })
      : null
    return (
      <div className="compare-column" key={person.id}>
        <Avatar name={person.displayName} colorName={person.colorName} unnamed />
        <p className="compare-label">{summary?.primaryLabel ?? person.displayName}</p>
        {summary && summary.details.length > 0 ? (
          <p className="compare-details">{summary.details.map((d) => d.value).join(' · ')}</p>
        ) : (
          <p className="compare-details compare-details-empty">No distinguishing facts yet</p>
        )}
        <p className="compare-meta">
          {interactionCount} interaction{interactionCount === 1 ? '' : 's'}
        </p>
        <p className="compare-meta">
          Added {person.createdAt.toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' })}
        </p>
        <Button variant="secondary" small onClick={() => onAddName(person)}>
          Add a name
        </Button>
      </div>
    )
  }

  return (
    <Sheet
      title="Compare unnamed people"
      onClose={onClose}
      footer={
        merging && mergePlan ? (
          <>
            <span className="sheet-confirm-text" role="alert">
              Merge into “{target.displayName}”? {mergePlan.preview.observationsMoved} facts,{' '}
              {mergePlan.preview.interactionsMoved} interactions, and {mergePlan.preview.remindersMoved} follow-ups
              move; {mergePlan.preview.pairsRemoved} duplicate connection{mergePlan.preview.pairsRemoved === 1 ? '' : 's'}{' '}
              collapse.
            </span>
            <Button variant="quiet" onClick={() => setMerging(false)}>
              Back
            </Button>
            <Button variant="primary" loading={busy} onClick={() => void merge()}>
              Merge records
            </Button>
          </>
        ) : (
          <>
            <Button variant="quiet" loading={busy} onClick={() => void dismiss()}>
              They are different
            </Button>
            <Button variant="secondary" onClick={() => setMerging(true)}>
              Merge records
            </Button>
          </>
        )
      }
    >
      <p className="row-subtitle" style={{ marginBottom: 'var(--space-medium)' }}>
        These two are recorded separately. If they are the same person, merging keeps every fact and interaction.
      </p>
      <div className="compare-columns">
        {column(a, countA)}
        {column(b, countB)}
      </div>
    </Sheet>
  )
}
