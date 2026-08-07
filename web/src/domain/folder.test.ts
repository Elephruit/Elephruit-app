import { describe, expect, it } from 'vitest'
import {
  archivedFolderIDs,
  buildTree,
  descendantIDs,
  flattenTree,
  hasDates,
  isArchived,
  isSuppressedByArchive,
  leftOpen,
  makeFolder,
  moveRefusal,
  pathLabel,
  pathTo,
  planArchiveFolder,
  planCreateFolder,
  planDeleteFolder,
  planMoveFolder,
  planReorderFolder,
  planUnarchiveFolder,
  progressOf,
  progressSentence,
  validateFolderDraft,
  type Folder,
} from './folder'

const now = new Date('2026-10-01T09:00:00Z')

function folder(overrides: Partial<Folder> & Pick<Folder, 'id' | 'title'>): Folder {
  return {
    summary: null,
    colorName: 'blue',
    parentID: null,
    startAt: null,
    dueAt: null,
    archivedAt: null,
    createdAt: now,
    updatedAt: now,
    ...overrides,
  }
}

/// Travel ▸ Chicago, the shape the whole feature exists for.
const travel = folder({ id: 'travel', title: 'Travel' })
const chicago = folder({ id: 'chicago', title: 'Chicago, October', parentID: 'travel', dueAt: now })

describe('validation', () => {
  it('wants a name', () => {
    expect(validateFolderDraft({ title: '   ' })).toBe('Give it a name.')
  })

  it('refuses to end before it starts', () => {
    const refusal = validateFolderDraft({
      title: 'Chicago',
      startAt: new Date('2026-10-10T00:00:00Z'),
      dueAt: new Date('2026-10-03T00:00:00Z'),
    })
    expect(refusal).toBe('It cannot end before it starts.')
  })

  /// Dates used to be refused on a "folder" and allowed on a "project". There
  /// is one kind now, so any folder may carry them and none has to.
  it('allows dates on any folder, and requires them on none', () => {
    expect(validateFolderDraft({ title: 'Travel' })).toBeNull()
    expect(validateFolderDraft({ title: 'Chicago', dueAt: now })).toBeNull()
  })
})

describe('creation', () => {
  it('keeps the dates it was given', () => {
    expect(makeFolder({ title: 'Chicago', dueAt: now }, now).dueAt).toEqual(now)
  })

  it('plans exactly one write', () => {
    const { plan, folder: made } = planCreateFolder({ title: 'Chicago' }, now)
    expect(plan).toEqual([{ op: 'set', collection: 'folders', id: made.id, data: made }])
  })

  it('starts unarchived, so no document is ever missing the field', () => {
    expect(makeFolder({ title: 'Travel' }, now).archivedAt).toBeNull()
  })

  it('knows whether it has dates worth showing', () => {
    expect(hasDates(travel)).toBe(false)
    expect(hasDates(chicago)).toBe(true)
  })
})

describe('the tree', () => {
  const all = [chicago, travel, folder({ id: 'recipes', title: 'Recipes' })]

  it('reads alphabetically at each level', () => {
    const flat = flattenTree(buildTree(all)).map((node) => node.folder.id)
    expect(flat).toEqual(['recipes', 'travel', 'chicago'])
  })

  it('uses saved sibling order when it exists', () => {
    const first = folder({ id: 'z', title: 'Zebra', sortOrder: 0 })
    const second = folder({ id: 'a', title: 'Apple', sortOrder: 1 })
    expect(buildTree([second, first]).map((node) => node.folder.id)).toEqual(['z', 'a'])
  })

  it('gives each node its depth', () => {
    const byID = new Map(flattenTree(buildTree(all)).map((node) => [node.folder.id, node.depth]))
    expect(byID.get('travel')).toBe(0)
    expect(byID.get('chicago')).toBe(1)
  })

  it('hoists an orphan to the root rather than losing it', () => {
    const orphan = folder({ id: 'orphan', title: 'Orphan', parentID: 'gone' })
    expect(flattenTree(buildTree([orphan])).map((n) => n.folder.id)).toEqual(['orphan'])
  })

  it('walks the path from the root down', () => {
    expect(pathTo(all, 'chicago').map((f) => f.id)).toEqual(['travel', 'chicago'])
  })

  it('spells a whole path for the places that need one', () => {
    expect(pathLabel(all, 'chicago')).toBe('Travel / Chicago, October')
    expect(pathLabel(all, 'travel')).toBe('Travel')
  })

  it('survives a parent cycle in stored data instead of hanging', () => {
    const a = folder({ id: 'a', title: 'A', parentID: 'b' })
    const b = folder({ id: 'b', title: 'B', parentID: 'a' })
    expect(pathTo([a, b], 'a').map((f) => f.id)).toEqual(['b', 'a'])
  })

  it('finds every descendant at any depth', () => {
    const deep = folder({ id: 'deep', title: 'Deep', parentID: 'travel' })
    const deeper = folder({ id: 'deeper', title: 'Deeper', parentID: 'deep' })
    expect(descendantIDs([travel, chicago, deep, deeper], 'travel')).toEqual(
      new Set(['chicago', 'deep', 'deeper']),
    )
  })
})

