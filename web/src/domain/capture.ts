/// Every way anything gets written — manual composer, fact editor, relationship
/// sheet, AI review screen — builds its writes here and hands one WritePlan to
/// the single executor. Nothing about reciprocals, supersede chains, placeholder
/// titles, or the last-contact cache is implemented twice. This is the web
/// analogue of the Mac app's decision D5: one capture value type, one atomic
/// apply, and a platform-specific write path is a review failure.

import type { FactAttribute, FactConfidence, FactSensitivity, Observation } from './facts'
import { newID } from './ids'
import type { Interaction, InteractionKind } from './interaction'
import { nameParts, paletteColorFor, type Person } from './person'
import { possessivePhrase, relationshipPair, type Relationship, type RelationshipKind } from './relationships'
import type { Reminder } from './reminders'
import type { WritePlan } from './writePlan'

// MARK: People

export interface PersonDraft {
  displayName: string
  roleTitle?: string | null
  organizationName?: string | null
  isPlaceholder?: boolean
  hasStatedName?: boolean
}

export function makePerson(draft: PersonDraft, now: Date): Person {
  const displayName = draft.displayName.trim()
  const stated = draft.hasStatedName ?? true
  const parts = stated ? nameParts(displayName) : { givenName: null, familyName: null }
  return {
    id: newID(),
    displayName,
    givenName: parts.givenName,
    familyName: parts.familyName,
    roleTitle: draft.roleTitle?.trim() || null,
    organizationName: draft.organizationName?.trim() || null,
    colorName: paletteColorFor(displayName),
    isPlaceholder: draft.isPlaceholder ?? false,
    hasStatedName: stated,
    createdAt: now,
    lastContactAt: null,
  }
}

export function planCreatePerson(draft: PersonDraft, now: Date): { plan: WritePlan; person: Person } {
  const person = makePerson(draft, now)
  return { plan: [{ op: 'set', collection: 'people', id: person.id, data: person }], person }
}

/// Naming somebody who was recorded before their name was known. One field, one
/// tap — and every fact and relationship they accumulated stays attached, because
/// the record was first-class all along.
export function planNamePerson(person: Person, name: string, now: Date): { plan: WritePlan } {
  void now
  const displayName = name.trim()
  const parts = nameParts(displayName)
  return {
    plan: [
      {
        op: 'update',
        collection: 'people',
        id: person.id,
        data: {
          displayName,
          givenName: parts.givenName,
          familyName: parts.familyName,
          hasStatedName: true,
          isPlaceholder: false,
        },
      },
    ],
  }
}

/// Renaming somebody refreshes the phrase-titles of unnamed relatives around
/// them in the same plan — "Dave's son" must survive Dave becoming "David".
/// The stale-phrase cost of storing derived titles, paid where it belongs.
export function planRenamePerson(
  person: Person,
  newName: string,
  relationshipsFromPerson: Relationship[],
  peopleByID: Map<string, Person>,
  now: Date,
): { plan: WritePlan } {
  const { plan } = planNamePerson(person, newName, now)
  const displayName = newName.trim()

  for (const relationship of relationshipsFromPerson) {
    if (relationship.subjectID !== person.id) continue
    const relative = peopleByID.get(relationship.otherID)
    if (!relative || relative.hasStatedName) continue
    plan.push({
      op: 'update',
      collection: 'people',
      id: relative.id,
      data: { displayName: possessivePhrase(displayName, relationship.kind, relationship.customLabel) },
    })
  }
  return { plan }
}

// MARK: Interactions

export interface InteractionDraft {
  kind: InteractionKind
  participantIDs: string[]
  summary: string
  discussion: string
  /// One follow-up per line; blank lines are nothing, not errors.
  followUps: string
  occurredAt: Date
}

export function emptyInteractionDraft(now: Date): InteractionDraft {
  return { kind: 'in-person', participantIDs: [], summary: '', discussion: '', followUps: '', occurredAt: now }
}

export function parseActionLines(text: string): string[] {
  return text
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line.length > 0)
}

export function draftIsValid(draft: InteractionDraft): boolean {
  return draft.summary.trim().length > 0 && draft.participantIDs.length > 0
}

