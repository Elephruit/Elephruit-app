/// The write direction of AI capture: dictated text goes through the app's
/// AI gateway — which decrypts the user's stored key server-side and calls
/// Anthropic on their behalf — and a schema-validated CaptureProposal comes
/// back. Everything after that is the pure resolution in domain/assist.ts
/// and the review screen's confirmation.
///
/// Privacy shape, stated plainly: the dictation and the people roster's
/// names are sent to Anthropic under the user's stored key, via our
/// backend. The key itself never enters this module — requests carry a
/// credential id. The reply is normalized at the provider boundary and then
/// validated against a strict zod schema; nothing unvalidated reaches a write
/// plan.

import { z } from 'zod'
import type { CaptureProposal } from '../domain/assist'
import { CURATED_ATTRIBUTES, attributeLabel } from '../domain/facts'
import { INTERACTION_KINDS, type InteractionKind } from '../domain/interaction'
import { RELATIONSHIP_KINDS, kindLabel, type RelationshipKind } from '../domain/relationships'
import { GatewayError, runAiTask, type GatewayRequest } from './gateway'
import { reportAiTaxonomyGaps } from './taxonomy'

// Structured outputs want every property present and no extras; optionality is
// expressed as null. Kept flat — recursive schemas are unsupported there.
const FactSchema = z.object({
  personName: z.string(),
  attribute: z.string(),
  value: z.string(),
  confidence: z.enum(['stated', 'inferred', 'uncertain']),
  sensitivity: z.enum(['normal', 'sensitive', 'restricted']),
  context: z.enum(['professional', 'personal', 'identity']),
  observedOn: z.string().nullable(),
  effectiveOn: z.string().nullable(),
})

const RelationshipFactSchema = z.object({
  attribute: z.string(),
  value: z.string(),
})

/// Structured time, flat for structured outputs: deadline/start carry a local
/// date (and optionally time + IANA zone); someday/none carry nulls. The
/// domain's resolveProposedSchedule turns this into real Reminder dates.
const ScheduleSchema = z.object({
  mode: z.enum(['deadline', 'start', 'someday', 'none']),
  localDate: z.string().nullable(),
  localTime: z.string().nullable(),
  timeZone: z.string().nullable(),
  sourceText: z.string().nullable(),
  confidence: z.enum(['stated', 'inferred', 'uncertain']),
})

export const CaptureProposalSchema = z.object({
  normalizationWarnings: z.array(z.string()).optional(),
  taxonomyGaps: z.array(z.object({ field: z.literal('relationship.kind'), value: z.string() })).optional(),
  interaction: z
    .object({
      kind: z.enum([...INTERACTION_KINDS]),
      summary: z.string(),
      discussion: z.string().nullable(),
      occurredAt: ScheduleSchema.nullable(),
    })
    .nullable(),
  participantNames: z.array(z.string()),
  personContexts: z.array(
    z.object({
      personName: z.string(),
      profileFocus: z.enum(['professional', 'personal']),
      roleTitle: z.string().nullable(),
      organizationName: z.string().nullable(),
      connectionStatus: z.enum(['met', 'introductionPlanned', 'unknown']),
      firstMetOn: z.string().nullable(),
      context: z.string().nullable(),
      introducedByName: z.string().nullable(),
    }),
  ),
  facts: z.array(FactSchema),
  relationships: z.array(
    z.object({
      subjectName: z.string(),
      kind: z.enum([...RELATIONSHIP_KINDS]),
      label: z.string().nullable(),
      otherName: z.string().nullable(),
      facts: z.array(RelationshipFactSchema),
    }),
  ),
  followUps: z.array(
    z.object({
      title: z.string(),
      personNames: z.array(z.string()),
      notes: z.string().nullable(),
      schedule: ScheduleSchema,
      responsibility: z.enum(['mine', 'theirs']),
      progress: z.enum(['notStarted', 'inProgress', 'blocked']),
      tags: z.array(z.string()),
      folderPath: z.string().nullable(),
    }),
  ),
  reminderChanges: z.array(
    z.object({
      reminderID: z.string(),
      action: z.enum(['complete', 'reopen', 'delete', 'update']),
      progress: z.enum(['notStarted', 'inProgress', 'blocked']).nullable(),
      notes: z.string().nullable(),
      responsibility: z.enum(['mine', 'theirs']).nullable(),
    }),
  ),
  factChanges: z.array(
    z.object({
      observationID: z.string(),
      action: z.enum(['confirm', 'correct']),
      value: z.string().nullable(),
      correctionNote: z.string().nullable(),
      confidence: z.enum(['stated', 'inferred', 'uncertain']).nullable(),
      sensitivity: z.enum(['normal', 'sensitive', 'restricted']).nullable(),
    }),
  ),
  relationshipChanges: z.array(
    z.object({ relationshipID: z.string(), action: z.literal('remove') }),
  ),
})

