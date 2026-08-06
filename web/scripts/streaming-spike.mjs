// The gate for the BYOK gateway: does a streaming callable actually stream
// through the functions emulator, or does something buffer it? Chunks are sent
// 300ms apart server-side; if they arrive bunched together at the end, the
// transport is buffering and the gateway must fall back to onRequest + NDJSON.
//
// Run with the functions emulator up, or one-shot:
//   npx firebase emulators:exec --only functions --project demo-elephruit \
//     "node scripts/streaming-spike.mjs"

import { initializeApp } from 'firebase/app'
import { connectFunctionsEmulator, getFunctions, httpsCallable } from 'firebase/functions'

const app = initializeApp({ apiKey: 'demo-api-key', projectId: 'demo-elephruit' })
const functions = getFunctions(app, 'us-central1')
connectFunctionsEmulator(functions, '127.0.0.1', 5001)

function fail(message) {
  console.error(`SPIKE FAILED: ${message}`)
  process.exit(1)
}

const ping = httpsCallable(functions, 'gatewayPing')
const { stream, data } = await ping.stream({})

const arrivals = []
for await (const chunk of stream) {
  arrivals.push({ receivedAt: Date.now(), chunk })
}
const result = await data

if (arrivals.length !== 3) {
  fail(`expected 3 chunks, saw ${arrivals.length}`)
}
if (result?.done !== true || result?.acceptsStreaming !== true) {
  fail(`unexpected final result: ${JSON.stringify(result)}`)
}

const gaps = arrivals.slice(1).map((entry, i) => entry.receivedAt - arrivals[i].receivedAt)
console.log(`chunk arrival gaps (server spacing 300ms): ${gaps.join('ms, ')}ms`)

// Buffered delivery would collapse the gaps to near zero. Genuine streaming
// preserves roughly the server's spacing; 150ms leaves room for jitter.
if (!gaps.every((gap) => gap > 150)) {
  fail('chunks arrived bunched together — the emulator transport is buffering')
}

console.log('spike ok: streaming callable delivers incrementally through the emulator')
process.exit(0)
