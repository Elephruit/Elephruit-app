/// The AI review as an editable draft, not an approve/reject checklist. A
/// resolved capture becomes a draft of items referencing shared person slots;
/// every field the parser filled can be corrected through typed reducer
/// actions; and the write plan is built from the *edited* draft — the original
/// model proposal is never what gets saved. Pure: the reducer never mutates,
/// and the planner reuses the same capture planners as every other write path.

import { foldAttribute, type PersonSlot, type ResolvedCapture } from './assist'
import {
  planCreateReminder,
  planCompleteReminder,
  planDeleteReminder,
  planReopenReminder,
  planUpdateReminder,
  planInteractionBundle,
  planConfirmObservation,
  planCorrection,
  planObservation,
  planRelationshipPair,
  planUpdatePersonContext,
  planUnrelate,
  planRelativeCapture,
} from './capture'
import type { FactConfidence, FactSensitivity, Observation } from './facts'
import type { FactContext } from './facts'
import type { InteractionKind } from './interaction'
import { defaultMemoryTitle, planMemoryRecord, type MemoryRecord } from './memory'
import type { Person } from './person'
import type { Reminder } from './reminders'
import type { ReminderProgress } from './reminders'
import { kindLabel, type RelationshipKind } from './relationships'
import type { Relationship } from './relationships'
import {
  hasTemporalCue,
  resolveScheduleDraft,
  resolveProposedSchedule,
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
  context: FactContext
  observedOn: string
  effectiveOn: string
}

export interface PersonContextDraftItem extends DraftItemBase {
  type: 'personContext'
  subjectSlotID: string
  profileFocus: 'professional' | 'personal'
  roleTitle: string
  organizationName: string
  connectionStatus: 'met' | 'introductionPlanned' | 'unknown'
  firstMetOn: string
  context: string
  introducedBySlotID: string | null
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
  responsibility: 'mine' | 'theirs'
  progress: ReminderProgress
  /// The explicit "Save without date" override for the temporal safeguard.
  /// Transient review state only — never persisted.
  allowUnscheduled: boolean
}

export interface ReminderChangeDraftItem extends DraftItemBase {
  type: 'reminderChange'
  reminder: Reminder
  action: 'complete' | 'reopen' | 'delete' | 'update'
  progress: ReminderProgress
  notes: string
  responsibility: 'mine' | 'theirs'
}

export interface FactChangeDraftItem extends DraftItemBase {
  type: 'factChange'
  observation: Observation
  action: 'confirm' | 'correct'
  value: string
  correctionNote: string
  confidence: FactConfidence
  sensitivity: FactSensitivity
}

export interface RelationshipChangeDraftItem extends DraftItemBase {
  type: 'relationshipChange'
  relationship: Relationship
  action: 'remove'
}

export type ReviewDraftItem = InteractionDraftItem | PersonContextDraftItem | FactDraftItem | RelationshipDraftItem | FollowUpDraftItem | ReminderChangeDraftItem | FactChangeDraftItem | RelationshipChangeDraftItem

export interface ResolvedCaptureDraft {
  slots: PersonSlotEntry[]
  items: ReviewDraftItem[]
  warnings: string[]
  /// The memory's title — defaulted deterministically, editable in review.
  title: string
  /// True once the user edits the title; automatic recomputation stops.
  titleEdited: boolean
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
        {
        const parsed = item.occurredAt
          ? resolveProposedSchedule(item.occurredAt, { timeZone: item.occurredAt.timeZone ?? Intl.DateTimeFormat().resolvedOptions().timeZone }).dueAt
          : null
        items.push({
          id: item.id,
          removed: false,
          type: 'interaction',
          kind: item.kind,
          summary: item.summary,
          discussion: item.discussion ?? '',
          participantSlotIDs: item.participants.map(ensureSlot),
          occurredAt: parsed ?? now,
        })
        break
        }
      case 'personContext':
        items.push({
          id: item.id,
          removed: false,
          type: 'personContext',
          subjectSlotID: ensureSlot(item.person),
          profileFocus: item.profileFocus,
          roleTitle: item.roleTitle ?? '',
          organizationName: item.organizationName ?? '',
          connectionStatus: item.connectionStatus,
          firstMetOn: item.firstMetOn ?? '',
          context: item.context ?? '',
          introducedBySlotID: item.introducedBy ? ensureSlot(item.introducedBy) : null,
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
          sensitivity: item.sensitivity,
          context: item.context,
          observedOn: item.observedOn ?? '',
          effectiveOn: item.effectiveOn ?? '',
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
          responsibility: item.responsibility,
          progress: item.progress,
          allowUnscheduled: false,
        })
        break
      case 'reminderChange':
        items.push({
          id: item.id, removed: false, type: 'reminderChange', reminder: item.reminder, action: item.action,
          progress: item.progress ?? item.reminder.progress ?? 'notStarted',
          notes: item.notes ?? item.reminder.notes ?? '',
          responsibility: item.responsibility ?? item.reminder.responsibility ?? 'mine',
        })
        break
      case 'factChange':
        items.push({
          id: item.id, removed: false, type: 'factChange', observation: item.observation, action: item.action,
          value: item.value ?? item.observation.value, correctionNote: item.correctionNote ?? '',
          confidence: item.confidence ?? item.observation.confidence,
          sensitivity: item.sensitivity ?? item.observation.sensitivity,
        })
        break
      case 'relationshipChange':
        items.push({ id: item.id, removed: false, type: 'relationshipChange', relationship: item.relationship, action: 'remove' })
        break
    }
  }

  const draft: ResolvedCaptureDraft = {
    slots: [...slots.values()],
    items,
    warnings: resolved.warnings,
    title: '',
    titleEdited: false,
    revision: 0,
  }
  draft.title = computeDefaultTitle(draft)
  return draft
}