describe('moving', () => {
  const all = [travel, chicago]

  it('allows a folder into another folder', () => {
    expect(moveRefusal(all, chicago, 'travel')).toBeNull()
  })

  it('allows anything back to the root', () => {
    expect(moveRefusal(all, chicago, null)).toBeNull()
  })

  it('refuses a folder into itself', () => {
    expect(moveRefusal(all, travel, 'travel')).toBe('It cannot go inside itself.')
  })

  /// The one that matters: a cycle detaches the branch from the root, and
  /// because the tree is built downward from null the branch is not corrupted
  /// but invisible.
  it('refuses a folder into its own descendant', () => {
    const inner = folder({ id: 'inner', title: 'Inner', parentID: 'travel' })
    expect(moveRefusal([travel, inner], travel, 'inner')).toBe(
      'It cannot go inside something it already contains.',
    )
  })

  it('refuses a parent that no longer exists', () => {
    expect(moveRefusal(all, chicago, 'gone')).toBe('That folder no longer exists.')
  })

  it('throws rather than planning a refused move', () => {
    const inner = folder({ id: 'inner', title: 'Inner', parentID: 'travel' })
    expect(() => planMoveFolder([travel, inner], travel, 'inner', now)).toThrow('already contains')
  })

  it('plans the allowed one as a single update', () => {
    expect(planMoveFolder(all, chicago, null, now).plan).toEqual([
      { op: 'update', collection: 'folders', id: 'chicago', data: { parentID: null, updatedAt: now } },
    ])
  })

  it('reorders siblings and normalizes their saved positions', () => {
    const recipes = folder({ id: 'recipes', title: 'Recipes' })
    const work = folder({ id: 'work', title: 'Work' })
    const plan = planReorderFolder([recipes, travel, work], work, null, 'recipes', now).plan

    expect(plan).toEqual([
      { op: 'update', collection: 'folders', id: 'work', data: { sortOrder: 0, parentID: null, updatedAt: now } },
      { op: 'update', collection: 'folders', id: 'recipes', data: { sortOrder: 1, updatedAt: now } },
      { op: 'update', collection: 'folders', id: 'travel', data: { sortOrder: 2, updatedAt: now } },
    ])
  })

  it('moves into another folder and closes the gap it left', () => {
    const recipes = folder({ id: 'recipes', title: 'Recipes' })
    const plan = planReorderFolder([recipes, travel, chicago], recipes, 'travel', null, now).plan

    expect(plan).toContainEqual({
      op: 'update', collection: 'folders', id: 'travel', data: { sortOrder: 0, updatedAt: now },
    })
    expect(plan).toContainEqual({
      op: 'update',
      collection: 'folders',
      id: 'recipes',
      data: { sortOrder: 1, parentID: 'travel', updatedAt: now },
    })
  })
})

