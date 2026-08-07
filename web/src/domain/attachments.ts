/// Attachments as capture inputs — the model, the limits, and the acceptance
/// rules, pure and testable. Files, raw bytes, and extracted text are
/// transient controller state: nothing here may ever enter a WritePlan or any
/// browser persistence. Extraction itself lives in src/attachments/.

export type AttachmentStatus = 'queued' | 'extracting' | 'ready' | 'error' | 'excluded'

export type AttachmentKind = 'pdf' | 'docx' | 'text' | 'table' | 'image'

export type AttachmentErrorCode =
  | 'unsupported-type'
  | 'type-mismatch'
  | 'file-too-large'
  | 'total-too-large'
  | 'too-many-files'
  | 'too-many-pages'
  | 'password-protected'
  | 'extraction-failed'
  | 'empty'

export interface CaptureAttachment {
  id: string
  file: File
  name: string
  detectedMimeType: string
  kind: AttachmentKind
  byteSize: number
  sha256: string | null
  status: AttachmentStatus
  pageCount: number | null
  extractedText: string | null
  requiresVision: boolean
  errorCode: AttachmentErrorCode | null
  errorMessage: string | null
}

// MARK: Limits — enforced before any provider transmission

export const ATTACHMENT_LIMITS = {
  maxFiles: 10,
  maxFileBytes: 20 * 1024 * 1024,
  maxTotalBytes: 50 * 1024 * 1024,
  maxExtractedPages: 150,
  maxRequestCharacters: 200_000,
} as const

// MARK: Supported types

interface TypeRule {
  kind: AttachmentKind
  extensions: string[]
  mimeTypes: string[]
}

const TYPE_RULES: TypeRule[] = [
  { kind: 'pdf', extensions: ['pdf'], mimeTypes: ['application/pdf'] },
  {
    kind: 'docx',
    extensions: ['docx'],
    mimeTypes: ['application/vnd.openxmlformats-officedocument.wordprocessingml.document'],
  },
  { kind: 'text', extensions: ['txt'], mimeTypes: ['text/plain'] },
  { kind: 'text', extensions: ['md', 'markdown'], mimeTypes: ['text/markdown', 'text/plain'] },
  { kind: 'table', extensions: ['csv'], mimeTypes: ['text/csv', 'text/plain', 'application/vnd.ms-excel'] },
  { kind: 'table', extensions: ['tsv'], mimeTypes: ['text/tab-separated-values', 'text/plain'] },
  { kind: 'image', extensions: ['png'], mimeTypes: ['image/png'] },
  { kind: 'image', extensions: ['jpg', 'jpeg'], mimeTypes: ['image/jpeg'] },
  { kind: 'image', extensions: ['webp'], mimeTypes: ['image/webp'] },
]

export function fileExtension(name: string): string {
  const dot = name.lastIndexOf('.')
  return dot === -1 ? '' : name.slice(dot + 1).toLowerCase()
}

export function kindForExtension(name: string): AttachmentKind | null {
  const extension = fileExtension(name)
  return TYPE_RULES.find((rule) => rule.extensions.includes(extension))?.kind ?? null
}

/// The picker's accept list, from the same rules the validator enforces.
export function acceptList(): string {
  return TYPE_RULES.flatMap((rule) => rule.extensions.map((e) => `.${e}`)).join(',')
}

/// Whether a detected (sniffed) MIME type is plausible for the extension. A
/// mismatch is a rejection, not a guess — a renamed executable must not ride
/// in on a friendly extension.
export function mimeMatchesExtension(name: string, detectedMimeType: string): boolean {
  const extension = fileExtension(name)
  const rule = TYPE_RULES.find((r) => r.extensions.includes(extension))
  if (!rule) return false
  return rule.mimeTypes.includes(detectedMimeType)
}

// MARK: Pre-extraction validation

export interface FileFacts {
  name: string
  byteSize: number
}

export function validateSelection(
  candidate: FileFacts,
  existing: FileFacts[],
): { ok: true } | { ok: false; code: AttachmentErrorCode; message: string } {
  if (kindForExtension(candidate.name) === null) {
    return {
      ok: false,
      code: 'unsupported-type',
      message: `${candidate.name} is not a supported type. PDF, Word (.docx), text, Markdown, CSV/TSV, and images work here.`,
    }
  }
  if (candidate.byteSize > ATTACHMENT_LIMITS.maxFileBytes) {
    return {
      ok: false,
      code: 'file-too-large',
      message: `${candidate.name} is ${formatBytes(candidate.byteSize)} — the limit is ${formatBytes(ATTACHMENT_LIMITS.maxFileBytes)} per file.`,
    }
  }
  if (existing.length + 1 > ATTACHMENT_LIMITS.maxFiles) {
    return {
      ok: false,
      code: 'too-many-files',
      message: `A capture can carry at most ${ATTACHMENT_LIMITS.maxFiles} files.`,
    }
  }
  const total = existing.reduce((sum, file) => sum + file.byteSize, 0) + candidate.byteSize
  if (total > ATTACHMENT_LIMITS.maxTotalBytes) {
    return {
      ok: false,
      code: 'total-too-large',
      message: `Together these files exceed ${formatBytes(ATTACHMENT_LIMITS.maxTotalBytes)}. Remove one before adding more.`,
    }
  }
  return { ok: true }
}

/// Duplicate detection: SHA-256 when both sides have one, otherwise
/// name + size (+ lastModified when known).
export function isDuplicate(
  candidate: { name: string; byteSize: number; sha256?: string | null; lastModified?: number },
  existing: Array<{ name: string; byteSize: number; sha256?: string | null; lastModified?: number }>,
): boolean {
  return existing.some((entry) => {
    if (candidate.sha256 && entry.sha256) return candidate.sha256 === entry.sha256
    return (
      entry.name === candidate.name &&
      entry.byteSize === candidate.byteSize &&
      (entry.lastModified === undefined || candidate.lastModified === undefined || entry.lastModified === candidate.lastModified)
    )
  })
}

// MARK: Extraction outcomes

/// A PDF is likely scanned when most pages carry almost no text.
export function isLikelyScanned(pageCharCounts: number[]): boolean {
  if (pageCharCounts.length === 0) return true
  const sparse = pageCharCounts.filter((count) => count < 50).length
  return sparse / pageCharCounts.length > 0.6
}

export function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}

/// The status line an attachment row shows.
export function attachmentStatusLine(attachment: CaptureAttachment): string {
  switch (attachment.status) {
    case 'queued':
    case 'extracting':
      return 'Reading…'
    case 'ready':
      if (attachment.requiresVision)
        return attachment.pageCount !== null
          ? `Needs visual reading · ${attachment.pageCount} page${attachment.pageCount === 1 ? '' : 's'}`
          : 'Needs visual reading'
      return attachment.pageCount !== null
        ? `Ready · ${attachment.pageCount} page${attachment.pageCount === 1 ? '' : 's'}`
        : 'Ready'
    case 'error':
      return attachment.errorMessage ?? 'Could not read this file.'
    case 'excluded':
      return 'Excluded from this capture'
  }
}

/// Whether review can proceed: every included attachment is ready, excluded,
/// or removed — never still extracting or sitting on an unhandled error.
export function attachmentsReadyForReview(attachments: CaptureAttachment[]): boolean {
  return attachments.every(
    (attachment) => attachment.status === 'ready' || attachment.status === 'excluded',
  )
}
