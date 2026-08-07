/// The emulator's stand-in provider: deterministic streams, no network, so
/// the whole AI loop — including the browser walk and the attack smoke —
/// runs offline. Canned payloads satisfy the client's real zod schemas;
/// which payload to serve is inferred from marker properties in the
/// forwarded output format. Every outcome tags itself adapter:'fake' so a
/// test can prove no real provider was contacted.
///
/// Test keys: anything containing "-invalid" fails auth, "-flaky" fails as
/// unavailable; everything else (a stray real key included) succeeds
/// locally without being sent anywhere.

import { PublicError } from '../log/errors.js'
import { StreamCancelled, type NormalizedRequest, type ProviderAdapter, type StreamOutcome } from './adapter.js'
import type { ProviderId } from './types.js'
import { fakeVerifyKey } from './verify.js'

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))

function cannedCaptureProposal(): unknown {
  return {
    interaction: {
      kind: 'in-person',
      summary: 'Coffee with Ana — caught up on the move',
      discussion: 'Ana settled into the new place; her son started at Roosevelt.',
    },
    participantNames: ['Ana Torres'],
    facts: [{ personName: 'Ana Torres', attribute: 'city', value: 'Portland', confidence: 'stated' }],
    relationships: [
      {
        subjectName: 'Ana Torres',
        kind: 'child',
        label: 'son',
        otherName: null,
        facts: [{ attribute: 'school', value: 'Roosevelt' }],
      },
    ],
    followUps: [
      {
        title: 'Send the neighborhood list by Friday',
        personNames: ['Ana Torres'],
        notes: null,
        schedule: {
          mode: 'deadline',
          localDate: nextFriday(),
          localTime: null,
          timeZone: null,
          sourceText: 'by Friday',
          confidence: 'stated',
        },
      },
    ],
  }
}

/// The canned deadline stays in the near future whenever the walk happens.
function nextFriday(): string {
  const d = new Date()
  d.setDate(d.getDate() + (((5 - d.getDay()) % 7 || 7)))
  const pad = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`
}

function cannedDayBrief(request: NormalizedRequest): unknown {
  const names = briefedNames(request)
  return {
    people: names.map((name) => ({
      name,
      headline: `Things are steady with ${name} — one open loop.`,
      talkingPoints: ['The move went well', 'Ask about the new routine'],
      myNextMoves: ['You still owe the neighborhood list'],
      statusQuestions: ['Did the school enrollment go through?'],
      suggestedQuestions: [`What is ${name.split(' ')[0]} enjoying about the new place?`],
    })),
    dayNote: names.length > 1 ? 'A light day — two conversations, both warm.' : null,
  }
}

/// Flatten message content to text for marker sniffing — block arrays carry
/// their text blocks, attachments contribute nothing.
function contentAsText(content: NormalizedRequest['messages'][number]['content'] | undefined): string {
  if (typeof content === 'string') return content
  if (!content) return ''
  return content
    .map((block) => (block.type === 'text' ? block.text : ''))
    .join('\n')
}

/// A canned dossier keyed to the [File: … (id)] headers in the request, so
/// provenance rows in the review point at the real attachments.
function cannedDossier(request: NormalizedRequest): unknown {
  const text = contentAsText(request.messages[0]?.content)
  const ids = [...text.matchAll(/\[File: .+? \(([^)]+)\)\]/g)].map((match) => match[1])
  const source = ids[0] ?? 'file-1'
  return {
    subject: { proposedName: 'Kelly Tsaur', roleTitle: 'Head of Payer/Provider Industry Vertical', organizationName: 'ZS' },
    facts: [
      {
        attribute: 'role',
        value: 'Head of Payer/Provider Industry Vertical',
        confidence: 'stated',
        sensitivity: 'normal',
        evidence: 'Kelly Tsaur, Head of Payer/Provider Industry Vertical',
        sourceAttachmentID: source,
        pageNumber: 1,
      },
      {
        attribute: 'employer',
        value: 'ZS',
        confidence: 'stated',
        sensitivity: 'normal',
        evidence: 'joined ZS in 2019',
        sourceAttachmentID: source,
        pageNumber: 1,
      },
      {
        attribute: 'location',
        value: 'Chicago',
        confidence: 'inferred',
        sensitivity: 'normal',
        evidence: 'based in the Chicago office',
        sourceAttachmentID: source,
        pageNumber: 2,
      },
      {
        attribute: 'health',
        value: 'Recovering from knee surgery',
        confidence: 'stated',
        sensitivity: 'sensitive',
        evidence: 'out for two weeks after knee surgery',
        sourceAttachmentID: source,
        pageNumber: 2,
      },
    ],
    relationships: [
      {
        kind: 'colleague',
        label: null,
        otherName: 'Harbinder Raina',
        facts: [
          {
            attribute: 'employer',
            value: 'ZS',
            evidence: 'works alongside Harbinder Raina',
            sourceAttachmentID: source,
            pageNumber: 1,
          },
        ],
      },
    ],
    followUps: [
      {
        title: 'Review the payer landscape deck before the intro call',
        evidence: 'suggest reviewing the payer landscape deck',
        sourceAttachmentID: source,
        pageNumber: 3,
      },
    ],
    warnings: ['A phone number in the document was omitted.'],
  }
}

/// The day-brief input is JSON in the single user message; echo its people
/// so the UI shows real names during a browser walk.
function briefedNames(request: NormalizedRequest): string[] {
  try {
    const input = JSON.parse(contentAsText(request.messages[0]?.content) || '{}') as {
      people?: Array<{ name?: unknown }>
    }
    const names = (input.people ?? [])
      .map((person) => person.name)
      .filter((name): name is string => typeof name === 'string' && name.length > 0)
    if (names.length > 0) return names
  } catch {
    // Not JSON — fall through to the fixture name.
  }
  return ['Ana Torres']
}

function cannedText(request: NormalizedRequest): string {
  const format = request.outputFormat ? JSON.stringify(request.outputFormat) : ''
  if (format.includes('sourceAttachmentID')) return JSON.stringify(cannedDossier(request))
  if (format.includes('participantNames')) return JSON.stringify(cannedCaptureProposal())
  if (format.includes('talkingPoints')) return JSON.stringify(cannedDayBrief(request))
  return 'A canned reply from the emulator fake adapter.'
}

export function fakeAdapterFor(provider: ProviderId): ProviderAdapter {
  return {
    provider,
    verifyKey: fakeVerifyKey,

    async streamMessage(apiKey, request, signal, onText): Promise<StreamOutcome> {
      if (apiKey.includes('-invalid')) {
        throw new PublicError('PROVIDER_AUTH_FAILED', 'The provider rejected this key. Verify or replace it in Settings.')
      }
      if (apiKey.includes('-flaky')) {
        throw new PublicError('PROVIDER_UNAVAILABLE', 'The provider could not be reached. Nothing was lost.')
      }

      const text = cannedText(request)
      const third = Math.ceil(text.length / 3)
      for (let index = 0; index < text.length; index += third) {
        if (signal.aborted) throw new StreamCancelled()
        await onText(text.slice(index, index + third))
        await sleep(80)
      }
      return {
        stopReason: 'end_turn',
        usage: { inputTokens: 128, outputTokens: Math.ceil(text.length / 4) },
        adapter: 'fake',
      }
    },
  }
}

export const fakeAdapter = fakeAdapterFor('anthropic')
