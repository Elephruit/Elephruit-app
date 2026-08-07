import { describe, expect, it } from 'vitest'
import {
  archivedContainerIDs,
  buildTree,
  canContain,
  descendantIDs,
  flattenTree,
  isArchived,
  isSuppressedByArchive,
  leftOpen,
  makeContainer,
  moveRefusal,
  pathLabel,
  pathTo,
  planArchiveContainer,
  planCreateContainer,
  planDeleteContainer,
  planMoveContainer,
  planUnarchiveContainer,
  progressOf,
  progressSentence,
  validateContainerDraft,
  type Container,
} from './container'

const now = new Date('2026-10-01T09:00:00Z')

function container(overrides: Partial<Container> & Pick<Container, 'id' | 'kind' | 'title'>): Container {
  return {
    summary: null,
    colorName: 'blue',
    parentID: null,
    startAt: null,
    dueAt: null,
    status: 'active',
    archivedAt: null,
    createdAt: now,
    updatedAt: now,
    ...overrides,
  }
}

/// Travel ▸ Chicago, the shape the whole feature exists for.
const travel = container({ id: 'travel', kind: 'folder', title: 'Travel' })
const chicago = container({ id: 'chicago', kind: 'project', title: 'Chicago, October', parentID: 'travel' })

describe('what may hold what', () => {
  it('lets a folder hold folders and projects', () => {
    expect(canContain('folder', 'folder')).toBe(true)
    expect(canContain('folder', 'project')).toBe(true)
  })

  it('refuses to put anything inside a project', () => {
    expect(canContain('project', 'project')).toBe(false)
    expect(canContain('project', 'folder')).toBe(false)
  })
})

describe('validation', () => {
  it('wants a name', () => {
    expect(validateContainerDraft({ kind: 'folder', title: '   ' })).toBe('Give it a name.')
  })

  it('refuses dates on a folder, and says what to do instead', () => {
    const refusal = validateContainerDraft({ kind: 'folder', title: 'Travel', dueAt: now })
    expect(refusal).toBe('A folder has no dates. Make it a project if it ends.')
  })

  it('refuses to end before it starts', () => {
    const refusal = validateContainerDraft({
      kind: 'project',
      title: 'Chicago',
      startAt: new Date('2026-10-10T00:00:00Z'),
      dueAt: new Date('2026-10-03T00:00:00Z'),
    })
    expect(refusal).toBe('It cannot end before it starts.')
  })
})

describe('creation', () => {
  it('drops project-only fields when the kind is a folder', () => {
    const made = makeContainer(
      { kind: 'folder', title: 'Travel', startAt: now, dueAt: now },
      now,
    )
    expect(made.startAt).toBeNull()
    expect(made.dueAt).toBeNull()
  })

  it('keeps them on a project', () => {
    const made = makeContainer({ kind: 'project', title: 'Chicago', dueAt: now }, now)
    expect(made.dueAt).toEqual(now)
  })

  it('plans exactly one write', () => {
    const { plan, container: made } = planCreateContainer({ kind: 'project', title: 'Chicago' }, now)
    expect(plan).toEqual([{ op: 'set', collection: 'containers', id: made.id, data: made }])
  })

  it('starts unarchived, so no document is ever missing the field', () => {
    expect(makeContainer({ kind: 'folder', title: 'Travel' }, now).archivedAt).toBeNull()
  })
})