type JsonObject = Record<string, unknown>
type FactConfidence = 'stated' | 'inferred' | 'uncertain'
type FactSensitivity = 'normal' | 'sensitive' | 'restricted'
type FactContext = 'professional' | 'personal' | 'identity'

const EMPTY_SCHEDULE = {
  mode: 'none' as const,
  localDate: null,
  localTime: null,
  timeZone: null,
  sourceText: null,
  confidence: 'stated' as const,
}

function object(value: unknown): JsonObject | null {
  return value !== null && typeof value === 'object' && !Array.isArray(value) ? value as JsonObject : null
}

function token(value: unknown): string {
  return typeof value === 'string' ? value.trim().toLowerCase().replace(/[^a-z0-9]/g, '') : ''
}

function string(value: unknown): string {
  return typeof value === 'string' ? value.trim() : ''
}

function nullableString(value: unknown): string | null {
  const result = string(value)
  return result && token(result) !== 'none' && token(result) !== 'null' ? result : null
}

function values(value: unknown): unknown[] {
  if (Array.isArray(value)) return value
  return value === null || value === undefined ? [] : [value]
}

function strings(value: unknown, field: string, warnings: string[]): string[] {
  const raw = values(value)
  const result = raw.map(string).filter(Boolean)
  if (typeof value === 'string' && result.length) warnings.push(`AI returned ${field} as text; it was converted to a list for review.`)
  if (raw.length !== result.length) warnings.push(`Some invalid ${field} values were omitted from the proposal.`)
  return result
}

function interactionKind(value: unknown, warnings: string[]): InteractionKind {
  const normalized = token(value)
  const aliases: Record<string, InteractionKind> = {
    inperson: 'in-person', coffee: 'in-person', lunch: 'in-person', dinner: 'in-person', drinks: 'in-person',
    call: 'phone', phone: 'phone', telephone: 'phone',
    meeting: 'video', video: 'video', zoom: 'video', meet: 'video',
    message: 'message', text: 'message', slack: 'message', chat: 'message', im: 'message',
    email: 'email', other: 'other', connection: 'other', introduction: 'other',
  }
  const result = aliases[normalized]
  if (result) {
    if (string(value) !== result) warnings.push(`Interaction type “${string(value)}” was normalized to “${result}”.`)
    return result
  }
  warnings.push('An unknown interaction type was kept as “other” for review.')
  return 'other'
}

function relationshipKind(value: unknown): { kind: RelationshipKind; label: string | null; unrecognized: boolean } {
  const raw = string(value)
  const normalized = token(value)
  const exact = RELATIONSHIP_KINDS.find((kind) => token(kind) === normalized)
  if (exact) return { kind: exact, label: null, unrecognized: exact === 'unknown' }
  const aliases: Record<string, RelationshipKind> = {
    husband: 'partner', wife: 'partner', spouse: 'partner', fiance: 'partner', fiancee: 'partner',
    mother: 'parent', father: 'parent', mom: 'parent', dad: 'parent',
    son: 'child', daughter: 'child', kid: 'child', niece: 'child', nephew: 'child', nieceandnephew: 'child',
    sister: 'sibling', brother: 'sibling', twin: 'sibling', twinsister: 'sibling', twinbrother: 'sibling',
    connection: 'friend', contact: 'friend',
    coworker: 'colleague', colleague: 'colleague', peer: 'colleague', teammate: 'colleague', consultant: 'colleague',
    boss: 'manager', supervisor: 'manager', lead: 'manager',
    report: 'directReport', reportsto: 'directReport', employee: 'directReport',
    introducer: 'introducedBy', intro: 'introducedBy', introducedby: 'introducedBy',
    roommate: 'householdMember', household: 'householdMember', family: 'householdMember',
    owner: 'petOwner', dog: 'pet', cat: 'pet',
  }
  return aliases[normalized]
    ? { kind: aliases[normalized], label: raw || null, unrecognized: false }
    : { kind: 'unknown', label: raw || null, unrecognized: true }
}