/// One interaction linked to every attendee, one linked reminder per follow-up
/// line, and the last-contact cache moved forward for each participant — in one
/// plan, so a conference call is one record on N pages and the cache can never
/// drift from the write that justified it.
export function planInteractionBundle(
  draft: InteractionDraft,
  participants: Person[],
  now: Date,
): { plan: WritePlan; interaction: Interaction; reminders: Reminder[] } {
  if (!draftIsValid(draft)) {
    throw new Error('An interaction needs a summary and at least one participant.')
  }

  const participantIDs = [...new Set(draft.participantIDs)]
  const interaction: Interaction = {
    id: newID(),
    kind: draft.kind,
    provenance: 'logged',
    summary: draft.summary.trim(),
    discussion: draft.discussion.trim() || null,
    participantIDs,
    occurredAt: draft.occurredAt,
    createdAt: now,
  }

  const plan: WritePlan = [{ op: 'set', collection: 'interactions', id: interaction.id, data: interaction }]

  const reminders: Reminder[] = parseActionLines(draft.followUps).map((title) => ({
    id: newID(),
    title,
    notes: null,
    personIDs: participantIDs,
    sourceInteractionID: interaction.id,
    startAt: null,
    dueAt: null,
    isSomeday: false,
    status: 'open' as const,
    completedAt: null,
    createdAt: now,
  }))
  for (const reminder of reminders) {
    plan.push({ op: 'set', collection: 'reminders', id: reminder.id, data: reminder })
  }

  for (const person of participants) {
    if (!participantIDs.includes(person.id)) continue
    if (person.lastContactAt === null || person.lastContactAt.getTime() < draft.occurredAt.getTime()) {
      plan.push({
        op: 'update',
        collection: 'people',
        id: person.id,
        data: { lastContactAt: draft.occurredAt },
      })
    }
  }

  return { plan, interaction, reminders }
}

// MARK: Facts

export interface ObservationDraft {
  subjectID: string
  attribute: FactAttribute
  value: string
  confidence?: FactConfidence
  sensitivity?: FactSensitivity
  observedOn?: Date
  sourceInteractionID?: string | null
  sourceDocumentID?: string | null
}

export function makeObservation(draft: ObservationDraft, now: Date): Observation {
  const observedOn = draft.observedOn ?? now
  return {
    id: newID(),
    subjectID: draft.subjectID,
    attribute: draft.attribute,
    value: draft.value.trim(),
    observedOn,
    effectiveOn: null,
    lastConfirmedOn: observedOn,
    confidence: draft.confidence ?? 'stated',
    sensitivity: draft.sensitivity ?? 'normal',
    sourceInteractionID: draft.sourceInteractionID ?? null,
    sourceDocumentID: draft.sourceDocumentID ?? null,
    supersedesID: null,
    supersededOn: null,
    correctionNote: null,
    createdAt: now,
  }
}

export function planObservation(draft: ObservationDraft, now: Date): { plan: WritePlan; observation: Observation } {
  const observation = makeObservation(draft, now)
  return {
    plan: [{ op: 'set', collection: 'observations', id: observation.id, data: observation }],
    observation,
  }
}

/// Confirming bumps lastConfirmedOn on the same row. No new row — nothing changed.
export function planConfirmObservation(observation: Observation, now: Date): { plan: WritePlan } {
  return {
    plan: [{ op: 'update', collection: 'observations', id: observation.id, data: { lastConfirmedOn: now } }],
  }
}

/// Correcting appends: one batch writes the replacement and marks the old row
/// superseded, with the user's note on the *old* row — that is where "I misheard
/// this" belongs. Nothing is ever deleted.
export function planCorrection(
  old: Observation,
  next: { value: string; confidence?: FactConfidence; sensitivity?: FactSensitivity; sourceDocumentID?: string | null },
  correctionNote: string | null,
  now: Date,
): { plan: WritePlan; observation: Observation } {
  const replacement = makeObservation(
    {
      subjectID: old.subjectID,
      attribute: old.attribute,
      value: next.value,
      confidence: next.confidence ?? 'stated',
      sensitivity: next.sensitivity ?? old.sensitivity,
      sourceInteractionID: old.sourceInteractionID,
      sourceDocumentID: next.sourceDocumentID ?? null,
    },
    now,
  )
  replacement.supersedesID = old.id

  return {
    plan: [
      { op: 'set', collection: 'observations', id: replacement.id, data: replacement },
      {
        op: 'update',
        collection: 'observations',
        id: old.id,
        data: { supersededOn: now, correctionNote: correctionNote?.trim() || null },
      },
    ],
    observation: replacement,
  }
}

// MARK: Relationships

export function planRelationshipPair(
  args: { subjectID: string; otherID: string; kind: RelationshipKind; customLabel?: string | null },
  now: Date,
): { plan: WritePlan; pair: [Relationship, Relationship] } {
  const pair = relationshipPair({ ...args, now })
  return {
    plan: pair.map((row) => ({ op: 'set' as const, collection: 'relationships' as const, id: row.id, data: row })),
    pair,
  }
}

/// Recording a relative in the user's own words, named or not. A blank name is
/// legal and ordinary: the new record is titled by the possessive phrase and
/// queued for filling in. Never resolved against existing records by phrase —
/// two people can both be "Dave's son" — so this always creates.
export interface RelativeCaptureDraft {
  kind: RelationshipKind
  /// The user's word — "son". Kept as the label, never used to infer anything.
  label?: string | null
  /// Optional. Nil is legal, and ordinary.
  name?: string | null
  /// Facts about the new person, attribute → value, already folded.
  facts?: Array<{ attribute: FactAttribute; value: string }>
  sourceInteractionID?: string | null
}

