/// The read direction of the AI street: turning the domain-assembled briefing
/// payload into talking points, through the app's AI gateway under the user's
/// stored key. Same posture as capture parsing — a credential id instead of a
/// key, schema-validated output, and the model sees only what
/// domain/briefing.ts decided it may see.

import { zodOutputFormat } from '@anthropic-ai/sdk/helpers/zod'
import { z } from 'zod'
import type { BriefingInput } from '../domain/briefing'
import { AICaptureError } from './anthropic'
import { GatewayError, runAiTask, wireOutputFormat, type GatewayRequest } from './gateway'

export const DayBriefSchema = z.object({
  people: z.array(
    z.object({
      /// Must match a name from the input exactly.
      name: z.string(),
      /// One line on where things stand with this person.
      headline: z.string(),
      talkingPoints: z.array(z.string()),
      openLoops: z.array(z.string()),
      suggestedQuestions: z.array(z.string()),
    }),
  ),
  /// One optional line across the whole day; null when there is nothing worth saying.
  dayNote: z.string().nullable(),
})

export type DayBrief = z.infer<typeof DayBriefSchema>

export function buildBriefingSystemPrompt(): string {
  return [
    'You prepare a private, personal relationship brief. The user is about to talk to these people and wants to be a thoughtful presence in their lives.',
    'Use only the records provided. Never invent names, events, dates, or details that are not in the data. If little is recorded about someone, say less about them rather than padding.',
    'For each person: a one-line headline of where things stand; two to four talking points grounded in recorded facts and recent conversations; follow-ups the user owes them; one to three questions worth asking, favoring what has changed lately or is going stale.',
    'Confidence labels like "Estimated" mean the record is uncertain — phrase those as things to confirm, not facts to assert.',
    'Write in plain, warm, second-person prose ("ask her", "you owe him"). No emoji, no headers inside strings, no markdown.',
  ].join('\n')
}

export function buildBriefingRequestParams(model: string, input: BriefingInput) {
  return {
    provider: 'anthropic' as const,
    model,
    maxTokens: 8192,
    system: buildBriefingSystemPrompt(),
    messages: [{ role: 'user' as const, content: JSON.stringify(input) }],
    effort: 'low' as const,
    outputFormat: wireOutputFormat(zodOutputFormat(DayBriefSchema)),
  }
}

export async function generateDayBrief(
  input: BriefingInput,
  options: { credentialId: string; model: string },
): Promise<DayBrief> {
  try {
    const request: GatewayRequest = {
      ...buildBriefingRequestParams(options.model, input),
      credentialId: options.credentialId,
    }
    const { text, final } = await runAiTask(request)

    if (final.stopReason === 'refusal') {
      throw new AICaptureError('The model declined to prepare this brief.')
    }
    try {
      return DayBriefSchema.parse(JSON.parse(text))
    } catch {
      throw new AICaptureError('The reply did not match the expected shape. Try again.')
    }
  } catch (cause) {
    if (cause instanceof AICaptureError) throw cause
    if (cause instanceof GatewayError) {
      throw new AICaptureError(cause.message, cause.recoverable)
    }
    throw new AICaptureError('Could not reach the AI gateway. Nothing was lost.')
  }
}
