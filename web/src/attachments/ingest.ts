/// The ingestion orchestrator: validate, sniff, hash, extract — producing a
/// CaptureAttachment the controller can hold. Local only; nothing here talks
/// to any provider. Aborting (file removed, composer discarded) cancels the
/// remaining work for that file.

import {
  ATTACHMENT_LIMITS,
  kindForExtension,
  mimeMatchesExtension,
  type AttachmentErrorCode,
  type CaptureAttachment,
} from '../domain/attachments'
import { newID } from '../domain/ids'
import { extractPdf, PdfPageLimitError, PdfPasswordError } from './extractPdf'
import { extractTable } from './extractTable'
import { extractText } from './extractText'
import { sniffMimeType } from './validateAttachment'
import type { WorkerReply, WorkerRequest } from './attachment.worker'

let worker: Worker | null = null
let nextRequestID = 1
const pending = new Map<number, { resolve: (reply: WorkerReply) => void }>()

function ensureWorker(): Worker {
  if (!worker) {
    worker = new Worker(new URL('./attachment.worker.ts', import.meta.url), { type: 'module' })
    worker.onmessage = (event: MessageEvent<WorkerReply>) => {
      pending.get(event.data.id)?.resolve(event.data)
      pending.delete(event.data.id)
    }
  }
  return worker
}

type DistributiveOmit<T, K extends PropertyKey> = T extends unknown ? Omit<T, K> : never

function callWorker(request: DistributiveOmit<WorkerRequest, 'id'>, transfer: Transferable[] = []): Promise<WorkerReply> {
  const id = nextRequestID++
  return new Promise((resolve) => {
    pending.set(id, { resolve })
    ensureWorker().postMessage({ ...request, id }, transfer)
  })
}

export interface IngestResult {
  attachment: CaptureAttachment
  /// For images: the re-encoded bytes that may travel (never the original).
  preparedImage: { bytes: ArrayBuffer; mimeType: string } | null
}

function failed(base: CaptureAttachment, code: AttachmentErrorCode, message: string): IngestResult {
  return { attachment: { ...base, status: 'error', errorCode: code, errorMessage: message }, preparedImage: null }
}

export async function ingestFile(file: File, signal?: AbortSignal): Promise<IngestResult> {
  const kind = kindForExtension(file.name) ?? 'text'
  const base: CaptureAttachment = {
    id: newID(),
    file,
    name: file.name,
    detectedMimeType: '',
    kind,
    byteSize: file.size,
    sha256: null,
    status: 'extracting',
    pageCount: null,
    extractedText: null,
    requiresVision: false,
    errorCode: null,
    errorMessage: null,
  }

  const detected = await sniffMimeType(file)
  if (!detected || !mimeMatchesExtension(file.name, detected)) {
    return failed(
      base,
      'type-mismatch',
      `${file.name} does not look like what its name says — it was not added.`,
    )
  }
  base.detectedMimeType = detected

  const buffer = await file.arrayBuffer()
  const hashReply = await callWorker({ task: 'hash', buffer: buffer.slice(0) })
  if (hashReply.ok && typeof hashReply.result === 'string') base.sha256 = hashReply.result
  if (signal?.aborted) return failed(base, 'extraction-failed', 'Cancelled.')

  try {
    switch (kind) {
      case 'pdf': {
        const extraction = await extractPdf(file, ATTACHMENT_LIMITS.maxExtractedPages, signal)
        return {
          attachment: {
            ...base,
            status: 'ready',
            pageCount: extraction.pageCount,
            extractedText: extraction.requiresVision ? null : extraction.text,
            requiresVision: extraction.requiresVision,
          },
          preparedImage: null,
        }
      }
      case 'docx': {
        const reply = await callWorker({ task: 'docx', buffer }, [buffer])
        if (!reply.ok) return failed(base, 'extraction-failed', 'This Word file could not be read.')
        const text = (reply.result as { text: string }).text
        if (!text) return failed(base, 'empty', `${file.name} contains no readable text.`)
        return { attachment: { ...base, status: 'ready', extractedText: text }, preparedImage: null }
      }
      case 'text': {
        const text = (await extractText(file)).trim()
        if (!text) return failed(base, 'empty', `${file.name} is empty.`)
        return { attachment: { ...base, status: 'ready', extractedText: text }, preparedImage: null }
      }
      case 'table': {
        const text = await extractTable(file, file.name.toLowerCase().endsWith('.tsv') ? '\t' : ',')
        if (!text) return failed(base, 'empty', `${file.name} is empty.`)
        return { attachment: { ...base, status: 'ready', extractedText: text }, preparedImage: null }
      }
      case 'image': {
        const reply = await callWorker({ task: 'image', buffer, mimeType: detected }, [buffer])
        if (!reply.ok) return failed(base, 'extraction-failed', 'This image could not be processed.')
        const prepared = reply.result as { bytes: ArrayBuffer; mimeType: string }
        return {
          attachment: { ...base, status: 'ready', requiresVision: true },
          preparedImage: prepared,
        }
      }
    }
  } catch (cause) {
    if (cause instanceof PdfPasswordError) {
      return failed(base, 'password-protected', 'This PDF is password-protected and cannot be read.')
    }
    if (cause instanceof PdfPageLimitError) {
      return failed(
        base,
        'too-many-pages',
        `${file.name} has ${cause.pageCount} pages — the limit is ${ATTACHMENT_LIMITS.maxExtractedPages} per capture.`,
      )
    }
    if ((cause as DOMException)?.name === 'AbortError') {
      return failed(base, 'extraction-failed', 'Cancelled.')
    }
    return failed(base, 'extraction-failed', `${file.name} could not be read.`)
  }
}
