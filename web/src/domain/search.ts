/// Search across everything the graph holds.
///
/// Firestore has no full-text search, and the honest options are a third-party
/// index or doing it on the client. At this app's scale it is the client:
/// people, reminders, observations and folders already subscribe as whole
/// collections, so the rows are in memory before anybody types. The ceiling is
/// real and stated at the bottom of this file rather than discovered.
///
/// ### Archived results appear by default
/// This is the load-bearing decision. Archiving is meant to move something out
/// of the way of today, not out of reach — a trip you took last year is exactly
/// the sort of thing you go looking for by name. So archived matches are found
/// without any token being typed, and collected into their own group below the
/// live ones rather than mixed in, because a finished thing and a live thing
/// answer different questions even when they match equally well.

import { archivedFolderIDs, type Folder } from './folder'
import type { Interaction } from './interaction'
import { displayTitle, type Note } from './note'
import { foldedForMatching, type Person } from './person'
import type { Reminder } from './reminders'

export type HitKind = 'person' | 'folder' | 'reminder' | 'interaction' | 'note'

export interface SearchHit {
  id: string
  kind: HitKind
  title: string
  /// The second line: a role, a path, a date — whatever tells two similar
  /// results apart.
  detail: string | null
  archived: boolean
  score: number
  /// Recency, for breaking ties between equally good matches.
  at: number
}

export interface SearchResults {
  live: SearchHit[]
  archived: SearchHit[]
}

/// How well `text` answers `query`, or 0 for no match.
///
/// Deliberately simple and explainable, the same standard the Mac app's ranking
/// holds itself to: a whole-word start beats a mid-word hit, a title beats a
/// body, and a user should be able to guess why something came first.
function scoreOf(text: string | null | undefined, folded: string, weight: number): number {
  if (!text) return 0
  const hay = foldedForMatching(text)
  if (!hay) return 0

  if (hay === folded) return weight * 2
  if (hay.startsWith(folded)) return weight * 1.5
  // A match at a word boundary — "field" in "the Field Museum" — reads as
  // intentional in a way that a match inside a word does not.
  if (hay.includes(` ${folded}`)) return weight * 1.25
  if (hay.includes(folded)) return weight
  return 0
}

const TITLE_WEIGHT = 40
const BODY_WEIGHT = 12

export interface SearchInput {
  people?: Person[]
  folders?: Folder[]
  reminders?: Reminder[]
  interactions?: Interaction[]
  notes?: Note[]
}

/// Everything matching, split into live and archived and ranked within each.
export function search(query: string, input: SearchInput, limit = 40): SearchResults {
  const folded = foldedForMatching(query)
  if (!folded) return { live: [], archived: [] }

  const folders = input.folders ?? []
  const archivedIDs = archivedFolderIDs(folders)
  const foldersByID = new Map(folders.map((folder) => [folder.id, folder]))
  const hits: SearchHit[] = []

  for (const person of input.people ?? []) {
    // A placeholder exists only so somebody could be mentioned; surfacing it in
    // search offers a record with nothing in it.
    if (person.isPlaceholder) continue
    const score =
      scoreOf(person.displayName, folded, TITLE_WEIGHT) +
      scoreOf(person.organizationName, folded, BODY_WEIGHT) +
      scoreOf(person.roleTitle, folded, BODY_WEIGHT)
    if (score === 0) continue
    hits.push({
      id: person.id,
      kind: 'person',
      title: person.displayName,
      detail: [person.roleTitle, person.organizationName].filter(Boolean).join(' · ') || null,
      archived: false,
      score,
      at: person.lastContactAt?.getTime() ?? person.createdAt?.getTime() ?? 0,
    })
  }

  for (const folder of folders) {
    const score = scoreOf(folder.title, folded, TITLE_WEIGHT) + scoreOf(folder.summary, folded, BODY_WEIGHT)
    if (score === 0) continue
    hits.push({
      id: folder.id,
      kind: 'folder',
      title: folder.title,
      detail: folder.summary,
      archived: archivedIDs.has(folder.id),
      score,
      at: folder.updatedAt?.getTime() ?? 0,
    })
  }

  for (const reminder of input.reminders ?? []) {
    const score = scoreOf(reminder.title, folded, TITLE_WEIGHT) + scoreOf(reminder.notes, folded, BODY_WEIGHT)
    if (score === 0) continue
    const folder = reminder.folderID ? foldersByID.get(reminder.folderID) : undefined
    hits.push({
      id: reminder.id,
      kind: 'reminder',
      title: reminder.title,
      detail: folder?.title ?? null,
      // A reminder is archived when the folder it belongs to is. It has no
      // archived flag of its own — one place to look, one place to be wrong.
      archived: reminder.folderID ? archivedIDs.has(reminder.folderID) : false,
      score,
      at: reminder.dueAt?.getTime() ?? reminder.createdAt?.getTime() ?? 0,
    })
  }

  for (const note of input.notes ?? []) {
    // The projection is capped at BODY_TEXT_CAP, so this matches a note's
    // title and roughly its first four hundred words rather than its whole
    // body — see SEARCH_ONLY_READS_THE_PROJECTION.
    const score = scoreOf(note.title, folded, TITLE_WEIGHT) + scoreOf(note.bodyText, folded, BODY_WEIGHT)
    if (score === 0) continue
    const folder = note.folderID ? foldersByID.get(note.folderID) : undefined
    hits.push({
      id: note.id,
      kind: 'note',
      title: displayTitle(note),
      detail: folder?.title ?? null,
      archived: note.folderID ? archivedIDs.has(note.folderID) : false,
      score,
      at: note.updatedAt?.getTime() ?? 0,
    })
  }

  for (const interaction of input.interactions ?? []) {
    const score =
      scoreOf(interaction.summary, folded, TITLE_WEIGHT) +
      scoreOf(interaction.discussion, folded, BODY_WEIGHT)
    if (score === 0) continue
    hits.push({
      id: interaction.id,
      kind: 'interaction',
      title: interaction.summary,
      detail: interaction.occurredAt?.toLocaleDateString() ?? null,
      archived: false,
      score,
      at: interaction.occurredAt?.getTime() ?? 0,
    })
  }

  const rank = (a: SearchHit, b: SearchHit) => b.score - a.score || b.at - a.at
  return {
    live: hits.filter((hit) => !hit.archived).sort(rank).slice(0, limit),
    archived: hits.filter((hit) => hit.archived).sort(rank).slice(0, limit),
  }
}

/// The point at which this stops being the right approach.
///
/// Every row is already in memory for other reasons, so search itself is free;
/// what is not free is holding them there. Interactions are the collection that
/// grows without bound, and the feed already caps its own subscription at 100.
/// If the library ever reaches a few thousand interactions, the answer is a
/// stored inverted index or a hosted one — not a bigger loop.
export const CLIENT_SEARCH_CEILING = 5000
