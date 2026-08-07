/// A folder: the first subject in this app that is not a person.
///
/// This began as two kinds, `project` and `folder`, on the reasoning that a
/// thing which ends and a thing which does not are different enough to name
/// apart. Used, they were not. Every folder still had to be filed somewhere,
/// listed the same way, and archived by the same action; the only thing the
/// distinction bought was a question at creation time — *what is it?* — asked
/// before the user necessarily knew, and a validation rule refusing dates on
/// the wrong one.
///
/// So: one kind. A folder holds things. Some folders have dates, because some
/// of them are trips; a folder with dates is not a different sort of object,
/// it is a folder with dates. Archiving works on any of them, and folders nest
/// in folders, which is the whole of what a filing system is.

import { newID } from './ids'
import type { PaletteColor } from './person'
import type { WritePlan } from './writePlan'

export interface Folder {
  id: string
  title: string
  summary: string | null
  colorName: PaletteColor
  parentID: string | null
  /// User-defined order among siblings. Older folders omit this and keep their
  /// alphabetical order until the first drag normalizes that branch.
  sortOrder?: number
  /// Optional, and descriptive rather than enforcing — a trip that runs late is
  /// still the trip, and nothing here turns red on its own.
  startAt: Date | null
  dueAt: Date | null
  /// Set by the archive. Present from the start so no document is ever missing
  /// the field and no read has to guess.
  archivedAt: Date | null
  createdAt: Date
  updatedAt: Date
}

export interface FolderDraft {
  title: string
  summary?: string | null
  colorName?: PaletteColor
  parentID?: string | null
  sortOrder?: number
  startAt?: Date | null
  dueAt?: Date | null
}

export function validateFolderDraft(draft: FolderDraft): string | null {
  if (!draft.title.trim()) return 'Give it a name.'
  if (draft.startAt && draft.dueAt && draft.startAt.getTime() > draft.dueAt.getTime()) {
    return 'It cannot end before it starts.'
  }
  return null
}

export function makeFolder(draft: FolderDraft, now: Date): Folder {
  return {
    id: newID(),
    title: draft.title.trim(),
    summary: draft.summary?.trim() || null,
    colorName: draft.colorName ?? 'blue',
    parentID: draft.parentID ?? null,
    ...(draft.sortOrder === undefined ? {} : { sortOrder: draft.sortOrder }),
    startAt: draft.startAt ?? null,
    dueAt: draft.dueAt ?? null,
    archivedAt: null,
    createdAt: now,
    updatedAt: now,
  }
}

export function planCreateFolder(draft: FolderDraft, now: Date): { plan: WritePlan; folder: Folder } {
  const folder = makeFolder(draft, now)
  return { plan: [{ op: 'set', collection: 'folders', id: folder.id, data: folder }], folder }
}

export type FolderChanges = Partial<
  Pick<Folder, 'title' | 'summary' | 'colorName' | 'parentID' | 'sortOrder' | 'startAt' | 'dueAt'>
>

export function planUpdateFolder(id: string, changes: FolderChanges, now: Date): { plan: WritePlan } {
  return { plan: [{ op: 'update', collection: 'folders', id, data: { ...changes, updatedAt: now } }] }
}

// MARK: - The tree

/// Every folder beneath `id`, at any depth, excluding `id` itself.
export function descendantIDs(folders: Folder[], id: string): Set<string> {
  const childrenOf = new Map<string | null, Folder[]>()
  for (const folder of folders) {
    const list = childrenOf.get(folder.parentID) ?? []
    list.push(folder)
    childrenOf.set(folder.parentID, list)
  }

  const found = new Set<string>()
  const queue = [id]
  while (queue.length > 0) {
    const current = queue.pop()
    if (current === undefined) continue
    for (const child of childrenOf.get(current) ?? []) {
      if (found.has(child.id)) continue
      found.add(child.id)
      queue.push(child.id)
    }
  }
  return found
}

/// Why a move is refused, or `null` when it is allowed.
///
/// The cycle check is the one that matters: dragging a folder into its own
/// descendant detaches the whole branch from the root, and because the tree is
/// built by walking down from `null`, the branch does not appear anywhere. It
/// is not corrupted — it is invisible, which is worse.
export function moveRefusal(folders: Folder[], subject: Folder, newParentID: string | null): string | null {
  if (newParentID === subject.id) return 'It cannot go inside itself.'
  if (newParentID === null) return null

  const parent = folders.find((folder) => folder.id === newParentID)
  if (!parent) return 'That folder no longer exists.'
  if (descendantIDs(folders, subject.id).has(newParentID)) {
    return 'It cannot go inside something it already contains.'
  }
  return null
}

export function planMoveFolder(
  folders: Folder[],
  subject: Folder,
  newParentID: string | null,
  now: Date,
): { plan: WritePlan } {
  const refusal = moveRefusal(folders, subject, newParentID)
  if (refusal) throw new Error(refusal)
  return planUpdateFolder(subject.id, { parentID: newParentID }, now)
}

