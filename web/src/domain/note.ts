/// A note: the record, and the two documents it is stored as.
///
/// ### Why the content is not in the note's document
/// Firestore's web SDK has no field projection — `select()` is Admin-only — so
/// a notes list that subscribes to the collection downloads every note's full
/// rich content in order to draw a list of titles. So the split:
///
/// - `notes/{id}` — metadata plus `bodyText`, the capped plain-text projection,
///   which is what rows, excerpts and search read.
/// - `noteContents/{id}` — the rich payload under the *same* id, read only when
///   a note is opened and written only when it is saved.
///
/// A sibling collection rather than a `notes/{id}/content/document`
/// subcollection, which was the first shape tried. Firestore does not cascade
/// deletes into subcollections, so that version needed a delete nobody could
/// forget to write, and left an invisible orphan when they did — invisible
/// because a subcollection under a deleted parent does not appear in the
/// console, while still being stored and still being billed. A sibling keyed by
/// the same id is removed by an ordinary write in the same batch, and is
/// covered by the same owner-only rule.
///
/// This is the same idea ADR 0006 settled for the Mac, where `Item.body` is the
/// derived plain text that feeds search and export while the rich payload sits
/// beside it. Here it additionally decides what a list costs to draw, which is
/// why it is a storage decision rather than an optimisation.

import { newID } from './ids'
import {
  emptyDocument,
  isDocumentEmpty,
  paragraphText,
  projectToText,
  type NoteDocument,
} from './noteDocument'
import type { WritePlan } from './writePlan'

export interface Note {
  id: string
  title: string
  /// The plain-text projection, capped. Never the source of truth — always
  /// recomputed from the document on save, so it cannot drift.
  bodyText: string
  containerID: string | null
  /// The people a note is about. A note about Maya belongs on Maya's page.
  personIDs: string[]
  pinnedAt: Date | null
  archivedAt: Date | null
  createdAt: Date
  updatedAt: Date
}

/// How much of the projection is kept on the note document.
///
/// Two kilobytes is roughly four hundred words: enough for an excerpt, enough
/// for search to find a note by something said in its first few paragraphs, and
/// small enough that subscribing to a few hundred notes stays cheap. Search
/// beyond it is a stated limit rather than a silent one — see
/// `SEARCH_ONLY_READS_THE_PROJECTION` below.
export const BODY_TEXT_CAP = 2048

export const SEARCH_ONLY_READS_THE_PROJECTION =
  'Search matches a note’s title and the first ~2 KB of its text, not its whole body.'

/// Firestore refuses a document over 1 MiB. Enforced here, before the write, so
/// a long note is refused with a sentence rather than discovered as a save that
/// silently did not happen.
export const MAX_DOCUMENT_BYTES = 1_048_576

/// A margin under the hard limit: the stored document also carries field names
/// and Firestore's own overhead, so writing right up to 1 MiB fails anyway.
export const DOCUMENT_BYTE_BUDGET = 900_000

export function documentByteSize(document: NoteDocument): number {
  // TextEncoder counts UTF-8 bytes, which is what the limit is measured in —
  // `string.length` counts UTF-16 units and would under-count every emoji.
  return new TextEncoder().encode(JSON.stringify(document)).byteLength
}

export function documentRefusal(document: NoteDocument): string | null {
  const size = documentByteSize(document)
  if (size <= DOCUMENT_BYTE_BUDGET) return null
  return `This note is too large to save (${Math.round(size / 1024)} KB of a 900 KB limit). Split it into two notes.`
}

/// The title a note shows when it has none of its own.
///
/// Taken from the first line with anything in it, the way every notes app the
/// user has met behaves. An untitled note is not an error state, so it is not
/// drawn as one.
export function derivedTitle(document: NoteDocument): string {
  for (const piece of document.pieces) {
    if (piece.type !== 'prose') continue
    const text = paragraphText(piece.paragraph).trim()
    if (text) return text.slice(0, 120)
  }
  return ''
}