function confidence(value: unknown, warnings: string[], field = 'confidence'): FactConfidence {
  const normalized = token(value)
  if (!normalized || ['stated', 'high', 'certain', 'explicit'].includes(normalized)) return 'stated'
  if (['inferred', 'medium', 'deduced', 'likely', 'probably'].includes(normalized)) return 'inferred'
  if (['uncertain', 'low', 'hedged', 'maybe', 'unclear', 'unknown'].includes(normalized)) return 'uncertain'
  warnings.push(`An unknown ${field} value was changed to “uncertain” for review.`)
  return 'uncertain'
}

function sensitivity(value: unknown, warnings: string[]): FactSensitivity {
  const normalized = token(value)
  if (!normalized || normalized === 'normal') return 'normal'
  if (['sensitive', 'delicate'].includes(normalized)) return 'sensitive'
  if (['restricted', 'secret', 'private', 'confidential'].includes(normalized)) return 'restricted'
  warnings.push('An unknown sensitivity value was changed to “sensitive” for review.')
  return 'sensitive'
}

function factContext(value: unknown): FactContext {
  const normalized = token(value)
  if (['identity', 'bio', 'origin', 'background'].includes(normalized)) return 'identity'
  if (['professional', 'work', 'career', 'job', 'business'].includes(normalized)) return 'professional'
  return 'personal'
}

function schedule(value: unknown, warnings: string[]) {
  const item = object(value)
  if (!item) return { ...EMPTY_SCHEDULE }
  const normalized = token(item.mode)
  const modes = { deadline: 'deadline', due: 'deadline', by: 'deadline', at: 'deadline', on: 'deadline', start: 'start', begin: 'start', someday: 'someday', later: 'someday', none: 'none' } as const
  let mode: 'deadline' | 'start' | 'someday' | 'none' = modes[normalized as keyof typeof modes] ?? 'none'
  if (normalized && !(normalized in modes)) warnings.push('An unknown schedule type was changed to “none” for review.')
  const localDate = nullableString(item.localDate)
  const localTime = nullableString(item.localTime)
  const timeZone = nullableString(item.timeZone)
  const sourceText = nullableString(item.sourceText)
  if (mode === 'none' && (localDate || localTime)) {
    mode = 'deadline'
    warnings.push('A dated item without a schedule type was treated as a deadline for review.')
  }
  return { mode, localDate, localTime, timeZone, sourceText, confidence: confidence(item.confidence, warnings, 'schedule confidence') }
}

function progress(value: unknown): 'notStarted' | 'inProgress' | 'blocked' {
  const normalized = token(value)
  if (['inprogress', 'progress', 'doing', 'active', 'started'].includes(normalized)) return 'inProgress'
  if (['blocked', 'waiting', 'hold', 'paused'].includes(normalized)) return 'blocked'
  return 'notStarted'
}

function responsibility(value: unknown): 'mine' | 'theirs' {
  return ['theirs', 'them', 'her', 'him', 'other', 'they'].includes(token(value)) ? 'theirs' : 'mine'
}