describe('deleting', () => {
  const inner = folder({ id: 'inner', title: 'Inner', parentID: 'travel' })

  it('never deletes what it holds', () => {
    const { plan } = planDeleteFolder(
      travel,
      { childFolders: [inner], reminderIDs: ['r1'], noteIDs: ['n1'] },
      now,
    )
    expect(plan.filter((write) => write.op === 'delete')).toEqual([
      { op: 'delete', collection: 'folders', id: 'travel' },
    ])
  })

  it('moves the children up to the deleted folder’s own parent', () => {
    const nested = folder({ id: 'nested', title: 'Nested', parentID: 'travel' })
    const travelInside = folder({ id: 'travel', title: 'Travel', parentID: 'root' })
    const { plan } = planDeleteFolder(
      travelInside,
      { childFolders: [nested], reminderIDs: [], noteIDs: [] },
      now,
    )
    expect(plan[0]).toEqual({
      op: 'update',
      collection: 'folders',
      id: 'nested',
      data: { parentID: 'root', updatedAt: now },
    })
  })

  it('unfiles the reminders and the notes instead of destroying them', () => {
    const { plan } = planDeleteFolder(
      travel,
      { childFolders: [], reminderIDs: ['r1'], noteIDs: ['n1'] },
      now,
    )
    expect(plan).toContainEqual({ op: 'update', collection: 'reminders', id: 'r1', data: { folderID: null } })
    expect(plan).toContainEqual({
      op: 'update',
      collection: 'notes',
      id: 'n1',
      data: { folderID: null, updatedAt: now },
    })
  })

  it('ignores folders that are not actually its children', () => {
    const elsewhere = folder({ id: 'elsewhere', title: 'Elsewhere', parentID: 'other' })
    const { plan } = planDeleteFolder(
      travel,
      { childFolders: [elsewhere], reminderIDs: [], noteIDs: [] },
      now,
    )
    expect(plan).toEqual([{ op: 'delete', collection: 'folders', id: 'travel' }])
  })
})

describe('archiving', () => {
  const deep = folder({ id: 'deep', title: 'Deep', parentID: 'travel' })
  const all = [travel, chicago, deep]

  it('takes everything beneath it in one plan', () => {
    const { plan } = planArchiveFolder(all, travel, now)
    expect(plan.map((write) => write.id).sort()).toEqual(['chicago', 'deep', 'travel'])
  })

  it('archives one folder without touching its parent', () => {
    expect(planArchiveFolder(all, chicago, now).plan.map((w) => w.id)).toEqual(['chicago'])
  })

  /// Unarchiving a child alone would leave it live inside an archived parent,
  /// reachable only from the archive — which is not what the word means.
  it('brings the ancestors back too, or the trip is unreachable', () => {
    const { plan } = planUnarchiveFolder(all, chicago, now)
    expect(plan.map((write) => write.id).sort()).toEqual(['chicago', 'travel'])
    expect(plan.every((w) => w.op === 'update' && w.data.archivedAt === null)).toBe(true)
  })

  it('is its own inverse over a whole subtree', () => {
    const archived = planArchiveFolder(all, travel, now).plan.map((w) => w.id).sort()
    const restored = planUnarchiveFolder(all, travel, now).plan.map((w) => w.id).sort()
    expect(restored).toEqual(archived)
  })

  it('names the archived ones', () => {
    const gone = folder({ id: 'gone', title: 'Gone', archivedAt: now })
    expect(archivedFolderIDs([travel, gone])).toEqual(new Set(['gone']))
    expect(isArchived(gone)).toBe(true)
    expect(isArchived(travel)).toBe(false)
  })
})

/// The rule the request turns on: an open reminder in a finished trip must stop
/// asking without being marked done, because nobody bought those tickets.
describe('what an archived folder does to what it holds', () => {
  const archivedIDs = new Set(['chicago'])

  it('takes reminders and notes out of the day’s lists', () => {
    expect(isSuppressedByArchive({ folderID: 'chicago' }, archivedIDs)).toBe(true)
  })

  it('leaves things in live folders alone', () => {
    expect(isSuppressedByArchive({ folderID: 'travel' }, archivedIDs)).toBe(false)
  })

  it('leaves unfiled things alone', () => {
    expect(isSuppressedByArchive({ folderID: null }, archivedIDs)).toBe(false)
    expect(isSuppressedByArchive({}, archivedIDs)).toBe(false)
  })

  it('never writes a status — the plan touches folders only', () => {
    const { plan } = planArchiveFolder([chicago], chicago, now)
    expect(plan.every((write) => write.collection === 'folders')).toBe(true)
  })

  it('reports what was left open rather than pretending it was done', () => {
    expect(leftOpen([{ status: 'open' as const }, { status: 'completed' as const }])).toEqual([
      { status: 'open' },
    ])
  })
})

describe('progress', () => {
  it('says nothing rather than a fraction of nothing', () => {
    expect(progressSentence(progressOf([]))).toBe('Nothing in it yet')
  })

  it('counts what is done', () => {
    const progress = progressOf([{ status: 'completed' }, { status: 'open' }, { status: 'open' }])
    expect(progress).toEqual({ done: 1, total: 3 })
    expect(progressSentence(progress)).toBe('1 of 3 done')
  })

  it('says so when everything is done', () => {
    expect(progressSentence(progressOf([{ status: 'completed' }]))).toBe('All 1 done')
  })
})
