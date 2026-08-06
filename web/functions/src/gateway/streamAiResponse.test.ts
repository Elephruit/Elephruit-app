/// The gateway against fakes: chunks must flow in order, the decrypted key
/// must be exactly what was encrypted for this record (context binding), and
/// every refusal path — bad shape, foreign credential, unknown model, rate
/// limits, concurrency — must fire BEFORE decryption. The canary test runs
/// the whole flow with an unmistakable secret as the key and asserts it
/// never reaches a log sink.

import { describe, expect, it } from 'vitest'
import { PublicError } from '../log/errors.js'
import { createLogger } from '../log/logger.js'
import { StreamCancelled, type NormalizedRequest, type ProviderAdapter } from '../providers/adapter.js'
import { MemoryStore, activeMetadata, fakeEncryption, silentLog } from '../testing/fakes.js'
import { handleStreamAiResponse, type GatewayDeps, type StreamSink } from './streamAiResponse.js'

const RAW_KEY = 'sk-ant-test-valid-00000000007XqP'

interface AdapterScript {
  chunks?: string[]
  error?: Error
  hangUntilAborted?: boolean
}

function makeAdapter(script: AdapterScript = {}) {
  const seen: { apiKey?: string; request?: NormalizedRequest } = {}
  const adapter: ProviderAdapter = {
    provider: 'anthropic',
    verifyKey: async () => ({ outcome: 'valid' }),
    async streamMessage(apiKey, request, signal, onText) {
      seen.apiKey = apiKey
      seen.request = request
      if (script.error) throw script.error
      if (script.hangUntilAborted) {
        while (!signal.aborted) await new Promise((resolve) => setTimeout(resolve, 5))
        throw new StreamCancelled()
      }
      for (const chunk of script.chunks ?? ['Hello ', 'world']) {
        if (signal.aborted) throw new StreamCancelled()
        await onText(chunk)
      }
      return { stopReason: 'end_turn' as const, usage: { inputTokens: 10, outputTokens: 5 } }
    },
  }
  return { adapter, seen }
}

function makeSink(signal?: AbortSignal): { sink: StreamSink; chunks: string[] } {
  const chunks: string[] = []
  return {
    chunks,
    sink: {
      sendChunk: async (chunk) => {
        chunks.push(chunk.text)
        return true
      },
      signal: signal ?? new AbortController().signal,
    },
  }
}

interface DepsOptions {
  adapterScript?: AdapterScript
  rateLimited?: boolean
  leaseDenied?: boolean
  sampleUsed?: boolean
  logSink?: { info(m: string, p?: unknown): void; warn(m: string, p?: unknown): void; error(m: string, p?: unknown): void }
  rawKey?: string
}

async function makeDeps(options: DepsOptions = {}) {
  const store = new MemoryStore()
  const encrypted = await fakeEncryption.encrypt(options.rawKey ?? RAW_KEY, {
    uid: 'alice',
    credentialId: 'cred-1',
    provider: 'anthropic',
  })
  await store.create('alice', 'cred-1', {
    metadata: activeMetadata(),
    privateDoc: {
      ownerUid: 'alice',
      provider: 'anthropic',
      ciphertext: encrypted.ciphertext,
      kmsKeyName: encrypted.kmsKeyName,
      createdAt: new Date('2026-08-01T00:00:00Z'),
      rotatedAt: null,
    },
  })

  const { adapter, seen } = makeAdapter(options.adapterScript)
  const leaseCalls = { acquired: 0, released: 0 }
  let decryptCalls = 0
  const auditTypes: string[] = []

  const deps: GatewayDeps = {
    store,
    encryption: {
      encrypt: fakeEncryption.encrypt,
      decrypt: (payload, ctx) => {
        decryptCalls += 1
        return fakeEncryption.decrypt(payload, ctx)
      },
    },
    adapters: { anthropic: adapter },
    rateLimiter: { consume: async () => !(options.rateLimited ?? false) },
    leases: {
      acquire: async () => {
        if (options.leaseDenied) return false
        leaseCalls.acquired += 1
        return true
      },
      release: async () => {
        leaseCalls.released += 1
      },
    },
    audit: async (_uid, event) => {
      auditTypes.push(event.type)
    },
    log: options.logSink ? createLogger(options.logSink) : silentLog,
    now: () => new Date('2026-08-06T12:00:00Z'),
    newRequestId: () => 'req-42',
    sampleUsedEvent: () => options.sampleUsed ?? false,
  }
  return { deps, store, seen, leaseCalls, auditTypes, decryptCalls: () => decryptCalls }
}