/// The deterministic default title from the draft's current shape.
export function computeDefaultTitle(draft: ResolvedCaptureDraft): string {
  const active = draft.items.filter((item) => !item.removed)
  const interaction = active.find((item) => item.type === 'interaction')
  const facts = active.filter((item) => item.type === 'fact')
  const personContexts = active.filter((item) => item.type === 'personContext')
  const relationships = active.filter((item) => item.type === 'relationship')
  const followUps = active.filter((item) => item.type === 'followUp')

  const referenced: Person[] = []
  for (const item of active) {
    const refs =
      item.type === 'interaction'
        ? item.participantSlotIDs
        : item.type === 'personContext'
          ? [item.subjectSlotID, ...(item.introducedBySlotID ? [item.introducedBySlotID] : [])]
        : item.type === 'fact'
          ? [item.subjectSlotID]
          : item.type === 'relationship'
            ? [item.subjectSlotID, ...(item.otherSlotID ? [item.otherSlotID] : [])]
            : item.type === 'followUp'
              ? item.personSlotIDs
              : []
    for (const slotID of refs) {
      const person = slotPerson(draft, slotID)
      if (person && !referenced.some((p) => p.id === person.id)) referenced.push(person)
    }
  }
  const created = referenced.filter((person) =>
    draft.slots.some((slot) => slot.resolution.person.id === person.id && slot.resolution.ref === 'create'),
  )

  const firstRelationship = relationships[0]
  let connectedPair: [Person, Person] | null = null
  if (firstRelationship && firstRelationship.type === 'relationship' && firstRelationship.otherSlotID) {
    const a = slotPerson(draft, firstRelationship.subjectSlotID)
    const b = slotPerson(draft, firstRelationship.otherSlotID)
    if (a && b) connectedPair = [a, b]
  }

  return defaultMemoryTitle({
    interactionSummary: interaction && interaction.type === 'interaction' ? interaction.summary : null,
    primaryPerson: referenced[0] ?? null,
    createdPeople: created,
    connectedPair: relationships.length > 0 && facts.length === 0 && followUps.length === 0 ? connectedPair : null,
    hasFacts: facts.length > 0 || personContexts.length > 0,
    hasRelationships: relationships.length > 0,
    followUpOnly: followUps.length > 0 && facts.length === 0 && relationships.length === 0 && !interaction,
  })
}

// MARK: Actions

export type ReviewDraftAction =
  | { type: 'update-interaction'; id: string; changes: Partial<Omit<InteractionDraftItem, 'id' | 'type' | 'removed'>> }
  | { type: 'update-fact'; id: string; changes: Partial<Omit<FactDraftItem, 'id' | 'type' | 'removed'>> }
  | { type: 'update-person-context'; id: string; changes: Partial<Omit<PersonContextDraftItem, 'id' | 'type' | 'removed'>> }
  | { type: 'update-relationship'; id: string; changes: Partial<Omit<RelationshipDraftItem, 'id' | 'type' | 'removed'>> }
  | { type: 'update-follow-up'; id: string; changes: Partial<Omit<FollowUpDraftItem, 'id' | 'type' | 'removed'>> }
  | { type: 'update-reminder-change'; id: string; changes: Partial<Pick<ReminderChangeDraftItem, 'action' | 'progress' | 'notes' | 'responsibility'>> }
  | { type: 'update-fact-change'; id: string; changes: Partial<Pick<FactChangeDraftItem, 'action' | 'value' | 'correctionNote' | 'confidence' | 'sensitivity'>> }
  | { type: 'update-title'; title: string }
  | { type: 'resolve-person'; slotID: string; resolution: PersonSlotResolution }
  | { type: 'add-person-slot'; slot: PersonSlotEntry }
  | { type: 'remove-item'; id: string }
  | { type: 'restore-item'; id: string }

