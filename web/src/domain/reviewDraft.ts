/// The AI review as an editable draft, not an approve/reject checklist. A
/// resolved capture becomes a draft of items referencing shared person slots;
/// every field the parser filled can be corrected through typed reducer
/// actions; and the write plan is built from the *edited* draft — the original
/// model proposal is never what gets saved. Pure: the reducer never mutates,
/// and the planner reuses the same capture planners as every other write path.

import { foldAttribute, type PersonSlot, type ResolvedCapture } from './assist'
import {
  planCreateReminder,
  planInteractionBundle,
  planObservation,
  planRelationshipPair,
  planRelativeCapture,
} from './capture'
import type { FactConfidence, FactSensitivity } from './facts'
import type { InteractionKind } from './interaction'
import type { Person } from './person'
import { kindLabel, type RelationshipKind } from './relationships'
import {
  hasTemporalCue,
  resolveScheduleDraft,
  validateScheduleDraft,
  type ScheduleDraftFields,
  type TemporalContext,
} from './temporal'
import type { WritePlan } from './writePlan'

// MARK: Person slots

/// One mentioned person, shared by every draft item that references them —
/// remapping "Kelly" to an existing record updates the interaction, the facts,
/// and the follow-up at once because they all point at the same slot.
export type PersonSlotResolution =
  | { ref: 'existing'; person: Person }
  | { ref: 'create'; person: Person }

export interface PersonSlotEntry {
  slotID: string
  resolution: PersonSlotResolution
  /// What the parser heard, kept for display while remapping.
  proposedName: string
}

// MARK: Draft items

interface DraftItemBase {
  id: string
  removed: boolean
}

export interface InteractionDraftItem extends DraftItemBase {
  type: 'interaction'
  kind: InteractionKind
  summary: string
  discussion: string
  participantSlotIDs: string[]
  occurredAt: Date
}

export interface FactDraftItem extends DraftItemBase {
  type: 'fact'
  subjectSlotID: string
  /// Editable text; folded through the curated registry at plan time.
  attribute: string
  value: string
  confidence: FactConfidence
  sensitivity: FactSensitivity
}

export interface RelationshipDraftItem extends DraftItemBase {
  type: 'relationship'
  subjectSlotID: string
  kind: RelationshipKind
  /// The user's word — "son". Empty means none.
  label: string
  /// Null means the other person is unnamed; a placeholder titled by the
  /// phrase is created on save.
  otherSlotID: string | null
  facts: Array<{ attribute: string; value: string }>
}

export interface FollowUpDraftItem extends DraftItemBase {
  type: 'followUp'
  title: string
  notes: string
  personSlotIDs: string[]
  schedule: ScheduleDraftFields
  scheduleSource: string | null
  scheduleConfidence: 'stated' | 'inferred' | 'uncertain'
  /// The explicit "Save without date" override for the temporal safeguard.
  /// Transient review state only — never persisted.
  allowUnscheduled: boolean
}

export type ReviewDraftItem = InteractionDraftItem | FactDraftItem | RelationshipDraftItem | FollowUpDraftItem

export interface ResolvedCaptureDraft {
  slots: PersonSlotEntry[]
  items: ReviewDraftItem[]
  warnings: string[]
  revision: number
}

// MARK: Building the draft

function slotKey(slot: PersonSlot): string {
  return slot.person.id
}

/// ResolvedCapture → editable draft. Slot identity comes from resolution:
/// items that resolved to the same person share one slot.
export function draftFromResolved(resolved: ResolvedCapture, now: Date): ResolvedCaptureDraft {
  const slots = new Map<string, PersonSlotEntry>()

  function ensureSlot(slot: PersonSlot): string {
    const id = slotKey(slot)
    if (!slots.has(id)) {
      slots.set(id, {
        slotID: id,
        resolution: slot.ref === 'existing' ? { ref: 'existing', person: slot.person } : { ref: 'create', person: slot.person },
        proposedName: slot.person.displayName,
      })
    }
    return id
  }

  const items: ReviewDraftItem[] = []
  for (const item of resolved.items) {
    switch (item.type) {
      case 'interaction':
        items.push({
          id: item.id,
          removed: false,
          type: 'interaction',
          kind: item.kind,
          summary: item.summary,
          discussion: item.discussion ?? '',
          participantSlotIDs: item.participants.map(ensureSlot),
          occurredAt: now,
        })
        break
      case 'fact':
        items.push({
          id: item.id,
          removed: false,
          type: 'fact',
          subjectSlotID: ensureSlot(item.person),
          attribute: item.attribute,
          value: item.value,
          confidence: item.confidence,
          sensitivity: 'normal',
        })
        break
      case 'relationship':
        items.push({
          id: item.id,
          removed: false,
          type: 'relationship',
          subjectSlotID: ensureSlot(item.subject),
          kind: item.kind,
          label: item.label ?? '',
          otherSlotID: item.other ? ensureSlot(item.other) : null,
          facts: item.facts.map((f) => ({ attribute: f.attribute, value: f.value })),
        })
        break
      case 'followUp':
        items.push({
          id: item.id,
          removed: false,
          type: 'followUp',
          title: item.title,
          notes: item.notes ?? '',
          personSlotIDs: item.people.map(ensureSlot),
          schedule: {
            scheduleMode: item.schedule.mode,
            localDate: item.schedule.localDate ?? '',
            localTime: item.schedule.localTime ?? '',
            timeZone: item.schedule.timeZone ?? '',
          },
          scheduleSource: item.schedule.sourceText,
          scheduleConfidence: item.schedule.confidence,
          allowUnscheduled: false,
        })
        break
    }
  }

  return { slots: [...slots.values()], items, warnings: resolved.warnings, revision: 0 }
}

