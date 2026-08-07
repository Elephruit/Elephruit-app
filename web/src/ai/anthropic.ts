/// The write direction of AI capture: dictated text goes through the app's
/// AI gateway — which decrypts the user's stored key server-side and calls
/// Anthropic on their behalf — and a schema-validated CaptureProposal comes
/// back. Everything after that is the pure resolution in domain/assist.ts
/// and the review screen's confirmation.
///
/// Privacy shape, stated plainly: the dictation and the people roster's
/// names are sent to Anthropic under the user's stored key, via our
/// backend. The key itself never enters this module — requests carry a
/// credential id. The reply is re-validated here against the same zod
/// schema the request asked for; nothing unvalidated reaches a write plan.

import { zodOutputFormat } from '@anthropic-ai/sdk/helpers/zod'
import { z } from 'zod'
import type { CaptureProposal } from '../domain/assist'
import { CURATED_ATTRIBUTES, attributeLabel } from '../domain/facts'
import { INTERACTION_KINDS } from '../domain/interaction'
import { RELATIONSHIP_KINDS, kindLabel } from '../domain/relationships'
import { GatewayError, runAiTask, wireOutputFormat, type GatewayRequest } from './gateway'

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
    }),
  ),
  reminderChanges: z.array(
    z.object({
      reminderID: z.string(),
      action: z.enum(['complete', 'reopen', 'delete', 'update']),
      progress: z.enum(['notStarted', 'inProgress', 'blocked']).nullable(),
      notes: z.string().nullable(),
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
- followUps: commitments and expected actions, one entry each, titled as a short imperative ("Send the neighborhood list"). responsibility is "mine" when the SPEAKER owes or intends the action and "theirs" when the other person owes it or the speaker is waiting on them. personNames lists who each one concerns. notes carries any extra detail worth keeping; null otherwise.
- progress is "notStarted", "inProgress", or "blocked". Use a non-default state only when the speaker explicitly describes it.
- reminderChanges: when the speaker clearly says an existing follow-up was completed, reopened, deleted, or has a progress update, reference its exact supplied ID. Use action "update" with progress and/or a concise notes update for statements like "the forecast is blocked on Finance". Never guess an ID or create a duplicate. Deletion stays an explicit review item.
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
- Empty arrays are correct when the update contains nothing of that type.`
}

/// The request minus the credential — pure, so a test can pin the shape
/// without a network. Low effort fits a scoped extraction task and keeps
/// dictation snappy; the output format is the zod schema serialized, which
/// the gateway forwards opaquely into the provider's output_config.
export function buildRequestParams(model: string, system: string, text: string) {
  return {
    provider: 'anthropic' as const,
    model,
    maxTokens: 8192,
    system,
    messages: [{ role: 'user' as const, content: text }],
    effort: 'low' as const,
    outputFormat: wireOutputFormat(zodOutputFormat(CaptureProposalSchema)),
  }
}

export class AICaptureError extends Error {
  readonly recoverable: boolean

  constructor(message: string, recoverable = true) {
    super(message)
    this.recoverable = recoverable
  }
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
      return CaptureProposalSchema.parse(JSON.parse(reply))
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