/// Repairs provider-shaped JSON into the strict proposal consumed by the
/// resolver. It never invents identity or destructive-change IDs: unsafe rows
/// are omitted and explained in the review warnings.
export function normalizeCaptureProposal(raw: unknown): CaptureProposal {
  const root = object(raw)
  if (!root) throw new Error('Capture proposal must be a JSON object.')
  const warnings: string[] = []
  const taxonomyGaps: Array<{ field: 'relationship.kind'; value: string }> = []

  const interactionObject = object(root.interaction)
  const interactionSummary = string(interactionObject?.summary)
  const interaction = interactionObject && interactionSummary ? {
    kind: interactionKind(interactionObject.kind, warnings),
    summary: interactionSummary,
    discussion: nullableString(interactionObject.discussion),
    occurredAt: interactionObject.occurredAt == null ? null : schedule(interactionObject.occurredAt, warnings),
  } : null
  if (interactionObject && !interactionSummary) warnings.push('An interaction without a summary was omitted from the proposal.')

  const personContexts = values(root.personContexts).flatMap((rawItem) => {
    const item = object(rawItem)
    const personName = string(item?.personName)
    if (!item || !personName) {
      warnings.push('A person detail without a name was omitted from the proposal.')
      return []
    }
    return [{
      personName,
      profileFocus: ['professional', 'work', 'career'].includes(token(item.profileFocus)) ? 'professional' as const : 'personal' as const,
      roleTitle: nullableString(item.roleTitle),
      organizationName: nullableString(item.organizationName),
      connectionStatus: token(item.connectionStatus) === 'met' ? 'met' as const : ['introductionplanned', 'planned', 'intro'].includes(token(item.connectionStatus)) ? 'introductionPlanned' as const : 'unknown' as const,
      firstMetOn: nullableString(item.firstMetOn),
      context: nullableString(item.context),
      introducedByName: nullableString(item.introducedByName),
    }]
  })

  const facts = values(root.facts).flatMap((rawItem) => {
    const item = object(rawItem)
    const personName = string(item?.personName)
    const value = string(item?.value)
    if (!item || !personName || !value) {
      warnings.push('A fact without both a person and value was omitted from the proposal.')
      return []
    }
    return [{ personName, attribute: string(item.attribute) || 'quick fact', value, confidence: confidence(item.confidence, warnings), sensitivity: sensitivity(item.sensitivity, warnings), context: factContext(item.context), observedOn: nullableString(item.observedOn), effectiveOn: nullableString(item.effectiveOn) }]
  })

  const relationships = values(root.relationships).flatMap((rawItem) => {
    const item = object(rawItem)
    const subjectName = string(item?.subjectName)
    const normalizedKind = relationshipKind(item?.kind)
    if (!item || !subjectName) {
      warnings.push('A relationship without a subject was omitted from the proposal.')
      return []
    }
    const relationshipFacts = values(item.facts).flatMap((rawFact) => {
      if (typeof rawFact === 'string') return rawFact.trim() ? [{ attribute: 'detail', value: rawFact.trim() }] : []
      const fact = object(rawFact)
      const value = string(fact?.value)
      return fact && value ? [{ attribute: string(fact.attribute) || 'detail', value }] : []
    })
    const suppliedLabel = nullableString(item.label)
    if (normalizedKind.unrecognized) {
      const preservedLabel = suppliedLabel ?? normalizedKind.label
      const label = preservedLabel ? `“${preservedLabel}”` : 'A missing relationship type'
      warnings.push(`${label} is not in the relationship taxonomy. It was kept as “unknown” for review and may need a new app category.`)
      if (preservedLabel) taxonomyGaps.push({ field: 'relationship.kind', value: preservedLabel })
    } else if (normalizedKind.label) {
      warnings.push(`Relationship type “${normalizedKind.label}” was normalized to “${normalizedKind.kind}” and kept as its review label.`)
    }
    return [{ subjectName, kind: normalizedKind.kind, label: suppliedLabel ?? normalizedKind.label, otherName: nullableString(item.otherName), facts: relationshipFacts }]
  })

  const followUps = values(root.followUps).flatMap((rawItem) => {
    const item = object(rawItem)
    const title = string(item?.title)
    if (!item || !title) {
      warnings.push('A follow-up without a title was omitted from the proposal.')
      return []
    }
    return [{ title, personNames: strings(item.personNames, 'follow-up names', warnings), notes: nullableString(item.notes), schedule: schedule(item.schedule, warnings), responsibility: responsibility(item.responsibility), progress: progress(item.progress), tags: strings(item.tags, 'tags', warnings), folderPath: nullableString(item.folderPath) }]
  })

  const reminderChanges = values(root.reminderChanges).flatMap((rawItem) => {
    const item = object(rawItem)
    const reminderID = string(item?.reminderID)
    const action = string(item?.action)
    if (!item || !reminderID || !['complete', 'reopen', 'delete', 'update'].includes(action)) {
      warnings.push('An invalid follow-up change was omitted from the proposal.')
      return []
    }
    return [{ reminderID, action: action as 'complete' | 'reopen' | 'delete' | 'update', progress: item.progress == null ? null : progress(item.progress), notes: nullableString(item.notes), responsibility: item.responsibility == null ? null : responsibility(item.responsibility) }]
  })
  const factChanges = values(root.factChanges).flatMap((rawItem) => {
    const item = object(rawItem)
    const observationID = string(item?.observationID)
    const action = string(item?.action)
    if (!item || !observationID || !['confirm', 'correct'].includes(action)) {
      warnings.push('An invalid fact change was omitted from the proposal.')
      return []
    }
    return [{ observationID, action: action as 'confirm' | 'correct', value: nullableString(item.value), correctionNote: nullableString(item.correctionNote), confidence: item.confidence == null ? null : confidence(item.confidence, warnings), sensitivity: item.sensitivity == null ? null : sensitivity(item.sensitivity, warnings) }]
  })
  const relationshipChanges = values(root.relationshipChanges).flatMap((rawItem) => {
    const item = object(rawItem)
    const relationshipID = string(item?.relationshipID)
    if (item && relationshipID && item.action === 'remove') return [{ relationshipID, action: 'remove' as const }]
    warnings.push('An invalid relationship change was omitted from the proposal.')
    return []
  })

  return CaptureProposalSchema.parse({
    normalizationWarnings: warnings,
    taxonomyGaps,
    interaction,
    participantNames: strings(root.participantNames, 'participant names', warnings),
    personContexts,
    facts,
    relationships,
    followUps,
    reminderChanges,
    factChanges,
    relationshipChanges,
  })
}

