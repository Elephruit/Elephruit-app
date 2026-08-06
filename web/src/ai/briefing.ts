/// The read direction of the AI street: turning the domain-assembled briefing
/// payload into talking points. Same posture as capture parsing — the user's
/// own key, browser-direct, schema-validated output, and the model sees only
/// what domain/briefing.ts decided it may see.

import Anthropic from '@anthropic-ai/sdk'
import { zodOutputFormat } from '@anthropic-ai/sdk/helpers/zod'
import { z } from 'zod'
import type { BriefingInput } from '../domain/briefing'
import { AICaptureError } from './anthropic'

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
    'For each person: a one-line headline of where things stand; two to four talking points grounded in recorded facts and recent conversations; open loops the user owes them, drawn from the follow-ups; one to three questions worth asking, favoring what has changed lately or is going stale.',
    'Confidence labels like "Estimated" mean the record is uncertain — phrase those as things to confirm, not facts to assert.',
    'Write in plain, warm, second-person prose ("ask her", "you owe him"). No emoji, no headers inside strings, no markdown.',
  ].join('\n')
}

export function buildBriefingRequestParams(model: string, input: BriefingInput) {
  return {
    model,
    max_tokens: 8192,
    system: buildBriefingSystemPrompt(),
    messages: [{ role: 'user' as const, content: JSON.stringify(input) }],
    output_config: {
      effort: 'low' as const,
      format: zodOutputFormat(DayBriefSchema),
    },
  }
}

export async function generateDayBrief(
  input: BriefingInput,
  options: { apiKey: string; model: string },
): Promise<DayBrief> {
  const client = new Anthropic({ apiKey: options.apiKey, dangerouslyAllowBrowser: true })

  try {
    const response = await client.messages.parse(buildBriefingRequestParams(options.model, input))

    if (response.stop_reason === 'refusal') {
      throw new AICaptureError('The model declined to prepare this brief.')
    }

    const brief = response.parsed_output
    if (!brief) {
      throw new AICaptureError('The reply did not match the expected shape. Try again.')
    }
    return brief
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
    throw new AICaptureError('Could not reach the API. Nothing was lost.')
  }
}