// MARK: Actions

export type ReviewDraftAction =
  | { type: 'update-interaction'; id: string; changes: Partial<Omit<InteractionDraftItem, 'id' | 'type' | 'removed'>> }
  | { type: 'update-fact'; id: string; changes: Partial<Omit<FactDraftItem, 'id' | 'type' | 'removed'>> }
  | { type: 'update-relationship'; id: string; changes: Partial<Omit<RelationshipDraftItem, 'id' | 'type' | 'removed'>> }
  | { type: 'update-follow-up'; id: string; changes: Partial<Omit<FollowUpDraftItem, 'id' | 'type' | 'removed'>> }
  | { type: 'resolve-person'; slotID: string; resolution: PersonSlotResolution }
  | { type: 'add-person-slot'; slot: PersonSlotEntry }
  | { type: 'remove-item'; id: string }
  | { type: 'restore-item'; id: string }

export function reviewDraftReducer(draft: ResolvedCaptureDraft, action: ReviewDraftAction): ResolvedCaptureDraft {
  const bump = (next: Partial<ResolvedCaptureDraft>): ResolvedCaptureDraft => ({
    ...draft,
    ...next,
    revision: draft.revision + 1,
  })

  switch (action.type) {
    case 'update-interaction':
    case 'update-fact':
    case 'update-relationship':
    case 'update-follow-up': {
      const expected =
        action.type === 'update-interaction'
          ? 'interaction'
          : action.type === 'update-fact'
            ? 'fact'
            : action.type === 'update-relationship'
              ? 'relationship'
              : 'followUp'
      return bump({
        items: draft.items.map((item) =>
          item.id === action.id && item.type === expected ? ({ ...item, ...action.changes } as ReviewDraftItem) : item,
        ),
      })
    }
    case 'resolve-person':
      return bump({
        slots: draft.slots.map((slot) =>
          slot.slotID === action.slotID ? { ...slot, resolution: action.resolution } : slot,
        ),
      })
    case 'add-person-slot':
      if (draft.slots.some((slot) => slot.slotID === action.slot.slotID)) return draft
      return bump({ slots: [...draft.slots, action.slot] })
    case 'remove-item':
      return bump({
        items: draft.items.map((item) => (item.id === action.id ? { ...item, removed: true } : item)),
      })
    case 'restore-item':
      return bump({
        items: draft.items.map((item) => (item.id === action.id ? { ...item, removed: false } : item)),
      })
  }
}

// MARK: Validation

export interface DraftProblem {
  itemID: string
  message: string
  /// Temporal problems carry their own affordances (Add date / Save without
  /// date); field problems just block until corrected.
  kind: 'field' | 'temporal'
}

export function slotByID(draft: ResolvedCaptureDraft, slotID: string): PersonSlotEntry | undefined {
  return draft.slots.find((slot) => slot.slotID === slotID)
}

export function slotPerson(draft: ResolvedCaptureDraft, slotID: string): Person | undefined {
  return slotByID(draft, slotID)?.resolution.person
}

export function activeItems(draft: ResolvedCaptureDraft): ReviewDraftItem[] {
  return draft.items.filter((item) => !item.removed)
}

export function validateDraft(draft: ResolvedCaptureDraft): DraftProblem[] {
  const problems: DraftProblem[] = []
  const active = activeItems(draft)

  const seenPairs = new Set<string>()

  for (const item of active) {
    switch (item.type) {
      case 'interaction':
        if (!item.summary.trim()) problems.push({ itemID: item.id, message: 'The interaction needs a summary.', kind: 'field' })
        if (item.participantSlotIDs.length === 0)
          problems.push({ itemID: item.id, message: 'Add at least one participant.', kind: 'field' })
        break
      case 'fact':
        if (!item.value.trim()) problems.push({ itemID: item.id, message: 'The fact needs a value.', kind: 'field' })
        break
      case 'relationship': {
        if (item.otherSlotID !== null) {
          const subject = slotPerson(draft, item.subjectSlotID)
          const other = slotPerson(draft, item.otherSlotID)
          if (subject && other && subject.id === other.id)
            problems.push({ itemID: item.id, message: 'A person cannot be related to themselves.', kind: 'field' })
          const pairKey = [item.subjectSlotID, item.otherSlotID, item.kind].join('→')
          if (seenPairs.has(pairKey))
            problems.push({ itemID: item.id, message: 'This relationship is already in the review.', kind: 'field' })
          seenPairs.add(pairKey)
        }
        break
      }
      case 'followUp': {
        if (!item.title.trim()) problems.push({ itemID: item.id, message: 'The follow-up needs a title.', kind: 'field' })
        const fieldError = validateScheduleDraft(item.schedule)
        if (fieldError) problems.push({ itemID: item.id, message: fieldError, kind: 'field' })
        if (
          item.schedule.scheduleMode === 'none' &&
          !item.allowUnscheduled &&
          hasTemporalCue(`${item.title} ${item.notes}`)
        ) {
          problems.push({
            itemID: item.id,
            message: 'This sounds scheduled, but no date was captured.',
            kind: 'temporal',
          })
        }
        break
      }
    }
  }

  return problems
}

