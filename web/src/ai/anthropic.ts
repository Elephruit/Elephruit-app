/// The one impure edge of AI capture: dictated text goes to the Anthropic API
/// with the user's own key, browser-direct, and a schema-validated
/// CaptureProposal comes back. Everything after that is the pure resolution
/// in domain/assist.ts and the review screen's confirmation.
///
/// Privacy shape, stated plainly: the dictation and the people roster's names
/// are sent to Anthropic under the user's key. Nothing else leaves.

import Anthropic from '@anthropic-ai/sdk'
import { zodOutputFormat } from '@anthropic-ai/sdk/helpers/zod'
import { z } from 'zod'
import type { CaptureProposal } from '../domain/assist'
import { CURATED_ATTRIBUTES, attributeLabel } from '../domain/facts'
import { INTERACTION_KINDS } from '../domain/interaction'
import { RELATIONSHIP_KINDS, kindLabel } from '../domain/relationships'

// Structured outputs want every property present and no extras; optionality is
// expressed as null. Kept flat — recursive schemas are unsupported there.
const FactSchema = z.object({
  personName: z.string(),
  attribute: z.string(),
  value: z.string(),
  confidence: z.enum(['stated', 'inferred', 'uncertain']),
})

const RelationshipFactSchema = z.object({
  attribute: z.string(),
  value: z.string(),
})

export const CaptureProposalSchema = z.object({
  interaction: z
    .object({
      kind: z.enum([...INTERACTION_KINDS]),
      summary: z.string(),
      discussion: z.string().nullable(),
    })
    .nullable(),
  participantNames: z.array(z.string()),
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
    }),
  ),
})

export interface CaptureContext {
  today: Date
  peopleNames: string[]
}

export function buildSystemPrompt(context: CaptureContext): string {
  const attributes = CURATED_ATTRIBUTES.map((a) => `${a} ("${attributeLabel(a)}")`).join(', ')
  const kinds = RELATIONSHIP_KINDS.map((k) => `${k} ("${kindLabel(k)}")`).join(', ')
  const roster = context.peopleNames.slice(0, 200).join('; ')

  return `You turn one spoken update from the user into a structured capture proposal for their personal relationship log. Today is ${context.today.toDateString()}.

People already on record: ${roster || '(nobody yet)'}.

Rules, in order of importance:
- Extract only what the speaker actually said. Keep values close to their words; never embellish, never summarize a fact into something broader.
- Never invent a name. Somebody mentioned without a name ("her son") is a relationship with otherName null — never a made-up name, never a guessed match against the roster.
- When a name closely matches somebody on record, use the roster's exact spelling so the app can match it.
- interaction: only when the update describes a conversation or meeting that happened (coffee, a call, ran into them). A pure statement of facts has interaction null and participantNames empty. Choose the kind that fits; summary is one short line in the speaker's voice.
- participantNames: the people the speaker interacted with — not every name mentioned in passing.
- facts: things now known about a person, attributed to the right person. attribute should be one of the curated attributes when one fits: ${attributes}. Otherwise use a short lowercase phrase of your own. confidence is "stated" when the speaker asserted it, "inferred" when you are deducing it, "uncertain" when they hedged.
- relationships: family, work, and social ties the update reveals (${kinds}). label carries the speaker's own word ("son", "boss"). Facts about a person who was only described relative to somebody else ("her son is a senior") belong in that relationship's facts, not in the top-level facts.
- followUps: things the SPEAKER now owes or intends to do, one entry each, titled as a short imperative ("Send the neighborhood list"). personNames lists who each one concerns.
- Empty arrays are correct when the update contains nothing of that type.`
}

/// The request minus the client — pure, so a test can pin the shape without a
/// network. Thinking stays at the model's default; low effort fits a scoped
/// extraction task and keeps dictation snappy.
export function buildRequestParams(model: string, system: string, text: string) {
  return {
    model,
    max_tokens: 8192,
    system,
    messages: [{ role: 'user' as const, content: text }],
    output_config: {
      effort: 'low' as const,
      format: zodOutputFormat(CaptureProposalSchema),
    },
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
  options: { apiKey: string; model: string; context: CaptureContext },
): Promise<CaptureProposal> {
  const client = new Anthropic({ apiKey: options.apiKey, dangerouslyAllowBrowser: true })

  try {
    const response = await client.messages.parse(
      buildRequestParams(options.model, buildSystemPrompt(options.context), text),
    )

    if (response.stop_reason === 'refusal') {
      throw new AICaptureError('The model declined to process this update. Your text is kept — log it manually.')
    }

    const proposal = response.parsed_output
    if (!proposal) {
      throw new AICaptureError('The reply did not match the expected shape. Your text is kept — log it manually.')
    }
    return proposal
  } catch (cause) {
    if (cause instanceof AICaptureError) throw cause
    if (cause instanceof Anthropic.AuthenticationError) {
      throw new AICaptureError('That API key was not accepted. Check it in Settings.', false)
    }
    if (cause instanceof Anthropic.RateLimitError) {
      throw new AICaptureError('The API is rate-limiting right now — try again in a moment.')
    }
    if (cause instanceof Anthropic.APIError) {
      throw new AICaptureError(`The API returned an error (${cause.status ?? 'network'}).`)
    }
    throw new AICaptureError('Could not reach the API. Your text is kept — log it manually.')
  }
}