export interface CaptureRecordContext {
  id: string
  name: string
  profile: string
  facts: Array<{ id: string; label: string; value: string }>
  reminders: Array<{ id: string; title: string; status: 'open' | 'completed'; responsibility: 'mine' | 'theirs'; progress: 'notStarted' | 'inProgress' | 'blocked'; notes: string | null }>
  relationships: Array<{ id: string; description: string }>
}

export interface CaptureContext {
  today: Date
  peopleNames: string[]
  records?: CaptureRecordContext[]
  /// The browser's locale and zone — relative phrases ("Monday", "tomorrow")
  /// resolve deterministically only when the model knows where the user is.
  locale: string
  timeZone: string
  utcOffsetMinutes: number
}

export function buildSystemPrompt(context: CaptureContext): string {
  const attributes = CURATED_ATTRIBUTES.map((a) => `${a} ("${attributeLabel(a)}")`).join(', ')
  const kinds = RELATIONSHIP_KINDS.map((k) => `${k} ("${kindLabel(k)}")`).join(', ')
  const roster = context.peopleNames.slice(0, 200).join('; ')
  const existingRecords = (context.records ?? [])
    .slice(0, 80)
    .map((record) => {
      const lines = [`${record.name} [${record.id}]${record.profile ? ` — ${record.profile}` : ''}`]
      lines.push(...record.facts.slice(0, 20).map((fact) => `  fact ${fact.id}: ${fact.label} = ${fact.value}`))
      lines.push(...record.reminders.slice(0, 20).map((reminder) => `  follow-up ${reminder.id} (${reminder.status}, ${reminder.responsibility}, ${reminder.progress}): ${reminder.title}${reminder.notes ? ` — ${reminder.notes}` : ''}`))
      lines.push(...record.relationships.slice(0, 20).map((relationship) => `  relationship ${relationship.id}: ${relationship.description}`))
      return lines.join('\n')
    })
    .join('\n')
  const offset = context.utcOffsetMinutes
  const offsetLabel = `UTC${offset >= 0 ? '+' : '−'}${String(Math.floor(Math.abs(offset) / 60)).padStart(2, '0')}:${String(Math.abs(offset) % 60).padStart(2, '0')}`
  const localDate = context.today.toLocaleDateString(context.locale, {
    weekday: 'long',
    year: 'numeric',
    month: 'long',
    day: 'numeric',
  })

  return `You turn one spoken update from the user into a structured capture proposal for their personal relationship log. Today is ${context.today.toDateString()} — ${localDate}. The user's locale is ${context.locale}; their time zone is ${context.timeZone} (${offsetLabel}).

People already on record: ${roster || '(nobody yet)'}.

Existing safe record context (sensitive and private facts are intentionally absent):
${existingRecords || '(no existing details supplied)'}.

Rules, in order of importance:
- Extract only what the speaker actually said. Keep values close to their words; never embellish, never summarize a fact into something broader.
- Never invent a name. Somebody mentioned without a name ("her son") is a relationship with otherName null — never a made-up name, never a guessed match against the roster.
- When a name closely matches somebody on record, use the roster's exact spelling so the app can match it.
- interaction: only when the update describes contact that happened — a conversation, a meeting, a call, or mediated contact. "Harbinder introduced me to Kelly" and "I met Kelly through Harbinder" are interactions (kind "other" when the channel is unknown) with both people as participants; the introduction relationship is proposed separately as well. A pure statement of biography ("Kelly was introduced by Harbinder" as background, "her son is 13") has interaction null and participantNames empty. Choose the kind that fits; summary is one short line in the speaker's voice preserving the event meaning.
- participantNames: the people the speaker interacted with — not every name mentioned in passing.
- interaction.occurredAt: capture when the interaction happened using the schedule's local date/time fields and mode "deadline"; use null when the speaker gave no date. This is descriptive history, never a reminder.
- personContexts: the working-board identity and origin for a person. Use profileFocus "professional" when their work is central, otherwise "personal". Capture roleTitle, organizationName, whether they have already met the user or an introduction is planned, the YYYY-MM-DD first-meeting date, the speaker's meeting context, and who introduced them. Use null rather than guessing. Include a row whenever any of these values are stated.
- facts: things now known about a person, attributed to the right person. attribute should be one of the curated attributes when one fits: ${attributes}. Otherwise use a short lowercase phrase of your own. confidence is "stated" when the speaker asserted it, "inferred" when you are deducing it, "uncertain" when they hedged.
- Every fact also has sensitivity, context, observedOn, and effectiveOn. sensitivity is "restricted" for secrets or deeply private material, "sensitive" for delicate personal information, otherwise "normal". context controls where custom facts appear: identity, professional, or personal. Dates are YYYY-MM-DD or null; observedOn is when the speaker learned it and effectiveOn is when it becomes true if different.
- relationships: family, work, and social ties the update reveals (${kinds}). label carries the speaker's own word ("son", "boss"). Facts about a person who was only described relative to somebody else ("her son is a senior") belong in that relationship's facts, not in the top-level facts.
- followUps: commitments and expected actions, one entry each, titled as a short imperative ("Send the neighborhood list"). responsibility is "mine" when the SPEAKER owes or intends the action and "theirs" when the other person owes it or the speaker is waiting on them. personNames lists who each one concerns. notes carries any extra detail worth keeping; null otherwise. tags is a list of zero or more labels. folderPath preserves one folder name or slash-separated path only when the speaker explicitly says where the item lives; use the deepest named folder and otherwise null. Never invent a folder. Tags never substitute for a folder.
- progress is "notStarted", "inProgress", or "blocked". Use a non-default state only when the speaker explicitly describes it.
- reminderChanges: when the speaker clearly says an existing follow-up was completed, reopened, deleted, reassigned, or has a progress update, reference its exact supplied ID. Use action "update" with progress, responsibility, and/or a concise notes update. "I will take that" means responsibility "mine"; "she owns that" means "theirs". Never guess an ID or create a duplicate. Deletion stays an explicit review item.
- factChanges: use "confirm" when the speaker says an existing supplied fact still holds. Use "correct" with the replacement value and an optional correction note when it changed or was wrong. Reference the exact supplied observation ID; never guess one or emit the same correction as a new fact.
- relationshipChanges: use "remove" only when the speaker clearly asks to remove an existing supplied relationship. Reference its exact supplied ID. This remains explicit in review because both reciprocal relationship rows will be removed.
- schedule: every follow-up carries one. Read temporal phrases carefully:
  - mode "deadline": there is a moment after which the item is late or missed. Meetings, appointments, calls, flights, reservations, and attendance obligations at a specific time are deadlines — "Attend Monday 10am CT meeting" is a deadline at Monday 10:00, not a start. "Send the deck by Friday" is a date-only deadline.
  - mode "start": the wording means it merely becomes available or begins then and can never be late — "Start drafting the deck Monday".
  - mode "someday": deliberately parked without a date — "sometime, take Kelly to lunch".
  - mode "none": no temporal phrase at all.
  - "Remind me Monday to call Kelly" is a deadline on Monday unless the wording clearly means it only becomes available then.
  - localDate is YYYY-MM-DD resolved against the user's date and zone; a weekday name means the next contextually valid occurrence. localTime is 24-hour HH:mm only when a time was stated. Cues include today, tomorrow, tonight, weekday names, month + day, numeric dates, "at 10", "10am", "noon", "by", "before", "on", "after".
  - timeZone is an IANA identifier, required whenever localTime is set. Resolve abbreviations from the user's context: "CT" means America/Chicago when the user's zone is America/Chicago or the context clearly indicates US Central. If an abbreviation stays ambiguous, keep your best reading, set confidence "uncertain", and preserve the phrase in sourceText for confirmation.
  - sourceText always preserves the exact temporal phrase when one exists.
  - Never leave temporal wording only in the title while returning mode "none", unless the phrase is quoted or clearly not an instruction.
- Empty arrays are correct when the update contains nothing of that type.
- Return only one raw JSON object, without markdown or commentary. Always include these top-level keys: interaction, participantNames, personContexts, facts, relationships, followUps, reminderChanges, factChanges, relationshipChanges.
- Use arrays for every plural field, including participantNames, facts, relationship facts, personNames, and tags. Use null for an unknown optional scalar.
- Use only the exact interaction, relationship, confidence, sensitivity, context, connection, progress, responsibility, action, and schedule enum values listed above.`
}

