/// The attachment worker: hashing, DOCX extraction, and image re-encoding off
/// the composer thread. (PDF parsing already runs in pdf.js's own dedicated
/// worker and stays on that path.) One request in, one reply out, matched by
/// id; errors travel as messages, never as silent drops.

import { extractDocx } from './extractDocx'
import { hashBytes } from './hashAttachment'
import { prepareImage } from './prepareImage'

export type WorkerRequest =
  | { id: number; task: 'hash'; buffer: ArrayBuffer }
  | { id: number; task: 'docx'; buffer: ArrayBuffer }
  | { id: number; task: 'image'; buffer: ArrayBuffer; mimeType: string }

export type WorkerReply =
  | { id: number; ok: true; result: string | { text: string } | { bytes: ArrayBuffer; mimeType: string } }
  | { id: number; ok: false; message: string }

self.onmessage = async (event: MessageEvent<WorkerRequest>) => {
  const request = event.data
  try {
    switch (request.task) {
      case 'hash': {
        const result = await hashBytes(request.buffer)
        postMessage({ id: request.id, ok: true, result } satisfies WorkerReply)
        break
      }
      case 'docx': {
        const result = await extractDocx(request.buffer)
        postMessage({ id: request.id, ok: true, result } satisfies WorkerReply)
        break
      }
      case 'image': {
        const result = await prepareImage(request.buffer, request.mimeType)
        postMessage({ id: request.id, ok: true, result } satisfies WorkerReply, { transfer: [result.bytes] })
        break
      }
    }
  } catch (cause) {
    postMessage({
      id: request.id,
      ok: false,
      message: cause instanceof Error ? cause.message : 'Worker task failed',
    } satisfies WorkerReply)
  }
}