describe('the tree', () => {
  const all = [chicago, travel, container({ id: 'recipes', kind: 'folder', title: 'Recipes' })]

  it('reads folders before projects, alphabetically within each', () => {
    const flat = flattenTree(buildTree(all)).map((node) => node.container.id)
    expect(flat).toEqual(['recipes', 'travel', 'chicago'])
  })

  it('gives each node its depth', () => {
    const byID = new Map(flattenTree(buildTree(all)).map((node) => [node.container.id, node.depth]))
    expect(byID.get('travel')).toBe(0)
    expect(byID.get('chicago')).toBe(1)
  })

  it('hoists an orphan to the root rather than losing it', () => {
    const orphan = container({ id: 'orphan', kind: 'project', title: 'Orphan', parentID: 'gone' })
    const flat = flattenTree(buildTree([orphan])).map((node) => node.container.id)
    expect(flat).toEqual(['orphan'])
  })

  it('walks the path from the root down', () => {
    expect(pathTo(all, 'chicago').map((c) => c.id)).toEqual(['travel', 'chicago'])
  })

  /// A `<select>` keeps the chosen option's indent when it is closed, so a
  /// leading dash reads as a stray mark and says nothing about which folder.
  it('labels a picker option with its whole path', () => {
    expect(pathLabel(all, 'chicago')).toBe('Travel / Chicago, October')
    expect(pathLabel(all, 'travel')).toBe('Travel')
  })

  it('survives a parent cycle in stored data instead of hanging', () => {
    const a = container({ id: 'a', kind: 'folder', title: 'A', parentID: 'b' })
    const b = container({ id: 'b', kind: 'folder', title: 'B', parentID: 'a' })
    expect(pathTo([a, b], 'a').map((c) => c.id)).toEqual(['b', 'a'])
  })

  it('finds every descendant at any depth', () => {
    const deep = container({ id: 'deep', kind: 'folder', title: 'Deep', parentID: 'travel' })
    const deeper = container({ id: 'deeper', kind: 'project', title: 'Deeper', parentID: 'deep' })
    expect(descendantIDs([travel, chicago, deep, deeper], 'travel')).toEqual(
      new Set(['chicago', 'deep', 'deeper']),
    )
  })
})

describe('moving', () => {
  const all = [travel, chicago]

  it('allows a project into a folder', () => {
    expect(moveRefusal(all, chicago, 'travel')).toBeNull()
  })

  it('allows anything back to the root', () => {
    expect(moveRefusal(all, chicago, null)).toBeNull()
  })

  it('refuses a folder into a project, and says why', () => {
    const refusal = moveRefusal(all, travel, 'chicago')
    expect(refusal).toBe('A project holds work, not folders.')
  })

  it('refuses a container into itself', () => {
    expect(moveRefusal(all, travel, 'travel')).toBe('It cannot go inside itself.')
  })

  /// The one that matters: a cycle detaches the branch from the root, and
  /// because the tree is built downward from null the branch is not corrupted
  /// but invisible.
  it('refuses a folder into its own descendant', () => {
    const inner = container({ id: 'inner', kind: 'folder', title: 'Inner', parentID: 'travel' })
    const refusal = moveRefusal([travel, inner], travel, 'inner')
    expect(refusal).toBe('It cannot go inside something it already contains.')
  })

  it('refuses a parent that no longer exists', () => {
    expect(moveRefusal(all, chicago, 'gone')).toBe('That folder no longer exists.')
  })

  it('throws rather than planning a refused move', () => {
    expect(() => planMoveContainer(all, travel, 'chicago', now)).toThrow('A project holds work, not folders.')
  })

  it('plans the allowed one as a single update', () => {
    const { plan } = planMoveContainer(all, chicago, null, now)
    expect(plan).toEqual([
      { op: 'update', collection: 'containers', id: 'chicago', data: { parentID: null, updatedAt: now } },
    ])
  })
})

