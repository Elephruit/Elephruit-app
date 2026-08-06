/// The feed's read model, pure: memory records join to their entities, and
/// everything from before memories existed is projected as synthetic legacy
/// moments — exactly once, with IDs stable across snapshots so live updates
/// cannot double-insert or replay entrance animations. No Firestore imports;
/// hooks feed this plain arrays and render what comes back.

import { excerptOf } from '../domain/timeline'
import { attributeLabel, type Observation } from '../domain/facts'
import { countsAsContact, provenancePhrase, type Interaction, type InteractionKind } from '../domain/interaction'
import { MEMORY_KIND_LABELS, type MemoryKind, type MemoryRecord } from '../domain/memory'
import type { Person } from '../domain/person'
import type { Relationship } from '../domain/relationships'
import type { Reminder } from '../domain/reminders'
import { kindLabel } from '../domain/relationships'
import type { SourceDocument } from '../domain/sources'

export interface MemoryMomentViewModel {
  id: string
  kind: MemoryKind
  title: string
  occurredAt: Date
  /// 'in person — logged', 'Profile update', 'Dossier import', …
  provenanceLabel: string
  interactionKind: InteractionKind | null
  /// Whether this moment represents actual contact (drives node tinting).
  isContact: boolean
  people: Person[]
  excerpt: string | null
  /// Inline learned details — the sparkle rows.
  details: Array<{ id: string; text: string }>
  relationships: Array<{ id: string; text: string }>
  followUps: Reminder[]
  /// 'From 2 files · 28 pages' for imports.
  sourceLine: string | null
  legacy: boolean
}

export interface ProjectionEntities {
  memories: MemoryRecord[]
  people: Person[]
  interactions: Interaction[]
  observations: Observation[]
  relationships: Relationship[]
  reminders: Reminder[]
  sources: SourceDocument[]
}

function relationshipText(relationship: Relationship, peopleByID: Map<string, Person>): string {
  const subject = peopleByID.get(relationship.subjectID)?.displayName ?? 'Somebody'
  const other = peopleByID.get(relationship.otherID)?.displayName ?? 'somebody'
  const word = relationship.customLabel ?? kindLabel(relationship.kind)
  return `${subject} → ${word} → ${other}`
}

/// One half of each relationship pair — the forward row when it carries the
/// user's word, else the row with the smaller id, so a pair renders once.
function dedupeRelationshipPairs(relationships: Relationship[]): Relationship[] {
  const byID = new Map(relationships.map((r) => [r.id, r]))
  return relationships.filter((relationship) => {
    const reciprocal = byID.get(relationship.reciprocalID)
    if (!reciprocal) return true
    if (relationship.customLabel && !reciprocal.customLabel) return true
    if (!relationship.customLabel && reciprocal.customLabel) return false
    return relationship.id < reciprocal.id
  })
}

export function projectMemories(entities: ProjectionEntities): MemoryMomentViewModel[] {
  const peopleByID = new Map(entities.people.map((p) => [p.id, p]))
  const interactionsByID = new Map(entities.interactions.map((i) => [i.id, i]))
  const observationsByID = new Map(entities.observations.map((o) => [o.id, o]))
  const relationshipsByID = new Map(entities.relationships.map((r) => [r.id, r]))
  const remindersByID = new Map(entities.reminders.map((r) => [r.id, r]))
  const sourcesByID = new Map(entities.sources.map((s) => [s.id, s]))

  return entities.memories.map((memory) => {
    const interaction = memory.interactionID ? interactionsByID.get(memory.interactionID) : null
    const observations = memory.observationIDs
      .map((id) => observationsByID.get(id))
      .filter((o): o is Observation => Boolean(o))
    const relationships = dedupeRelationshipPairs(
      memory.relationshipIDs.map((id) => relationshipsByID.get(id)).filter((r): r is Relationship => Boolean(r)),
    )
    const followUps = memory.reminderIDs.map((id) => remindersByID.get(id)).filter((r): r is Reminder => Boolean(r))
    const sources = memory.sourceDocumentIDs
      .map((id) => sourcesByID.get(id))
      .filter((s): s is SourceDocument => Boolean(s))
    const pageTotal = sources.reduce((sum, source) => sum + (source.pageCount ?? 0), 0)

    return {
      id: memory.id,
      kind: memory.kind,
      title: memory.title,
      occurredAt: memory.occurredAt,
      provenanceLabel: interaction
        ? provenancePhrase(interaction.provenance, interaction.kind)
        : MEMORY_KIND_LABELS[memory.kind],
      interactionKind: interaction?.kind ?? null,
      isContact: interaction ? countsAsContact(interaction.provenance) : false,
      people: memory.personIDs.map((id) => peopleByID.get(id)).filter((p): p is Person => Boolean(p)),
      excerpt: interaction ? excerptOf(interaction.discussion) : null,
      details: observations.map((o) => ({ id: o.id, text: `${attributeLabel(o.attribute)}: ${o.value}` })),
      relationships: relationships.map((r) => ({ id: r.id, text: relationshipText(r, peopleByID) })),
      followUps,
      sourceLine:
        sources.length > 0
          ? `From ${sources.length} file${sources.length === 1 ? '' : 's'}${pageTotal > 0 ? ` · ${pageTotal} pages` : ''}`
          : null,
      legacy: false,
    }
  })
}

