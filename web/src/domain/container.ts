/// The first subject in this app that is not a person.
///
/// A project and a folder are the same shape — a named thing that other things
/// live in — and the only difference that earns a field is whether it *ends*. A
/// trip to Chicago has dates, a sense of done, and an archive waiting for it; a
/// folder called Travel has none of those and never will. So one collection,
/// one `kind`, and every query, rule and archive path written once.
///
/// Containers hold reminders (and, later, notes). They never hold interactions:
/// an interaction is something that happened with a person, and the person is
/// what it belongs to.

import { newID } from './ids'
import type { PaletteColor } from './person'
import type { WritePlan } from './writePlan'

export const CONTAINER_KINDS = ['project', 'folder'] as const
export type ContainerKind = (typeof CONTAINER_KINDS)[number]

export const CONTAINER_KIND_LABELS: Record<ContainerKind, string> = {
  project: 'Project',
  folder: 'Folder',
}

/// Only a project has one. A folder is never done, which is what makes it a
/// folder.
export type ContainerStatus = 'active' | 'completed'

export interface Container {
  id: string
  kind: ContainerKind
  title: string
  summary: string | null
  colorName: PaletteColor
  /// Folders nest inside folders; a project sits in a folder or at the root.
  parentID: string | null
  /// Projects only. Descriptive, not enforcing — a trip that runs late is still
  /// the trip, and nothing here turns red on its own.
  startAt: Date | null
  dueAt: Date | null
  /// Projects only; folders are always active.
  status: ContainerStatus
  /// Set by the archive, phase 3. Present from the start so no document is ever
  /// missing the field and no read has to guess.
  archivedAt: Date | null
  createdAt: Date
  updatedAt: Date
}

/// Whether a container of `parentKind` may hold one of `childKind`.
///
/// A project holds no containers. A project inside a project is a heading, and
/// a heading is a different feature with a different shape — allowing it here
/// would mean the tree could be six deep before anybody noticed, and every
/// count would have to decide how far down to look.
export function canContain(parentKind: ContainerKind, childKind: ContainerKind): boolean {
  return parentKind === 'folder' && (childKind === 'folder' || childKind === 'project')
}

/// The fields only a project may carry. Kept as one list so the validator, the
/// editor and the kind-change path cannot disagree about it.
export const PROJECT_ONLY_FIELDS = ['startAt', 'dueAt', 'status'] as const

export interface ContainerDraft {
  kind: ContainerKind
  title: string
  summary?: string | null
  colorName?: PaletteColor
  parentID?: string | null
  startAt?: Date | null
  dueAt?: Date | null
}

export function validateContainerDraft(draft: ContainerDraft): string | null {
  if (!draft.title.trim()) return 'Give it a name.'
  if (draft.kind === 'folder' && (draft.startAt || draft.dueAt)) {
    return 'A folder has no dates. Make it a project if it ends.'
  }
  if (draft.startAt && draft.dueAt && draft.startAt.getTime() > draft.dueAt.getTime()) {
    return 'It cannot end before it starts.'
  }
  return null
}

export function makeContainer(draft: ContainerDraft, now: Date): Container {
  const isProject = draft.kind === 'project'
  return {
    id: newID(),
    kind: draft.kind,
    title: draft.title.trim(),
    summary: draft.summary?.trim() || null,
    colorName: draft.colorName ?? 'blue',
    parentID: draft.parentID ?? null,
    startAt: isProject ? (draft.startAt ?? null) : null,
    dueAt: isProject ? (draft.dueAt ?? null) : null,
    status: 'active',
    archivedAt: null,
    createdAt: now,
    updatedAt: now,
  }
}

export function planCreateContainer(
  draft: ContainerDraft,
  now: Date,
): { plan: WritePlan; container: Container } {
  const container = makeContainer(draft, now)
  return {
    plan: [{ op: 'set', collection: 'containers', id: container.id, data: container }],
    container,
  }
}

export type ContainerChanges = Partial<
  Pick<Container, 'title' | 'summary' | 'colorName' | 'parentID' | 'startAt' | 'dueAt' | 'status'>
>

