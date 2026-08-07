/// Source provenance without raw-file retention. When a dossier's proposals
/// are saved, this metadata is written beside them — filename, type, size,
/// hash, page count — so every fact can say where it came from, while the
/// file itself is never stored anywhere. rawFileRetained is a literal false:
/// a schema-level promise, not a setting.

import { newID } from './ids'
import type { WritePlan } from './writePlan'

export interface SourceDocument {
  id: string
  kind: 'dossier'
  displayName: string
  mimeType: string
  byteSize: number
  sha256: string
  pageCount: number | null
  importedAt: Date
  rawFileRetained: false
}

export function makeSourceDocument(
  args: {
    displayName: string
    mimeType: string
    byteSize: number
    sha256: string
    pageCount: number | null
  },
  now: Date,
): SourceDocument {
  return {
    id: newID(),
    kind: 'dossier',
    displayName: args.displayName,
    mimeType: args.mimeType,
    byteSize: args.byteSize,
    sha256: args.sha256,
    pageCount: args.pageCount,
    importedAt: now,
    rawFileRetained: false,
  }
}

export function planSourceDocument(source: SourceDocument): WritePlan {
  return [{ op: 'set', collection: 'sources', id: source.id, data: source }]
}