function compareFolderOrder(a: Folder, b: Folder): number {
  if (a.sortOrder !== undefined && b.sortOrder !== undefined && a.sortOrder !== b.sortOrder) {
    return a.sortOrder - b.sortOrder
  }
  if (a.sortOrder !== undefined && b.sortOrder === undefined) return -1
  if (a.sortOrder === undefined && b.sortOrder !== undefined) return 1
  return a.title.localeCompare(b.title)
}

export function foldersInOrder(folders: Folder[], parentID: string | null): Folder[] {
  return folders.filter((folder) => folder.parentID === parentID).sort(compareFolderOrder)
}

/// Reparents and orders one folder in a single write plan. `beforeID` names a
/// sibling in the destination branch; `null` appends. Both the branch it left
/// and the branch it joins are normalized so every later read has one stable
/// order, including folders created before `sortOrder` existed.
export function planReorderFolder(
  folders: Folder[],
  subject: Folder,
  newParentID: string | null,
  beforeID: string | null,
  now: Date,
): { plan: WritePlan } {
  const refusal = moveRefusal(folders, subject, newParentID)
  if (refusal) throw new Error(refusal)

  const destination = foldersInOrder(folders, newParentID).filter((folder) => folder.id !== subject.id)
  const insertionIndex = beforeID === null ? destination.length : destination.findIndex((folder) => folder.id === beforeID)
  if (beforeID !== null && insertionIndex < 0) throw new Error('That drop position no longer exists.')
  destination.splice(insertionIndex, 0, subject)

  const source = subject.parentID === newParentID
    ? []
    : foldersInOrder(folders, subject.parentID).filter((folder) => folder.id !== subject.id)
  const writes = new Map<string, WritePlan[number]>()

  source.forEach((folder, sortOrder) => {
    writes.set(folder.id, {
      op: 'update', collection: 'folders', id: folder.id, data: { sortOrder, updatedAt: now },
    })
  })
  destination.forEach((folder, sortOrder) => {
    writes.set(folder.id, {
      op: 'update',
      collection: 'folders',
      id: folder.id,
      data: {
        sortOrder,
        ...(folder.id === subject.id ? { parentID: newParentID } : {}),
        updatedAt: now,
      },
    })
  })

  return { plan: [...writes.values()] }
}

export interface FolderNode {
  folder: Folder
  depth: number
  children: FolderNode[]
}

/// The tree, alphabetical at each level, which is the order a filing system
/// reads in. Folders whose parent is missing are hoisted to the root rather
/// than dropped — a dangling `parentID` is a bug, and hiding its victims is how
/// it stays one.
export function buildTree(folders: Folder[]): FolderNode[] {
  const known = new Set(folders.map((folder) => folder.id))
  const childrenOf = new Map<string | null, Folder[]>()

  for (const folder of folders) {
    const parentID = folder.parentID !== null && known.has(folder.parentID) ? folder.parentID : null
    const list = childrenOf.get(parentID) ?? []
    list.push(folder)
    childrenOf.set(parentID, list)
  }

  const build = (parentID: string | null, depth: number): FolderNode[] =>
    [...(childrenOf.get(parentID) ?? [])]
      .sort(compareFolderOrder)
      .map((folder) => ({ folder, depth, children: build(folder.id, depth + 1) }))

  return build(null, 0)
}

/// The tree flattened in reading order, for a list that draws its own indents.
export function flattenTree(nodes: FolderNode[]): FolderNode[] {
  return nodes.flatMap((node) => [node, ...flattenTree(node.children)])
}

/// The chain from the root down to and including `id`.
export function pathTo(folders: Folder[], id: string): Folder[] {
  const byID = new Map(folders.map((folder) => [folder.id, folder]))
  const chain: Folder[] = []
  const seen = new Set<string>()

  let current = byID.get(id)
  while (current && !seen.has(current.id)) {
    seen.add(current.id)
    chain.unshift(current)
    current = current.parentID ? byID.get(current.parentID) : undefined
  }
  return chain
}

/// "Travel / Chicago, October" — for the few places that need the whole path in
/// one line, such as a search result naming where something lives.
///
/// Not for pickers. A picker that spells the full path on every row repeats the
/// parent's name once per child, which is exactly what made the first filing
/// control unreadable; a picker should draw the tree and let the indent say it.
export function pathLabel(folders: Folder[], id: string): string {
  return pathTo(folders, id)
    .map((folder) => folder.title)
    .join(' / ')
}

// MARK: - Deletion