export function planUpdateContainer(id: string, changes: ContainerChanges, now: Date): { plan: WritePlan } {
  return { plan: [{ op: 'update', collection: 'containers', id, data: { ...changes, updatedAt: now } }] }
}

// MARK: - The tree

/// Every container beneath `id`, at any depth, excluding `id` itself.
export function descendantIDs(containers: Container[], id: string): Set<string> {
  const childrenOf = new Map<string | null, Container[]>()
  for (const container of containers) {
    const list = childrenOf.get(container.parentID) ?? []
    list.push(container)
    childrenOf.set(container.parentID, list)
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
export function moveRefusal(
  containers: Container[],
  subject: Container,
  newParentID: string | null,
): string | null {
  if (newParentID === subject.id) return 'It cannot go inside itself.'
  if (newParentID === null) return null

  const parent = containers.find((container) => container.id === newParentID)
  if (!parent) return 'That folder no longer exists.'
  if (!canContain(parent.kind, subject.kind)) {
    return parent.kind === 'project'
      ? 'A project holds work, not folders.'
      : `A ${CONTAINER_KIND_LABELS[parent.kind].toLowerCase()} cannot hold that.`
  }
  if (descendantIDs(containers, subject.id).has(newParentID)) {
    return 'It cannot go inside something it already contains.'
  }
  return null
}

export function planMoveContainer(
  containers: Container[],
  subject: Container,
  newParentID: string | null,
  now: Date,
): { plan: WritePlan } {
  const refusal = moveRefusal(containers, subject, newParentID)
  if (refusal) throw new Error(refusal)
  return planUpdateContainer(subject.id, { parentID: newParentID }, now)
}

export interface ContainerNode {
  container: Container
  depth: number
  children: ContainerNode[]
}

/// The tree, folders before projects and alphabetical within each, which is the
/// order a filing system reads in. Containers whose parent is missing are
/// hoisted to the root rather than dropped — a dangling `parentID` is a bug, and
/// hiding its victims is how it stays one.
export function buildTree(containers: Container[]): ContainerNode[] {
  const known = new Set(containers.map((container) => container.id))
  const childrenOf = new Map<string | null, Container[]>()

  for (const container of containers) {
    const parentID = container.parentID !== null && known.has(container.parentID) ? container.parentID : null
    const list = childrenOf.get(parentID) ?? []
    list.push(container)
    childrenOf.set(parentID, list)
  }

  const sort = (list: Container[]) =>
    [...list].sort((a, b) => {
      if (a.kind !== b.kind) return a.kind === 'folder' ? -1 : 1
      return a.title.localeCompare(b.title)
    })

  const build = (parentID: string | null, depth: number): ContainerNode[] =>
    sort(childrenOf.get(parentID) ?? []).map((container) => ({
      container,
      depth,
      children: build(container.id, depth + 1),
    }))

  return build(null, 0)
}

/// The tree flattened in reading order, for a list that draws its own indents.
export function flattenTree(nodes: ContainerNode[]): ContainerNode[] {
  return nodes.flatMap((node) => [node, ...flattenTree(node.children)])
}

/// The label a picker shows: "Travel / Chicago, October".
///
/// A path rather than a leading indent, because a `<select>` shows the chosen
/// option with its indent still attached — "— Chicago, October" reads as a
/// stray dash, and says nothing about which Travel it is when there are two.
export function pathLabel(containers: Container[], id: string): string {
  return pathTo(containers, id)
    .map((container) => container.title)
    .join(' / ')
}

/// The chain from the root down to and including `id`.
export function pathTo(containers: Container[], id: string): Container[] {
  const byID = new Map(containers.map((container) => [container.id, container]))
  const chain: Container[] = []
  const seen = new Set<string>()

  let current = byID.get(id)
  while (current && !seen.has(current.id)) {
    seen.add(current.id)
    chain.unshift(current)
    current = current.parentID ? byID.get(current.parentID) : undefined
  }
  return chain
}

// MARK: - Deletion

/// Deleting a container never deletes what it holds.
///
/// A folder is a filing decision, and undoing a filing decision must not
/// destroy the things filed. So the children move up to the deleted
/// container's own parent and the reminders lose their `containerID` — the
/// work survives in the buckets, where it can be found and re-filed. The
/// alternative, a cascade, means one wrong click on a trip takes eleven
/// reminders with it, and reminders have no supersede chain to recover from.
export function planDeleteContainer(
  subject: Container,
  contents: { childContainers: Container[]; reminderIDs: string[] },
  now: Date,
): { plan: WritePlan } {
  const plan: WritePlan = []

  for (const child of contents.childContainers) {
    if (child.parentID !== subject.id) continue
    plan.push({
      op: 'update',
      collection: 'containers',
      id: child.id,
      data: { parentID: subject.parentID, updatedAt: now },
    })
  }

  for (const reminderID of contents.reminderIDs) {
    plan.push({ op: 'update', collection: 'reminders', id: reminderID, data: { containerID: null } })
  }

  plan.push({ op: 'delete', collection: 'containers', id: subject.id })
  return { plan }
}

// MARK: - Archiving

/// Archiving a container, and everything beneath it, in one plan.
///
/// The cascade is real here, unlike deletion, because archiving loses nothing:
/// it is a statement that this is finished, and it is undone by the exact
/// inverse below. A trip whose folder was archived while the trip stayed live
/// would be a trip you could not navigate to.
///
/// Reminders are **not** touched. See ``isSuppressedByArchive`` for why their
/// status must survive intact.
export function planArchiveContainer(
  containers: Container[],
  subject: Container,
  now: Date,
): { plan: WritePlan } {
  const affected = [subject.id, ...descendantIDs(containers, subject.id)]
  return {
    plan: affected.map((id) => ({
      op: 'update' as const,
      collection: 'containers' as const,
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
export function planUnarchiveContainer(
  containers: Container[],
  subject: Container,
  now: Date,
): { plan: WritePlan } {
  const affected = new Set<string>([
    subject.id,
    ...descendantIDs(containers, subject.id),
    ...pathTo(containers, subject.id).map((container) => container.id),
  ])
  return {
    plan: [...affected].map((id) => ({
      op: 'update' as const,
      collection: 'containers' as const,
      id,
      data: { archivedAt: null, updatedAt: now },
    })),
  }
}

export function isArchived(container: Container): boolean {
  return container.archivedAt !== null && container.archivedAt !== undefined
}

/// The ids of every archived container, for the one question the buckets ask.
export function archivedContainerIDs(containers: Container[]): Set<string> {
  return new Set(containers.filter(isArchived).map((container) => container.id))
}

/// Whether a reminder should be left out of the day's buckets because the thing
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
/// - **Take it out of the buckets and leave its status alone.** It stops
///   asking, it stays open, and the project page still lists it under "Left
///   open" — which is the truth, and occasionally the interesting part of a
///   finished trip.
///
/// So `bucketFor` is untouched: it is pure, correct, and about dates. This is
/// applied by the *caller* before grouping.
export function isSuppressedByArchive(
  reminder: { containerID?: string | null },
  archivedIDs: Set<string>,
): boolean {
  return reminder.containerID !== null && reminder.containerID !== undefined
    ? archivedIDs.has(reminder.containerID)
    : false
}

/// The open reminders of an archived container — the ones that never happened.
export function leftOpen<T extends { status: 'open' | 'completed' }>(reminders: T[]): T[] {
  return reminders.filter((reminder) => reminder.status === 'open')
}

// MARK: - Reading

export interface ContainerProgress {
  done: number
  total: number
}

/// Counted over reminders already filtered to this container. Reported as two
/// numbers rather than a fraction, because a project with nothing in it has no
/// fraction and `0/0` is the honest answer to "how far along".
export function progressOf(reminders: Array<{ status: 'open' | 'completed' }>): ContainerProgress {
  return {
    done: reminders.filter((reminder) => reminder.status === 'completed').length,
    total: reminders.length,
  }
}

export function progressSentence(progress: ContainerProgress): string {
  if (progress.total === 0) return 'Nothing in it yet'
  if (progress.done === progress.total) return `All ${progress.total} done`
  return `${progress.done} of ${progress.total} done`
}