export function planRelativeCapture(
  subject: Person,
  draft: RelativeCaptureDraft,
  now: Date,
): { plan: WritePlan; relative: Person; pair: [Relationship, Relationship] } {
  const name = draft.name?.trim()
  const hasName = Boolean(name && name.length > 0)

  const relative = makePerson(
    {
      displayName: hasName ? name! : possessivePhrase(subject.displayName, draft.kind, draft.label),
      isPlaceholder: !hasName,
      hasStatedName: hasName,
    },
    now,
  )

  const plan: WritePlan = [{ op: 'set', collection: 'people', id: relative.id, data: relative }]

  const { plan: pairPlan, pair } = planRelationshipPair(
    { subjectID: subject.id, otherID: relative.id, kind: draft.kind, customLabel: draft.label },
    now,
  )
  plan.push(...pairPlan)

  for (const fact of draft.facts ?? []) {
    if (!fact.value.trim()) continue
    const { plan: factPlan } = planObservation(
      {
        subjectID: relative.id,
        attribute: fact.attribute,
        value: fact.value,
        sourceInteractionID: draft.sourceInteractionID ?? null,
      },
      now,
    )
    plan.push(...factPlan)
  }

  return { plan, relative, pair }
}

/// Unrelating removes both halves in one batch — a pair exists as a unit or not at all.
export function planUnrelate(forward: Relationship): { plan: WritePlan } {
  return {
    plan: [
      { op: 'delete', collection: 'relationships', id: forward.id },
      { op: 'delete', collection: 'relationships', id: forward.reciprocalID },
    ],
  }
}

// MARK: Reminders

export interface ReminderDraft {
  title: string
  notes?: string | null
  personIDs?: string[]
  categoryTags?: string[]
  sourceInteractionID?: string | null
  sourceDocumentID?: string | null
  startAt?: Date | null
  dueAt?: Date | null
  isSomeday?: boolean
  scheduleTimeZone?: string | null
  duePrecision?: 'date' | 'dateTime' | null
  startPrecision?: 'date' | 'dateTime' | null
}

export function planCreateReminder(draft: ReminderDraft, now: Date): { plan: WritePlan; reminder: Reminder } {
  const reminder: Reminder = {
    id: newID(),
    title: draft.title.trim(),
    notes: draft.notes?.trim() || null,
    personIDs: [...new Set(draft.personIDs ?? [])],
    categoryTags: [...new Set((draft.categoryTags ?? []).map((tag) => tag.trim()).filter(Boolean))],
    sourceInteractionID: draft.sourceInteractionID ?? null,
    sourceDocumentID: draft.sourceDocumentID ?? null,
    startAt: draft.startAt ?? null,
    dueAt: draft.dueAt ?? null,
    isSomeday: draft.isSomeday ?? false,
    status: 'open',
    completedAt: null,
    createdAt: now,
    scheduleTimeZone: draft.scheduleTimeZone ?? null,
    duePrecision: draft.duePrecision ?? null,
    startPrecision: draft.startPrecision ?? null,
  }
  return { plan: [{ op: 'set', collection: 'reminders', id: reminder.id, data: reminder }], reminder }
}

export function planUpdateReminder(
  id: string,
  changes: Partial<
    Pick<
      Reminder,
      | 'title'
      | 'notes'
      | 'startAt'
      | 'dueAt'
      | 'isSomeday'
      | 'personIDs'
      | 'categoryTags'
      | 'scheduleTimeZone'
      | 'duePrecision'
      | 'startPrecision'
    >
  >,
): { plan: WritePlan } {
  return { plan: [{ op: 'update', collection: 'reminders', id, data: { ...changes } }] }
}

/// The quick reschedule writes the start date and nothing else. No route through
/// this helper can create a deadline — rescheduling when you'll get to something
/// must never change when it is due. Day-granular by construction.
export function planQuickReschedule(id: string, startAt: Date | null): { plan: WritePlan } {
  return {
    plan: [
      {
        op: 'update',
        collection: 'reminders',
        id,
        data: { startAt, isSomeday: false, startPrecision: startAt ? 'date' : null },
      },
    ],
  }
}

/// Deletion is real deletion — reminders have no supersede chain — so the UI
/// must say it cannot be undone before ever applying this.
export function planDeleteReminder(id: string): { plan: WritePlan } {
  return { plan: [{ op: 'delete', collection: 'reminders', id }] }
}

export function planCompleteReminder(id: string, now: Date): { plan: WritePlan } {
  return { plan: [{ op: 'update', collection: 'reminders', id, data: { status: 'completed', completedAt: now } }] }
}

export function planReopenReminder(id: string): { plan: WritePlan } {
  return { plan: [{ op: 'update', collection: 'reminders', id, data: { status: 'open', completedAt: null } }] }
}