// MARK: The plan

/// The write plan from the *edited* draft. Removed items plan nothing and the
/// people only they referenced are never created; the interaction's edited
/// occurredAt drives both the record and the last-contact cache.
export function planFromReviewDraft(
  draft: ResolvedCaptureDraft,
  now: Date,
  temporal: TemporalContext,
): WritePlan {
  const active = activeItems(draft)
  const plan: WritePlan = []

  const created = new Map<string, Person>()
  function ensureCreated(slotID: string): Person {
    const entry = slotByID(draft, slotID)
    if (!entry) throw new Error(`Draft references a missing person slot: ${slotID}`)
    if (entry.resolution.ref === 'existing') return entry.resolution.person
    const person = entry.resolution.person
    if (!created.has(person.id)) {
      created.set(person.id, person)
      plan.push({ op: 'set', collection: 'people', id: person.id, data: person })
    }
    return person
  }

  let interactionID: string | null = null

  const interaction = active.find((item) => item.type === 'interaction')
  if (interaction && interaction.type === 'interaction') {
    const participants = interaction.participantSlotIDs.map(ensureCreated)
    const bundle = planInteractionBundle(
      {
        kind: interaction.kind,
        participantIDs: participants.map((p) => p.id),
        summary: interaction.summary,
        discussion: interaction.discussion,
        followUps: '',
        occurredAt: interaction.occurredAt,
      },
      participants,
      now,
    )
    interactionID = bundle.interaction.id
    plan.push(...bundle.plan)
  }

  for (const item of active) {
    switch (item.type) {
      case 'interaction':
        break
      case 'fact': {
        const person = ensureCreated(item.subjectSlotID)
        plan.push(
          ...planObservation(
            {
              subjectID: person.id,
              attribute: foldAttribute(item.attribute),
              value: item.value,
              confidence: item.confidence,
              sensitivity: item.sensitivity,
              sourceInteractionID: interactionID,
            },
            now,
          ).plan,
        )
        break
      }
      case 'relationship': {
        const subject = ensureCreated(item.subjectSlotID)
        const label = item.label.trim() || null
        if (item.otherSlotID === null) {
          const capture = planRelativeCapture(
            subject,
            {
              kind: item.kind,
              label,
              name: null,
              facts: item.facts.map((f) => ({ attribute: foldAttribute(f.attribute), value: f.value })),
              sourceInteractionID: interactionID,
            },
            now,
          )
          plan.push(...capture.plan)
        } else {
          const other = ensureCreated(item.otherSlotID)
          plan.push(
            ...planRelationshipPair(
              { subjectID: subject.id, otherID: other.id, kind: item.kind, customLabel: label },
              now,
            ).plan,
          )
          for (const fact of item.facts) {
            if (!fact.value.trim()) continue
            plan.push(
              ...planObservation(
                {
                  subjectID: other.id,
                  attribute: foldAttribute(fact.attribute),
                  value: fact.value,
                  sourceInteractionID: interactionID,
                },
                now,
              ).plan,
            )
          }
        }
        break
      }
      case 'followUp': {
        const people = item.personSlotIDs.map(ensureCreated)
        const schedule = resolveScheduleDraft(item.schedule, temporal)
        plan.push(
          ...planCreateReminder(
            {
              title: item.title,
              notes: item.notes || null,
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

// MARK: Display

/// A one-line reading of an item for the collapsed row and the removed state.
export function draftItemSummary(draft: ResolvedCaptureDraft, item: ReviewDraftItem): string {
  switch (item.type) {
    case 'interaction':
      return item.summary || 'Interaction'
    case 'fact': {
      const person = slotPerson(draft, item.subjectSlotID)
      return `${item.attribute}: ${item.value}${person ? ` — ${person.displayName}` : ''}`
    }
    case 'relationship': {
      const subject = slotPerson(draft, item.subjectSlotID)
      const other = item.otherSlotID ? slotPerson(draft, item.otherSlotID) : null
      const word = item.label.trim() || kindLabel(item.kind)
      return `${subject?.displayName ?? 'Somebody'} → ${word} → ${other?.displayName ?? 'unnamed'}`
    }
    case 'followUp':
      return item.title || 'Follow-up'
  }
}
