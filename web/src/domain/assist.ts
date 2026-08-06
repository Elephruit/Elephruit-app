/// AI capture proposes; it never writes. This module is the pure middle: it
/// takes a CaptureProposal (whatever parsed the dictation — the LLM lives
/// behind an interface, exactly the slot doc 37 reserved for a model-backed
/// parser), resolves names against the people who exist, folds attributes
/// through the curated registry, and turns the *user's confirmed selection*
/// into the same WritePlan every other capture path uses. No SDK imports; the
/// hygiene test watches this file too.

import { planCreateReminder, planInteractionBundle, planObservation, planRelationshipPair, planRelativeCapture } from './capture'
import { FactAttributes, customAttribute, type FactAttribute, type FactConfidence } from './facts'
import type { InteractionKind } from './interaction'
import { makePerson } from './capture'
import { foldedForMatching, type Person } from './person'
import type { RelationshipKind } from './relationships'
import { resolveProposedSchedule, type ProposedSchedule, type TemporalContext } from './temporal'
import type { WritePlan } from './writePlan'

// MARK: What the parser proposes

export interface ProposedInteraction {
  kind: InteractionKind
  summary: string
  discussion: string | null
}

export interface ProposedFact {
  personName: string
  /// Free text from the parser; folded through customAttribute on resolution.
  attribute: string
  value: string
  confidence: FactConfidence
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
}

export interface CaptureProposal {
  interaction: ProposedInteraction | null
  /// Who took part in the interaction, by name.
  participantNames: string[]
  facts: ProposedFact[]
  relationships: ProposedRelationship[]
  followUps: ProposedFollowUp[]
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
    }
  | { id: string; type: 'fact'; person: PersonSlot; attribute: FactAttribute; value: string; confidence: FactConfidence }
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
    }

export interface ResolvedCapture {
  items: ResolvedItem[]
  warnings: string[]
}

export function slotName(slot: PersonSlot): string {
  return slot.person.displayName
}

function foldAttribute(text: string): FactAttribute {
  return customAttribute(text) ?? FactAttributes.quickFact
}

export function resolveProposal(proposal: CaptureProposal, existingPeople: Person[], now: Date): ResolvedCapture {
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
    })
  }

  return { items, warnings }
}

// MARK: From confirmed selection to the one write path

/// Builds the plan for exactly the items the user kept. People pending creation
/// are written once no matter how many kept items reference them; people only
/// referenced by discarded items are never created at all. `temporal` supplies
/// the user's zone for schedule resolution — callers must pass the real one;
/// the UTC default exists only for schedule-free fixtures.
export function planFromResolved(
  items: ResolvedItem[],
  keptIDs: Set<string>,
  now: Date,
  temporal: TemporalContext = { timeZone: 'UTC' },
): WritePlan {
  const kept = items.filter((item) => keptIDs.has(item.id))
  const plan: WritePlan = []

  const created = new Map<string, Person>()
  function ensureCreated(slot: PersonSlot): Person {
    if (slot.ref === 'existing') return slot.person
    if (!created.has(slot.person.id)) {
      created.set(slot.person.id, slot.person)
      plan.push({ op: 'set', collection: 'people', id: slot.person.id, data: slot.person })
    }
    return slot.person
  }

  let interactionID: string | null = null

  const interaction = kept.find((item) => item.type === 'interaction')
  if (interaction && interaction.type === 'interaction') {
    const participants = interaction.participants.map(ensureCreated)
    const bundle = planInteractionBundle(
      {
        kind: interaction.kind,
        participantIDs: participants.map((p) => p.id),
        summary: interaction.summary,
        discussion: interaction.discussion ?? '',
        followUps: '',
        occurredAt: now,
      },
      participants,
      now,
    )
    interactionID = bundle.interaction.id
    plan.push(...bundle.plan)
  }

  for (const item of kept) {
    switch (item.type) {
      case 'interaction':
        break
      case 'fact': {
        const person = ensureCreated(item.person)
        plan.push(
          ...planObservation(
            {
              subjectID: person.id,
              attribute: item.attribute,
              value: item.value,
              confidence: item.confidence,
              sourceInteractionID: interactionID,
            },
            now,
          ).plan,
        )
        break
      }
      case 'relationship': {
        const subject = ensureCreated(item.subject)
        if (item.other === null) {
          const capture = planRelativeCapture(
            subject,
            { kind: item.kind, label: item.label, name: null, facts: item.facts, sourceInteractionID: interactionID },
            now,
          )
          plan.push(...capture.plan)
        } else {
          const other = ensureCreated(item.other)
          plan.push(
            ...planRelationshipPair(
              { subjectID: subject.id, otherID: other.id, kind: item.kind, customLabel: item.label },
              now,
            ).plan,
          )
          for (const fact of item.facts) {
            plan.push(
              ...planObservation(
                { subjectID: other.id, attribute: fact.attribute, value: fact.value, sourceInteractionID: interactionID },
                now,
              ).plan,
            )
          }
        }
        break
      }
      case 'followUp': {
        const people = item.people.map(ensureCreated)
        const schedule = resolveProposedSchedule(item.schedule, temporal)
        plan.push(
          ...planCreateReminder(
            {
              title: item.title,
              notes: item.notes,
              personIDs: people.map((p) => p.id),
              sourceInteractionID: interactionID,
              startAt: schedule.startAt,
              dueAt: schedule.dueAt,
              isSomeday: schedule.isSomeday,
              scheduleTimeZone: schedule.scheduleTimeZone,
              duePrecision: schedule.duePrecision,
              startPrecision: schedule.startPrecision,
            },
            now,
          ).plan,
        )
        break
      }
    }
  }

  return plan
}
