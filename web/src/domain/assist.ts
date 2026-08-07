/// AI capture proposes; it never writes. This module is the pure middle: it
/// takes a CaptureProposal (whatever parsed the dictation — the LLM lives
/// behind an interface, exactly the slot doc 37 reserved for a model-backed
/// parser), resolves names against the people who exist, folds attributes
/// through the curated registry, and turns the *user's confirmed selection*
/// into the same WritePlan every other capture path uses. No SDK imports; the
/// hygiene test watches this file too.

import {
  FactAttributes,
  customAttribute,
  type FactAttribute,
  type FactConfidence,
  type FactContext,
  type FactSensitivity,
  type Observation,
} from './facts'
import type { InteractionKind } from './interaction'
import { makePerson } from './capture'
import { foldedForMatching, type Person } from './person'
import type { Relationship, RelationshipKind } from './relationships'
import type { Reminder, ReminderProgress } from './reminders'
import type { ProposedSchedule } from './temporal'

// MARK: What the parser proposes

export interface ProposedInteraction {
  kind: InteractionKind
  summary: string
  discussion: string | null
  occurredAt?: ProposedSchedule | null
}

export interface ProposedFact {
  personName: string
  /// Free text from the parser; folded through customAttribute on resolution.
  attribute: string
  value: string
  confidence: FactConfidence
  sensitivity?: FactSensitivity
  context?: FactContext
  observedOn?: string | null
  effectiveOn?: string | null
}

export interface ProposedPersonContext {
  personName: string
  profileFocus: 'professional' | 'personal'
  roleTitle: string | null
  organizationName: string | null
  connectionStatus: 'met' | 'introductionPlanned' | 'unknown'
  firstMetOn: string | null
  context: string | null
  introducedByName: string | null
}

export interface ProposedRelationship {
  subjectName: string
  kind: RelationshipKind
  /// The speaker's word — "son". Stored as the label, never used to infer.
  label: string | null
  /// Null when the person was mentioned but not named.
  otherName: string | null
  facts: Array<{ attribute: string; value: string }>
}

export interface ProposedFollowUp {
  title: string
  personNames: string[]
  /// Optional so pre-schedule proposals (and their fixtures) stay valid; the
  /// wire schema always supplies both.
  notes?: string | null
  schedule?: ProposedSchedule
  responsibility?: 'mine' | 'theirs'
  progress?: ReminderProgress
}

export interface CaptureProposal {
  interaction: ProposedInteraction | null
  /// Who took part in the interaction, by name.
  participantNames: string[]
  personContexts?: ProposedPersonContext[]
  facts: ProposedFact[]
  relationships: ProposedRelationship[]
  followUps: ProposedFollowUp[]
  reminderChanges?: Array<{
    reminderID: string
    action: 'complete' | 'reopen' | 'delete' | 'update'
    progress?: ReminderProgress | null
    notes?: string | null
    responsibility?: 'mine' | 'theirs' | null
  }>
  factChanges?: Array<{
    observationID: string
    action: 'confirm' | 'correct'
    value: string | null
    correctionNote: string | null
    confidence: FactConfidence | null
    sensitivity: FactSensitivity | null
  }>
  relationshipChanges?: Array<{ relationshipID: string; action: 'remove' }>
}

// MARK: Resolution

/// A name resolved to a person: one who exists, or one the save will create.
/// Creation is deduplicated by folded name, so a fact about "Jack" and a
/// follow-up owed to "jack" agree on which Jack they mean.
export type PersonSlot =
  | { ref: 'existing'; person: Person }
  | { ref: 'create'; person: Person }