/// Deleting a folder never deletes what it holds.
///
/// A folder is a filing decision, and undoing a filing decision must not
/// destroy the things filed. So the children move up to the deleted folder's
/// own parent and its reminders and notes lose their `folderID` — the work
/// survives, where it can be found and re-filed. The alternative, a cascade,
/// means one wrong click on a trip takes eleven reminders with it, and
/// reminders have no supersede chain to recover from.
export function planDeleteFolder(
  subject: Folder,
  contents: { childFolders: Folder[]; reminderIDs: string[]; noteIDs: string[] },
  now: Date,
): { plan: WritePlan } {
  const plan: WritePlan = []

  for (const child of contents.childFolders) {
    if (child.parentID !== subject.id) continue
    plan.push({
      op: 'update',
      collection: 'folders',
      id: child.id,
      data: { parentID: subject.parentID, updatedAt: now },
    })
  }

  for (const reminderID of contents.reminderIDs) {
    plan.push({ op: 'update', collection: 'reminders', id: reminderID, data: { folderID: null } })
  }

  for (const noteID of contents.noteIDs) {
    plan.push({ op: 'update', collection: 'notes', id: noteID, data: { folderID: null, updatedAt: now } })
  }

  plan.push({ op: 'delete', collection: 'folders', id: subject.id })
  return { plan }
}

// MARK: - Archiving

/// Archiving a folder, and everything beneath it, in one plan.
///
/// The cascade is real here, unlike deletion, because archiving loses nothing:
/// it is a statement that this is finished, and it is undone by the exact
/// inverse below. A trip whose parent folder was archived while the trip stayed
/// live would be a trip you could not navigate to.
///
/// Reminders and notes are **not** touched. See ``isSuppressedByArchive`` for
/// why their status must survive intact.
export function planArchiveFolder(folders: Folder[], subject: Folder, now: Date): { plan: WritePlan } {
  const affected = [subject.id, ...descendantIDs(folders, subject.id)]
  return {
    plan: affected.map((id) => ({
      op: 'update' as const,
      collection: 'folders' as const,
      id,
      data: { archivedAt: now, updatedAt: now },
    })),
  }
}

/// Bringing one back, with everything that went with it.
///
/// Unarchiving a *child* alone would leave it live inside an archived parent —
/// reachable only from the archive, which is not what "unarchive" means to
/// anybody. So this restores the whole subtree, and additionally clears the
/// ancestors: you cannot have the trip back without having Travel back.
export function planUnarchiveFolder(folders: Folder[], subject: Folder, now: Date): { plan: WritePlan } {
  const affected = new Set<string>([
    subject.id,
    ...descendantIDs(folders, subject.id),
    ...pathTo(folders, subject.id).map((folder) => folder.id),
  ])
  return {
    plan: [...affected].map((id) => ({
      op: 'update' as const,
      collection: 'folders' as const,
      id,
      data: { archivedAt: null, updatedAt: now },
    })),
  }
}

export function isArchived(folder: Folder): boolean {
  return folder.archivedAt !== null && folder.archivedAt !== undefined
}

/// The ids of every archived folder, for the one question the buckets ask.
export function archivedFolderIDs(folders: Folder[]): Set<string> {
  return new Set(folders.filter(isArchived).map((folder) => folder.id))
}

/// Whether something should be left out of the day's lists because the folder
/// it belongs to is over.
///
/// This is the rule the whole archive turns on, and it is deliberately not the
/// obvious one. When a trip ends with "buy Pokémon tickets" still open, there
/// are three things the app could do and two of them are wrong:
///
/// - **Leave it in Overdue.** It reproaches you every morning for a museum you
///   are no longer going to. Archiving did nothing.
/// - **Mark it completed.** Nobody bought those tickets. Writing `completed`
///   would put a claim in the record that is simply false, and completion is
///   the one thing this app's counts are trusted for.
/// - **Take it out of the lists and leave its status alone.** It stops asking,
///   it stays open, and the folder still lists it under "Left open" — which is
///   the truth, and occasionally the interesting part of a finished trip.
export function isSuppressedByArchive(
  subject: { folderID?: string | null },
  archivedIDs: Set<string>,
): boolean {
  return subject.folderID !== null && subject.folderID !== undefined
    ? archivedIDs.has(subject.folderID)
    : false
}

/// The open reminders of an archived folder — the ones that never happened.
export function leftOpen<T extends { status: 'open' | 'completed' }>(reminders: T[]): T[] {
  return reminders.filter((reminder) => reminder.status === 'open')
}

// MARK: - Reading

export interface FolderProgress {
  done: number
  total: number
}

/// Counted over reminders already filtered to this folder. Reported as two
/// numbers rather than a fraction, because a folder with nothing in it has no
/// fraction and `0/0` is the honest answer to "how far along".
export function progressOf(reminders: Array<{ status: 'open' | 'completed' }>): FolderProgress {
  return {
    done: reminders.filter((reminder) => reminder.status === 'completed').length,
    total: reminders.length,
  }
}

export function progressSentence(progress: FolderProgress): string {
  if (progress.total === 0) return 'Nothing in it yet'
  if (progress.done === progress.total) return `All ${progress.total} done`
  return `${progress.done} of ${progress.total} done`
}

/// Whether this folder is worth showing dates for at all.
export function hasDates(folder: Folder): boolean {
  return folder.startAt !== null || folder.dueAt !== null
}