describe('deleting', () => {
  const inner = container({ id: 'inner', kind: 'project', title: 'Inner', parentID: 'travel' })

  it('never deletes what it holds', () => {
    const { plan } = planDeleteContainer(
      travel,
      { childContainers: [inner], reminderIDs: ['r1', 'r2'] },
      now,
    )
    const deletes = plan.filter((write) => write.op === 'delete')
    expect(deletes).toEqual([{ op: 'delete', collection: 'containers', id: 'travel' }])
  })

  it('moves the children up to the deleted container’s own parent', () => {
    const nested = container({ id: 'nested', kind: 'folder', title: 'Nested', parentID: 'travel' })
    const travelInside = container({ id: 'travel', kind: 'folder', title: 'Travel', parentID: 'root' })
    const { plan } = planDeleteContainer(
      travelInside,
      { childContainers: [nested], reminderIDs: [] },
      now,
    )
    expect(plan[0]).toEqual({
      op: 'update',
      collection: 'containers',
      id: 'nested',
      data: { parentID: 'root', updatedAt: now },
    })
  })

  it('unfiles the reminders instead of destroying them', () => {
    const { plan } = planDeleteContainer(travel, { childContainers: [], reminderIDs: ['r1'] }, now)
    expect(plan).toContainEqual({
      op: 'update',
      collection: 'reminders',
      id: 'r1',
      data: { containerID: null },
    })
  })

  it('ignores containers that are not actually its children', () => {
    const elsewhere = container({ id: 'elsewhere', kind: 'project', title: 'Elsewhere', parentID: 'other' })
    const { plan } = planDeleteContainer(
      travel,
      { childContainers: [elsewhere], reminderIDs: [] },
      now,
    )
    expect(plan).toEqual([{ op: 'delete', collection: 'containers', id: 'travel' }])
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

describe('archiving', () => {
  const deep = container({ id: 'deep', kind: 'project', title: 'Deep', parentID: 'travel' })
  const all = [travel, chicago, deep]

  it('takes everything beneath it in one plan', () => {
    const { plan } = planArchiveContainer(all, travel, now)
    expect(plan.map((write) => write.id).sort()).toEqual(['chicago', 'deep', 'travel'])
    expect(plan.every((write) => write.op === 'update')).toBe(true)
  })

  it('archives a single project without touching its folder', () => {
    const { plan } = planArchiveContainer(all, chicago, now)
    expect(plan.map((write) => write.id)).toEqual(['chicago'])
  })

  /// Unarchiving a child alone would leave it live inside an archived parent,
  /// reachable only from the archive — which is not what the word means.
  it('brings the ancestors back too, or the trip is unreachable', () => {
    const { plan } = planUnarchiveContainer(all, chicago, now)
    expect(plan.map((write) => write.id).sort()).toEqual(['chicago', 'travel'])
    expect(plan.every((write) => write.op === 'update' && write.data.archivedAt === null)).toBe(true)
  })

  it('is its own inverse over a whole subtree', () => {
    const archived = planArchiveContainer(all, travel, now).plan.map((write) => write.id).sort()
    const restored = planUnarchiveContainer(all, travel, now).plan.map((write) => write.id).sort()
    expect(restored).toEqual(archived)
  })

  it('names the archived ones', () => {
    const gone = container({ id: 'gone', kind: 'project', title: 'Gone', archivedAt: now })
    expect(archivedContainerIDs([travel, gone])).toEqual(new Set(['gone']))
    expect(isArchived(gone)).toBe(true)
    expect(isArchived(travel)).toBe(false)
  })
})

/// The rule the request turns on: an open reminder in a finished trip must stop
/// asking without being marked done, because nobody bought those tickets.
describe('what an archived container does to its reminders', () => {
  const archivedIDs = new Set(['chicago'])

  it('takes them out of the day’s buckets', () => {
    expect(isSuppressedByArchive({ containerID: 'chicago' }, archivedIDs)).toBe(true)
  })

  it('leaves reminders in live containers alone', () => {
    expect(isSuppressedByArchive({ containerID: 'travel' }, archivedIDs)).toBe(false)
  })

  it('leaves unfiled reminders alone', () => {
    expect(isSuppressedByArchive({ containerID: null }, archivedIDs)).toBe(false)
    expect(isSuppressedByArchive({}, archivedIDs)).toBe(false)
  })

  it('never writes a status — the plan touches containers only', () => {
    const { plan } = planArchiveContainer([chicago], chicago, now)
    expect(plan.every((write) => write.collection === 'containers')).toBe(true)
  })

  it('reports what was left open rather than pretending it was done', () => {
    const reminders = [{ status: 'open' as const }, { status: 'completed' as const }]
    expect(leftOpen(reminders)).toEqual([{ status: 'open' }])
  })
})