/// Everything that predates memory records, projected exactly once. Entity
/// ids referenced by any real memory are excluded; synthetic moment ids
/// derive from entity type + id so snapshots keep them stable.
export function legacyMemoryProjection(entities: ProjectionEntities): MemoryMomentViewModel[] {
  const referenced = new Set<string>()
  for (const memory of entities.memories) {
    if (memory.interactionID) referenced.add(memory.interactionID)
    for (const id of memory.observationIDs) referenced.add(id)
    for (const id of memory.relationshipIDs) referenced.add(id)
    for (const id of memory.reminderIDs) referenced.add(id)
  }

  const peopleByID = new Map(entities.people.map((p) => [p.id, p]))
  const moments: MemoryMomentViewModel[] = []

  // Interactions carry their sourced observations and reminders with them.
  const legacyInteractions = entities.interactions.filter((i) => !referenced.has(i.id))
  const claimed = new Set<string>()
  for (const interaction of legacyInteractions) {
    const observations = entities.observations.filter(
      (o) => o.sourceInteractionID === interaction.id && !referenced.has(o.id),
    )
    const reminders = entities.reminders.filter(
      (r) => r.sourceInteractionID === interaction.id && !referenced.has(r.id),
    )
    for (const o of observations) claimed.add(o.id)
    for (const r of reminders) claimed.add(r.id)

    moments.push({
      id: `legacy-interaction-${interaction.id}`,
      kind: 'interaction',
      title: interaction.summary,
      occurredAt: interaction.occurredAt,
      provenanceLabel: provenancePhrase(interaction.provenance, interaction.kind),
      interactionKind: interaction.kind,
      isContact: countsAsContact(interaction.provenance),
      people: interaction.participantIDs.map((id) => peopleByID.get(id)).filter((p): p is Person => Boolean(p)),
      excerpt: excerptOf(interaction.discussion),
      details: observations.map((o) => ({ id: o.id, text: `${attributeLabel(o.attribute)}: ${o.value}` })),
      relationships: [],
      followUps: reminders,
      sourceLine: null,
      legacy: true,
    })
  }

  // Standalone facts — one quiet moment each. Superseded rows stay history.
  for (const observation of entities.observations) {
    if (referenced.has(observation.id) || claimed.has(observation.id)) continue
    if (observation.sourceInteractionID && entities.interactions.some((i) => i.id === observation.sourceInteractionID))
      continue
    if (observation.supersededOn !== null) continue
    const person = peopleByID.get(observation.subjectID)
    moments.push({
      id: `legacy-observation-${observation.id}`,
      kind: 'profileUpdate',
      title: person ? `Updated ${person.displayName}` : 'Updated a profile',
      occurredAt: observation.observedOn,
      provenanceLabel: MEMORY_KIND_LABELS.profileUpdate,
      interactionKind: null,
      isContact: false,
      people: person ? [person] : [],
      excerpt: null,
      details: [{ id: observation.id, text: `${attributeLabel(observation.attribute)}: ${observation.value}` }],
      relationships: [],
      followUps: [],
      sourceLine: null,
      legacy: true,
    })
  }

  // Standalone relationships, one moment per pair.
  const legacyRelationships = dedupeRelationshipPairs(
    entities.relationships.filter((r) => !referenced.has(r.id) && !referenced.has(r.reciprocalID)),
  )
  for (const relationship of legacyRelationships) {
    const subject = peopleByID.get(relationship.subjectID)
    const other = peopleByID.get(relationship.otherID)
    moments.push({
      id: `legacy-relationship-${relationship.id}`,
      kind: 'profileUpdate',
      title:
        subject && other ? `Connected ${subject.displayName} and ${other.displayName}` : 'Connected two people',
      occurredAt: relationship.createdAt,
      provenanceLabel: MEMORY_KIND_LABELS.profileUpdate,
      interactionKind: null,
      isContact: false,
      people: [subject, other].filter((p): p is Person => Boolean(p)),
      excerpt: null,
      details: [],
      relationships: [{ id: relationship.id, text: relationshipText(relationship, peopleByID) }],
      followUps: [],
      sourceLine: null,
      legacy: true,
    })
  }

  // Standalone reminders.
  for (const reminder of entities.reminders) {
    if (referenced.has(reminder.id) || claimed.has(reminder.id)) continue
    if (reminder.sourceInteractionID && entities.interactions.some((i) => i.id === reminder.sourceInteractionID))
      continue
    const first = reminder.personIDs.map((id) => peopleByID.get(id)).find(Boolean)
    moments.push({
      id: `legacy-reminder-${reminder.id}`,
      kind: 'profileUpdate',
      title: first ? `Added a follow-up for ${first.displayName}` : 'Added a follow-up',
      occurredAt: reminder.createdAt,
      provenanceLabel: MEMORY_KIND_LABELS.profileUpdate,
      interactionKind: null,
      isContact: false,
      people: reminder.personIDs.map((id) => peopleByID.get(id)).filter((p): p is Person => Boolean(p)),
      excerpt: null,
      details: [],
      relationships: [],
      followUps: [reminder],
      sourceLine: null,
      legacy: true,
    })
  }

  return moments
}

/// The feed: real memories plus the legacy projection, newest first.
export function projectFeed(entities: ProjectionEntities): MemoryMomentViewModel[] {
  return [...projectMemories(entities), ...legacyMemoryProjection(entities)].sort(
    (a, b) => b.occurredAt.getTime() - a.occurredAt.getTime(),
  )
}