export type ResolvedItem =
  | {
      id: string
      type: 'interaction'
      kind: InteractionKind
      summary: string
      discussion: string | null
      participants: PersonSlot[]
      occurredAt: ProposedSchedule | null
    }
  | { id: string; type: 'relationshipChange'; relationship: Relationship; action: 'remove' }
  | {
      id: string
      type: 'personContext'
      person: PersonSlot
      profileFocus: 'professional' | 'personal'
      roleTitle: string | null
      organizationName: string | null
      connectionStatus: 'met' | 'introductionPlanned' | 'unknown'
      firstMetOn: string | null
      context: string | null
      introducedBy: PersonSlot | null
    }
  | {
      id: string
      type: 'fact'
      person: PersonSlot
      attribute: FactAttribute
      value: string
      confidence: FactConfidence
      sensitivity: FactSensitivity
      context: FactContext
      observedOn: string | null
      effectiveOn: string | null
    }
  | {
      id: string
      type: 'relationship'
      subject: PersonSlot
      kind: RelationshipKind
      label: string | null
      /// Null means an unnamed relative — a placeholder titled by the phrase.
      other: PersonSlot | null
      facts: Array<{ attribute: FactAttribute; value: string }>
    }
  | {
      id: string
      type: 'followUp'
      title: string
      people: PersonSlot[]
      notes: string | null
      schedule: ProposedSchedule
      responsibility: 'mine' | 'theirs'
      progress: ReminderProgress
    }
  | {
      id: string
      type: 'reminderChange'
      reminder: Reminder
      action: 'complete' | 'reopen' | 'delete' | 'update'
      progress: ReminderProgress | null
      notes: string | null
      responsibility: 'mine' | 'theirs' | null
    }
  | {
      id: string
      type: 'factChange'
      observation: Observation
      action: 'confirm' | 'correct'
      value: string | null
      correctionNote: string | null
      confidence: FactConfidence | null
      sensitivity: FactSensitivity | null
    }

export interface ResolvedCapture {
  items: ResolvedItem[]
  warnings: string[]
}

export function slotName(slot: PersonSlot): string {
  return slot.person.displayName
}

/// Free attribute text → the curated registry when it matches, quickFact when
/// it is nothing at all. Shared with the review-draft planner so edited
/// attribute text folds identically to parsed attribute text.
export function foldAttribute(text: string): FactAttribute {
  return customAttribute(text) ?? FactAttributes.quickFact
}