export function reviewDraftReducer(draft: ResolvedCaptureDraft, action: ReviewDraftAction): ResolvedCaptureDraft {
  const bump = (next: Partial<ResolvedCaptureDraft>): ResolvedCaptureDraft => {
    const merged = { ...draft, ...next, revision: draft.revision + 1 }
    // An unedited title keeps tracking the draft's shape; the first manual
    // edit pins it.
    if (!merged.titleEdited && action.type !== 'update-title') {
      merged.title = computeDefaultTitle(merged)
    }
    return merged
  }

  switch (action.type) {
    case 'update-interaction':
    case 'update-person-context':
    case 'update-fact':
    case 'update-relationship':
    case 'update-follow-up':
    case 'update-reminder-change':
    case 'update-fact-change': {
      const expected =
        action.type === 'update-interaction'
          ? 'interaction'
          : action.type === 'update-person-context'
            ? 'personContext'
          : action.type === 'update-fact'
            ? 'fact'
            : action.type === 'update-relationship'
              ? 'relationship'
              : action.type === 'update-follow-up'
                ? 'followUp'
                : action.type === 'update-reminder-change'
                  ? 'reminderChange'
                  : 'factChange'
      return bump({
        items: draft.items.map((item) =>
          item.id === action.id && item.type === expected ? ({ ...item, ...action.changes } as ReviewDraftItem) : item,
        ),
      })
    }
    case 'update-title':
      return { ...draft, title: action.title, titleEdited: true, revision: draft.revision + 1 }
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
      case 'personContext':
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
      case 'reminderChange':
        break
      case 'factChange':
        if (item.action === 'correct' && !item.value.trim()) problems.push({ itemID: item.id, message: 'The corrected fact needs a value.', kind: 'field' })
        break
      case 'relationshipChange':
        break
    }
  }

  return problems
}

// MARK: The plan

