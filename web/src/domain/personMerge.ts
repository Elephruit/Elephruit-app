/// Merging two records that turn out to be the same person. Never automatic:
/// the UI shows a preview and the user chooses. The plan rewrites every
/// reference — interaction participants, observations, reminders, and
/// relationship pairs (handled as whole pairs, so reciprocal invariants
/// survive) — removes any self-relationship or duplicate pair the merge
/// would create, and deletes the source only in the same atomic batch.

import type { Observation } from './facts'
import type { Interaction } from './interaction'
import type { Person } from './person'
import { INVERSE, type Relationship, type RelationshipKind } from './relationships'
import type { Reminder } from './reminders'
import type { WritePlan } from './writePlan'

/// Direction-invariant identity of a relationship pair: the same two people
/// in the same kind-and-inverse relation, whichever row happens to be looked
/// at. Without this, whether a duplicate collapses would depend on which of a
/// pair's two rows drew the smaller random id.
function pairKey(subjectID: string, otherID: string, kind: RelationshipKind): string {
  const kinds = [kind, INVERSE[kind]].sort().join('|')
  return subjectID < otherID ? `${subjectID}↔${otherID}:${kinds}` : `${otherID}↔${subjectID}:${kinds}`
}

export interface MergeInputs {
  source: Person
  target: Person
  /// Interactions involving the source.
  interactions: Interaction[]
  /// The source's observations.
  observations: Observation[]
  /// Reminders involving the source.
  reminders: Reminder[]
  /// Every relationship row whose subject or other is the source OR the
  /// target — both sides are needed to detect duplicates after repointing.
  relationships: Relationship[]
}

/// Which record survives, by default: a stated name beats a placeholder, then
/// more attached facts and interactions, then age.
export function defaultMergeTarget(
  a: Person,
  b: Person,
  context: { factCount: (id: string) => number; interactionCount: (id: string) => number },
): Person {
  if (a.hasStatedName !== b.hasStatedName) return a.hasStatedName ? a : b
  const weight = (p: Person) => context.factCount(p.id) + context.interactionCount(p.id)
  if (weight(a) !== weight(b)) return weight(a) > weight(b) ? a : b
  return a.createdAt.getTime() <= b.createdAt.getTime() ? a : b
}

export interface MergePreview {
  interactionsMoved: number
  observationsMoved: number
  remindersMoved: number
  relationshipsRepointed: number
  pairsRemoved: number
}

export function planMergePeople(inputs: MergeInputs, now: Date): { plan: WritePlan; preview: MergePreview } {
  void now
  const { source, target } = inputs
  if (source.id === target.id) throw new Error('Cannot merge a person into themselves.')

  const plan: WritePlan = []
  const preview: MergePreview = {
    interactionsMoved: 0,
    observationsMoved: 0,
    remindersMoved: 0,
    relationshipsRepointed: 0,
    pairsRemoved: 0,
  }

  for (const interaction of inputs.interactions) {
    if (!interaction.participantIDs.includes(source.id)) continue
    const participantIDs = [
      ...new Set(interaction.participantIDs.map((id) => (id === source.id ? target.id : id))),
    ]
    plan.push({ op: 'update', collection: 'interactions', id: interaction.id, data: { participantIDs } })
    preview.interactionsMoved += 1
  }

  for (const observation of inputs.observations) {
    if (observation.subjectID !== source.id) continue
    plan.push({ op: 'update', collection: 'observations', id: observation.id, data: { subjectID: target.id } })
    preview.observationsMoved += 1
  }

  for (const reminder of inputs.reminders) {
    if (!reminder.personIDs.includes(source.id)) continue
    const personIDs = [...new Set(reminder.personIDs.map((id) => (id === source.id ? target.id : id)))]
    plan.push({ op: 'update', collection: 'reminders', id: reminder.id, data: { personIDs } })
    preview.remindersMoved += 1
  }

  // Relationships, pair by pair. Canonical row: the one with the smaller id.
  const byID = new Map(inputs.relationships.map((r) => [r.id, r]))
  const keptPairKeys = new Set<string>()

  // Pairs that never touch the source are already in place — they claim their
  // keys first so a repointed duplicate collapses in their favor.
  const pairs: Array<[Relationship, Relationship]> = []
  for (const row of inputs.relationships) {
    if (row.id > row.reciprocalID) continue
    const reciprocal = byID.get(row.reciprocalID)
    if (!reciprocal) continue
    pairs.push([row, reciprocal])
  }
  const touchesSource = ([a, b]: [Relationship, Relationship]) =>
    a.subjectID === source.id || a.otherID === source.id || b.subjectID === source.id || b.otherID === source.id

  for (const pair of pairs) {
    if (touchesSource(pair)) continue
    keptPairKeys.add(pairKey(pair[0].subjectID, pair[0].otherID, pair[0].kind))
  }

  for (const pair of pairs) {
    if (!touchesSource(pair)) continue
    const [forward, backward] = pair
    const newSubject = forward.subjectID === source.id ? target.id : forward.subjectID
    const newOther = forward.otherID === source.id ? target.id : forward.otherID

    // A merge must not relate the target to themselves.
    if (newSubject === newOther) {
      plan.push({ op: 'delete', collection: 'relationships', id: forward.id })
      plan.push({ op: 'delete', collection: 'relationships', id: backward.id })
      preview.pairsRemoved += 1
      continue
    }

    const key = pairKey(newSubject, newOther, forward.kind)
    if (keptPairKeys.has(key)) {
      // The same relationship already exists on the target — collapse.
      plan.push({ op: 'delete', collection: 'relationships', id: forward.id })
      plan.push({ op: 'delete', collection: 'relationships', id: backward.id })
      preview.pairsRemoved += 1
      continue
    }
    keptPairKeys.add(key)

    plan.push({
      op: 'update',
      collection: 'relationships',
      id: forward.id,
      data: { subjectID: newSubject, otherID: newOther },
    })
    plan.push({
      op: 'update',
      collection: 'relationships',
      id: backward.id,
      data: { subjectID: newOther, otherID: newSubject },
    })
    preview.relationshipsRepointed += 1
  }

  // The source disappears only after every reference is rewritten above —
  // same plan, same batch.
  plan.push({ op: 'delete', collection: 'people', id: source.id })

  return { plan, preview }
}

// MARK: Comparison dismissal

/// "They are different" persists on the subject person as an optional field —
/// no new collection, nothing required on existing documents.
export function planDismissComparison(subject: Person & { dismissedComparisonKeys?: string[] }, key: string): WritePlan {
  const keys = [...new Set([...(subject.dismissedComparisonKeys ?? []), key])]
  return [{ op: 'update', collection: 'people', id: subject.id, data: { dismissedComparisonKeys: keys } }]
}