const goodRequest = {
  credentialId: 'cred-1',
  provider: 'anthropic',
  model: 'claude-opus-5',
  messages: [{ role: 'user', content: 'Coffee with Ana this morning.' }],
  system: 'You turn updates into proposals.',
  effort: 'low',
  outputFormat: { type: 'json_schema', schema: { properties: { participantNames: {} } } },
}

async function expectPublicError(promise: Promise<unknown>, code: string) {
  try {
    await promise
    expect.unreachable(`expected PublicError ${code}`)
  } catch (error) {
    expect(error).toBeInstanceOf(PublicError)
    expect((error as PublicError).code).toBe(code)
  }
}

describe('handleStreamAiResponse', () => {
  it('streams chunks in order and returns a normalized final', async () => {
    const { deps, seen, leaseCalls } = await makeDeps()
    const { sink, chunks } = makeSink()
    const final = await handleStreamAiResponse(deps, 'alice', goodRequest, sink)

    expect(chunks).toEqual(['Hello ', 'world'])
    expect(final).toEqual({ stopReason: 'end_turn', usage: { inputTokens: 10, outputTokens: 5 }, requestId: 'req-42' })
    expect(seen.apiKey).toBe(RAW_KEY)
    expect(leaseCalls).toEqual({ acquired: 1, released: 1 })
  })

  it('normalizes defaults and forwards the opaque output format', async () => {
    const { deps, seen } = await makeDeps()
    await handleStreamAiResponse(deps, 'alice', goodRequest, makeSink().sink)
    expect(seen.request?.maxTokens).toBe(8192)
    expect(seen.request?.effort).toBe('low')
    expect(seen.request?.system).toBe('You turn updates into proposals.')
    expect(seen.request?.outputFormat).toEqual(goodRequest.outputFormat)
  })

  it('rejects malformed shapes, oversized prompts, and oversized output formats', async () => {
    const { deps } = await makeDeps()
    const { sink } = makeSink()
    await expectPublicError(handleStreamAiResponse(deps, 'alice', { nonsense: true }, sink), 'INVALID_REQUEST')
    await expectPublicError(
      handleStreamAiResponse(
        deps,
        'alice',
        { ...goodRequest, messages: Array.from({ length: 5 }, () => ({ role: 'user', content: 'x'.repeat(50_000) })) },
        sink,
      ),
      'INVALID_REQUEST',
    )
    await expectPublicError(
      handleStreamAiResponse(
        deps,
        'alice',
        { ...goodRequest, outputFormat: { type: 'json_schema', pad: 'x'.repeat(33_000) } },
        sink,
      ),
      'INVALID_REQUEST',
    )
    await expectPublicError(
      handleStreamAiResponse(deps, 'alice', { ...goodRequest, outputFormat: { type: 'tool_use' } }, sink),
      'INVALID_REQUEST',
    )
  })

  it('enforces the model allowlist', async () => {
    const { deps } = await makeDeps()
    await expectPublicError(
      handleStreamAiResponse(deps, 'alice', { ...goodRequest, model: 'gpt-4' }, makeSink().sink),
      'UNSUPPORTED_MODEL',
    )
  })

  it("answers CREDENTIAL_NOT_FOUND for another user's credential id", async () => {
    const { deps, decryptCalls } = await makeDeps()
    await expectPublicError(handleStreamAiResponse(deps, 'bob', goodRequest, makeSink().sink), 'CREDENTIAL_NOT_FOUND')
    expect(decryptCalls()).toBe(0)
  })

  it('answers CREDENTIAL_NOT_FOUND when the stored provider disagrees', async () => {
    const { deps, store } = await makeDeps()
    store.records.get('alice/cred-1')!.privateDoc.provider = 'openai' as never
    await expectPublicError(handleStreamAiResponse(deps, 'alice', goodRequest, makeSink().sink), 'CREDENTIAL_NOT_FOUND')
  })

  it('rate-limits before touching the credential', async () => {
    const { deps, decryptCalls } = await makeDeps({ rateLimited: true })
    await expectPublicError(handleStreamAiResponse(deps, 'alice', goodRequest, makeSink().sink), 'RATE_LIMITED')
    expect(decryptCalls()).toBe(0)
  })

  it('caps concurrent streams before decrypting', async () => {
    const { deps, decryptCalls } = await makeDeps({ leaseDenied: true })
    await expectPublicError(
      handleStreamAiResponse(deps, 'alice', goodRequest, makeSink().sink),
      'TOO_MANY_CONCURRENT_STREAMS',
    )
    expect(decryptCalls()).toBe(0)
  })

  it('marks the credential invalid when the provider rejects the key mid-flight', async () => {
    const { deps, store, leaseCalls } = await makeDeps({
      adapterScript: { error: new PublicError('PROVIDER_AUTH_FAILED', 'rejected') },
    })
    await expectPublicError(handleStreamAiResponse(deps, 'alice', goodRequest, makeSink().sink), 'PROVIDER_AUTH_FAILED')
    await new Promise((resolve) => setImmediate(resolve))
    expect(store.records.get('alice/cred-1')?.metadata.status).toBe('invalid')
    expect(leaseCalls.released).toBe(1)
  })

  it('treats a client disconnect as a quiet cancellation and frees the lease', async () => {
    const controller = new AbortController()
    const { deps, leaseCalls } = await makeDeps({ adapterScript: { hangUntilAborted: true } })
    const { sink } = makeSink(controller.signal)
    setTimeout(() => controller.abort(), 20)
    const final = await handleStreamAiResponse(deps, 'alice', goodRequest, sink)
    expect(final.stopReason).toBe('other')
    expect(leaseCalls.released).toBe(1)
  })

  it('stamps lastUsedAt at most hourly', async () => {
    const fresh = await makeDeps()
    await handleStreamAiResponse(fresh.deps, 'alice', goodRequest, makeSink().sink)
    await new Promise((resolve) => setImmediate(resolve))
    expect(fresh.store.records.get('alice/cred-1')?.metadata.lastUsedAt).toEqual(new Date('2026-08-06T12:00:00Z'))

    const recent = await makeDeps()
    recent.store.records.get('alice/cred-1')!.metadata.lastUsedAt = new Date('2026-08-06T11:30:00Z')
    await handleStreamAiResponse(recent.deps, 'alice', goodRequest, makeSink().sink)
    await new Promise((resolve) => setImmediate(resolve))
    expect(recent.store.records.get('alice/cred-1')?.metadata.lastUsedAt).toEqual(new Date('2026-08-06T11:30:00Z'))
  })

  it('samples credential_used audit events', async () => {
    const sampled = await makeDeps({ sampleUsed: true })
    await handleStreamAiResponse(sampled.deps, 'alice', goodRequest, makeSink().sink)
    expect(sampled.auditTypes).toContain('credential_used')

    const unsampled = await makeDeps({ sampleUsed: false })
    await handleStreamAiResponse(unsampled.deps, 'alice', goodRequest, makeSink().sink)
    expect(unsampled.auditTypes).toEqual([])
  })

  it('CANARY: the raw key never reaches a log sink, a chunk, or the final result', async () => {
    const CANARY = 'TEST_SECRET_MUST_NEVER_APPEAR_IN_LOGS_12345'
    const logged: unknown[] = []
    const logSink = {
      info: (m: string, p?: unknown) => logged.push([m, p]),
      warn: (m: string, p?: unknown) => logged.push([m, p]),
      error: (m: string, p?: unknown) => logged.push([m, p]),
    }
    const { deps } = await makeDeps({ rawKey: CANARY, logSink, sampleUsed: true })
    const { sink, chunks } = makeSink()
    const final = await handleStreamAiResponse(deps, 'alice', goodRequest, sink)

    const everything = JSON.stringify({ logged, chunks, final })
    expect(everything).not.toContain(CANARY)
  })
})