/// The write plan from the *edited* draft, plus the one MemoryRecord that
/// makes the save feedable. Removed items plan nothing and the people only
/// they referenced are never created; the interaction's edited occurredAt
/// drives the record, the last-contact cache, and the memory's own time.
/// Every entity ID the plan schedules lands in the memory before the caller's
/// single atomic applyPlan — a partial memory is never committed. A save with
/// no active items returns an empty plan and no memory.
export function planFromReviewDraft(
  draft: ResolvedCaptureDraft,
  now: Date,
  temporal: TemporalContext,
): { plan: WritePlan; memory: MemoryRecord | null } {
  const active = activeItems(draft)
  if (active.length === 0) return { plan: [], memory: null }
  const plan: WritePlan = []

  const personIDs = new Set<string>()
  const observationIDs: string[] = []
  const relationshipIDs: string[] = []
  const reminderIDs: string[] = []

  const created = new Map<string, Person>()
  function ensureCreated(slotID: string): Person {
    const entry = slotByID(draft, slotID)
    if (!entry) throw new Error(`Draft references a missing person slot: ${slotID}`)
    const person = entry.resolution.person
    personIDs.add(person.id)
    if (entry.resolution.ref === 'existing') return person
    if (!created.has(person.id)) {
      created.set(person.id, person)
      plan.push({ op: 'set', collection: 'people', id: person.id, data: person })
    }
    return person
  }

  let interactionID: string | null = null
  let occurredAt = now

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
    occurredAt = bundle.interaction.occurredAt
    plan.push(...bundle.plan)
  }

  for (const item of active) {
    switch (item.type) {
      case 'interaction':
        break
      case 'fact': {
        const person = ensureCreated(item.subjectSlotID)
        const { plan: factPlan, observation } = planObservation(
          {
            subjectID: person.id,
            attribute: foldAttribute(item.attribute),
            value: item.value,
            confidence: item.confidence,
            sensitivity: item.sensitivity,
            context: item.context,
            observedOn: item.observedOn ? new Date(`${item.observedOn}T12:00:00`) : undefined,
            effectiveOn: item.effectiveOn ? new Date(`${item.effectiveOn}T12:00:00`) : null,
            sourceInteractionID: interactionID,
          },
          now,
        )
        observationIDs.push(observation.id)
        plan.push(...factPlan)
        break
      }
      case 'personContext': {
        const person = ensureCreated(item.subjectSlotID)
        const introducedBy = item.introducedBySlotID ? ensureCreated(item.introducedBySlotID) : null
        plan.push(
          ...planUpdatePersonContext(person, {
            profileFocus: item.profileFocus,
            roleTitle: item.roleTitle.trim() || null,
            organizationName: item.organizationName.trim() || null,
            connectionOrigin: {
              status: item.connectionStatus,
              firstMetOn: item.firstMetOn ? new Date(`${item.firstMetOn}T12:00:00`) : null,
              context: item.context.trim() || null,
              introducedByPersonID: introducedBy?.id ?? null,
            },
          }).plan,
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
          personIDs.add(capture.relative.id)
          relationshipIDs.push(capture.pair[0].id, capture.pair[1].id)
          // The relative's distinguishing facts ride in capture.plan; collect
          // their ids from the plan writes themselves.
          for (const write of capture.plan) {
            if (write.collection === 'observations' && write.op === 'set') observationIDs.push(write.id)
          }
          plan.push(...capture.plan)
        } else {
          const other = ensureCreated(item.otherSlotID)
          const { plan: pairPlan, pair } = planRelationshipPair(
            { subjectID: subject.id, otherID: other.id, kind: item.kind, customLabel: label },
            now,
          )
          relationshipIDs.push(pair[0].id, pair[1].id)
          plan.push(...pairPlan)
          for (const fact of item.facts) {
            if (!fact.value.trim()) continue
            const { plan: factPlan, observation } = planObservation(
              {
                subjectID: other.id,
                attribute: foldAttribute(fact.attribute),
                value: fact.value,
                sourceInteractionID: interactionID,
              },
              now,
            )
            observationIDs.push(observation.id)
            plan.push(...factPlan)
          }
        }
        break
      }
      case 'followUp': {
        const people = item.personSlotIDs.map(ensureCreated)
        const schedule = resolveScheduleDraft(item.schedule, temporal)
        const { plan: reminderPlan, reminder } = planCreateReminder(
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
            responsibility: item.responsibility,
            progress: item.progress,
          },
          now,
        )
        reminderIDs.push(reminder.id)
        plan.push(...reminderPlan)
        break
      }
      case 'reminderChange': {
        const changePlan = item.action === 'complete'
          ? planCompleteReminder(item.reminder.id, now)
          : item.action === 'delete'
            ? planDeleteReminder(item.reminder.id)
            : item.action === 'update'
              ? planUpdateReminder(item.reminder.id, { progress: item.progress, notes: item.notes.trim() || null, responsibility: item.responsibility })
            : planReopenReminder(item.reminder.id)
        reminderIDs.push(item.reminder.id)
        for (const personID of item.reminder.personIDs) personIDs.add(personID)
        plan.push(...changePlan.plan)
        break
      }
      case 'factChange': {
        personIDs.add(item.observation.subjectID)
        if (item.action === 'confirm') {
          plan.push(...planConfirmObservation(item.observation, now).plan)
        } else {
          const correction = planCorrection(item.observation, { value: item.value, confidence: item.confidence, sensitivity: item.sensitivity }, item.correctionNote || null, now)
          observationIDs.push(correction.observation.id)
          plan.push(...correction.plan)
        }
        break
      }
      case 'relationshipChange':
        personIDs.add(item.relationship.subjectID)
        personIDs.add(item.relationship.otherID)
        relationshipIDs.push(item.relationship.id, item.relationship.reciprocalID)
        plan.push(...planUnrelate(item.relationship).plan)
        break
    }
  }

  const { plan: memoryPlan, memory } = planMemoryRecord(
    {
      kind: interactionID ? 'interaction' : 'profileUpdate',
      title: draft.title,
      occurredAt,
      personIDs: [...personIDs],
      interactionID,
      observationIDs,
      relationshipIDs,
      reminderIDs,
      origin: 'capture',
    },
    now,
  )
  plan.push(...memoryPlan)

  return { plan, memory }
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
    case 'personContext': {
      const person = slotPerson(draft, item.subjectSlotID)
      return `${person?.displayName ?? 'Somebody'} · ${item.profileFocus === 'professional' ? 'Professional' : 'Personal'} profile`
    }
    case 'relationship': {
      const subject = slotPerson(draft, item.subjectSlotID)
      const other = item.otherSlotID ? slotPerson(draft, item.otherSlotID) : null
      const word = item.label.trim() || kindLabel(item.kind)
      return `${subject?.displayName ?? 'Somebody'} → ${word} → ${other?.displayName ?? 'unnamed'}`
    }
    case 'followUp':
      return item.title || (item.responsibility === 'theirs' ? 'Waiting on' : 'Follow-up')
    case 'reminderChange':
      return `${item.action === 'complete' ? 'Complete' : item.action === 'delete' ? 'Delete' : item.action === 'update' ? 'Update' : 'Reopen'} “${item.reminder.title}”`
    case 'factChange':
      return `${item.action === 'confirm' ? 'Confirm' : 'Correct'} ${item.observation.attribute}: ${item.value}`
    case 'relationshipChange':
      return `Remove ${kindLabel(item.relationship.kind)} relationship`
  }
}