export function resolveProposal(
  proposal: CaptureProposal,
  existingPeople: Person[],
  now: Date,
  existing: { reminders?: Reminder[]; observations?: Observation[]; relationships?: Relationship[] } = {},
): ResolvedCapture {
  const warnings: string[] = []
  const pendingByName = new Map<string, Person>()

  function resolveName(rawName: string): PersonSlot {
    const folded = foldedForMatching(rawName)
    const matches = existingPeople.filter((p) => foldedForMatching(p.displayName) === folded)

    if (matches.length === 1) return { ref: 'existing', person: matches[0] }
    if (matches.length > 1) {
      // Never guess silently: pick the person most recently in touch and say so —
      // the review screen shows exactly who each item landed on.
      const picked = [...matches].sort(
        (a, b) => (b.lastContactAt?.getTime() ?? 0) - (a.lastContactAt?.getTime() ?? 0),
      )[0]
      warnings.push(`More than one person is named ${picked.displayName} — matched the one most recently in touch.`)
      return { ref: 'existing', person: picked }
    }

    const pending = pendingByName.get(folded)
    if (pending) return { ref: 'create', person: pending }
    const person = makePerson({ displayName: rawName.trim() }, now)
    pendingByName.set(folded, person)
    return { ref: 'create', person }
  }

  const items: ResolvedItem[] = []
  let index = 0
  const nextID = () => `item-${index++}`

  if (proposal.interaction && proposal.interaction.summary.trim()) {
    items.push({
      id: nextID(),
      type: 'interaction',
      kind: proposal.interaction.kind,
      summary: proposal.interaction.summary.trim(),
      discussion: proposal.interaction.discussion?.trim() || null,
      participants: proposal.participantNames.filter((n) => n.trim()).map(resolveName),
      occurredAt: proposal.interaction.occurredAt ?? null,
    })
  }

  const explicitContextNames = new Set<string>()
  for (const context of proposal.personContexts ?? []) {
    if (!context.personName.trim()) continue
    explicitContextNames.add(foldedForMatching(context.personName))
    items.push({
      id: nextID(),
      type: 'personContext',
      person: resolveName(context.personName),
      profileFocus: context.profileFocus,
      roleTitle: context.roleTitle?.trim() || null,
      organizationName: context.organizationName?.trim() || null,
      connectionStatus: context.connectionStatus,
      firstMetOn: context.firstMetOn,
      context: context.context?.trim() || null,
      introducedBy: context.introducedByName?.trim() ? resolveName(context.introducedByName) : null,
    })
  }

  // Work identity is both dated history and list-level identity. If an older
  // client/model returns role/employer facts without the newer personContexts
  // row, synthesize the editable profile proposal so those facts do not leave
  // a newly-created professional person looking blank in People.
  const professionalByName = new Map<string, { name: string; roleTitle: string | null; organizationName: string | null }>()
  for (const fact of proposal.facts) {
    const attribute = foldAttribute(fact.attribute)
    if (attribute !== FactAttributes.role && attribute !== FactAttributes.employer) continue
    const key = foldedForMatching(fact.personName)
    const current = professionalByName.get(key) ?? { name: fact.personName, roleTitle: null, organizationName: null }
    if (attribute === FactAttributes.role) current.roleTitle = fact.value.trim() || null
    if (attribute === FactAttributes.employer) current.organizationName = fact.value.trim() || null
    professionalByName.set(key, current)
  }
  for (const [key, identity] of professionalByName) {
    if (explicitContextNames.has(key)) continue
    items.push({
      id: nextID(),
      type: 'personContext',
      person: resolveName(identity.name),
      profileFocus: 'professional',
      roleTitle: identity.roleTitle,
      organizationName: identity.organizationName,
      connectionStatus: 'unknown',
      firstMetOn: null,
      context: null,
      introducedBy: null,
    })
  }

  for (const fact of proposal.facts) {
    if (!fact.value.trim() || !fact.personName.trim()) continue
    items.push({
      id: nextID(),
      type: 'fact',
      person: resolveName(fact.personName),
      attribute: foldAttribute(fact.attribute),
      value: fact.value.trim(),
      confidence: fact.confidence,
      sensitivity: fact.sensitivity ?? 'normal',
      context: fact.context ?? 'personal',
      observedOn: fact.observedOn ?? null,
      effectiveOn: fact.effectiveOn ?? null,
    })
  }

  for (const relationship of proposal.relationships) {
    if (!relationship.subjectName.trim()) continue
    items.push({
      id: nextID(),
      type: 'relationship',
      subject: resolveName(relationship.subjectName),
      kind: relationship.kind,
      label: relationship.label?.trim() || null,
      other: relationship.otherName?.trim() ? resolveName(relationship.otherName) : null,
      facts: relationship.facts
        .filter((f) => f.value.trim())
        .map((f) => ({ attribute: foldAttribute(f.attribute), value: f.value.trim() })),
    })
  }

  for (const followUp of proposal.followUps) {
    if (!followUp.title.trim()) continue
    items.push({
      id: nextID(),
      type: 'followUp',
      title: followUp.title.trim(),
      people: followUp.personNames.filter((n) => n.trim()).map(resolveName),
      notes: followUp.notes?.trim() || null,
      schedule: followUp.schedule ?? {
        mode: 'none',
        localDate: null,
        localTime: null,
        timeZone: null,
        sourceText: null,
        confidence: 'stated',
      },
      responsibility: followUp.responsibility ?? 'mine',
      progress: followUp.progress ?? 'notStarted',
    })
  }

  for (const change of proposal.reminderChanges ?? []) {
    const reminder = existing.reminders?.find((candidate) => candidate.id === change.reminderID)
    if (!reminder) {
      warnings.push('A requested follow-up change could not be matched. It was not saved.')
      continue
    }
    items.push({
      id: nextID(), type: 'reminderChange', reminder, action: change.action,
      progress: change.progress ?? null, notes: change.notes?.trim() || null,
      responsibility: change.responsibility ?? null,
    })
  }

  for (const change of proposal.factChanges ?? []) {
    const observation = existing.observations?.find((candidate) => candidate.id === change.observationID)
    if (!observation) {
      warnings.push('A requested fact change could not be matched. It was not saved.')
      continue
    }
    items.push({ id: nextID(), type: 'factChange', observation, ...change })
  }

  for (const change of proposal.relationshipChanges ?? []) {
    const relationship = existing.relationships?.find((candidate) => candidate.id === change.relationshipID)
    if (!relationship) {
      warnings.push('A requested relationship change could not be matched. It was not saved.')
      continue
    }
    items.push({ id: nextID(), type: 'relationshipChange', relationship, action: change.action })
  }

  return { items, warnings }
}