export function displayTitle(note: Pick<Note, 'title' | 'bodyText'>): string {
  const title = note.title.trim()
  if (title) return title
  const firstLine = note.bodyText.split('\n').find((line) => line.trim())
  return firstLine?.trim().slice(0, 120) || 'Untitled note'
}

export function excerptOf(note: Pick<Note, 'title' | 'bodyText'>, length = 160): string | null {
  // Skip whichever line is already serving as the title, or every row reads
  // with its own heading repeated underneath it.
  const shown = displayTitle(note)
  const rest = note.bodyText
    .split('\n')
    .map((line) => line.replace(/^#{1,3}\s+|^>\s?|^-\s\[[ x]\]\s|^-\s|^\d+\.\s/, '').trim())
    .filter((line) => line && line !== shown)
    .join(' ')
  if (!rest) return null
  return rest.length <= length ? rest : `${rest.slice(0, length - 1).trimEnd()}…`
}

export interface NoteDraft {
  title?: string
  containerID?: string | null
  personIDs?: string[]
}

export function makeNote(draft: NoteDraft, now: Date): Note {
  return {
    id: newID(),
    title: draft.title?.trim() ?? '',
    bodyText: '',
    containerID: draft.containerID ?? null,
    personIDs: [...new Set(draft.personIDs ?? [])],
    pinnedAt: null,
    archivedAt: null,
    createdAt: now,
    updatedAt: now,
  }
}

/// Creating a note writes the metadata only. The content document is written by
/// the first save, so a note that is opened and abandoned leaves one small row
/// rather than two.
export function planCreateNote(draft: NoteDraft, now: Date): { plan: WritePlan; note: Note } {
  const note = makeNote(draft, now)
  return { plan: [{ op: 'set', collection: 'notes', id: note.id, data: note }], note }
}

export interface NoteContentWrite {
  plan: WritePlan
  bodyText: string
}

/// Saving a note: the content document and the metadata it implies, in one
/// plan, so the projection can never disagree with the document it came from.
///
/// The title is the user's when they gave one and the first line when they did
/// not — recomputed here rather than stored once at creation, or renaming the
/// first heading of an untitled note would leave the old text in every list.
export function planSaveNote(
  note: Note,
  document: NoteDocument,
  now: Date,
): { plan: WritePlan; bodyText: string; refusal: string | null } {
  const refusal = documentRefusal(document)
  if (refusal) return { plan: [], bodyText: note.bodyText, refusal }

  const projection = projectToText(document)
  const bodyText = projection.length > BODY_TEXT_CAP ? projection.slice(0, BODY_TEXT_CAP) : projection

  return {
    refusal: null,
    bodyText,
    plan: [
      {
        op: 'update',
        collection: 'notes',
        id: note.id,
        data: { title: note.title.trim(), bodyText, updatedAt: now },
      },
      {
        op: 'set',
        collection: 'noteContents',
        id: note.id,
        data: { ...document },
      },
    ],
  }
}

export function planUpdateNote(
  id: string,
  changes: Partial<Pick<Note, 'title' | 'containerID' | 'personIDs' | 'pinnedAt' | 'archivedAt'>>,
  now: Date,
): { plan: WritePlan } {
  return { plan: [{ op: 'update', collection: 'notes', id, data: { ...changes, updatedAt: now } }] }
}

/// Deleting a note deletes its content too, in the same batch.
///
/// Both writes or neither: a metadata row without its content opens as an empty
/// note, and content without its row is a document nothing will ever read
/// again. The atomic batch is what makes stating that enough.
export function planDeleteNote(id: string): { plan: WritePlan } {
  return {
    plan: [
      { op: 'delete', collection: 'noteContents', id },
      { op: 'delete', collection: 'notes', id },
    ],
  }
}

export { emptyDocument, isDocumentEmpty }