/// The request minus the credential — pure, so a test can pin the shape
/// without a network. Capture deliberately uses prompt-directed JSON plus a
/// tolerant local normalizer: provider structured-output grammars have varied
/// across models and must not turn a valid streamed reply into a total failure.
export function buildRequestParams(model: string, system: string, text: string) {
  return {
    provider: 'anthropic' as const,
    model,
    maxTokens: 8192,
    system,
    messages: [{ role: 'user' as const, content: text }],
  }
}

export class AICaptureError extends Error {
  readonly recoverable: boolean

  constructor(message: string, recoverable = true) {
    super(message)
    this.recoverable = recoverable
  }
}

/// Providers occasionally wrap otherwise valid JSON in prose or a markdown
/// fence. Extract only the outermost object; parsing and normalization remain
/// separate so no unvalidated string reaches the domain planner.
export function extractJsonPayload(raw: string): string {
  const trimmed = raw.trim()
  const firstBrace = trimmed.indexOf('{')
  const lastBrace = trimmed.lastIndexOf('}')
  return firstBrace >= 0 && lastBrace > firstBrace ? trimmed.slice(firstBrace, lastBrace + 1) : trimmed
}

export async function parseCapture(
  text: string,
  options: { credentialId: string; model: string; context: CaptureContext },
): Promise<CaptureProposal> {
  try {
    const request: GatewayRequest = {
      ...buildRequestParams(options.model, buildSystemPrompt(options.context), text),
      credentialId: options.credentialId,
    }
    const { text: reply, final } = await runAiTask(request)

    if (final.stopReason === 'refusal') {
      throw new AICaptureError('The model declined to process this update. Your text is kept — log it manually.')
    }
    try {
      const proposal = normalizeCaptureProposal(JSON.parse(extractJsonPayload(reply)))
      void reportAiTaxonomyGaps(proposal.taxonomyGaps ?? [])
      return proposal
    } catch {
      throw new AICaptureError('The reply did not match the expected shape. Your text is kept — log it manually.')
    }
  } catch (cause) {
    if (cause instanceof AICaptureError) throw cause
    if (cause instanceof GatewayError) {
      throw new AICaptureError(cause.message, cause.recoverable)
    }
    throw new AICaptureError('Could not reach the AI gateway. Your text is kept — log it manually.')
  }
}
