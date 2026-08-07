import { describe, expect, it } from 'vitest'
import { makeObservation, makePerson, planInteractionBundle, emptyInteractionDraft } from './capture'
import { defaultMergeTarget, planDismissComparison, planMergePeople } from './personMerge'
import type { Person } from './person'
import { relationshipPair } from './relationships'
import type { Reminder } from './reminders'

const NOW = new Date('2026-08-06T15:00:00')

function person(name: string, overrides: Partial<Person> = {}): Person {
  return { ...makePerson({ displayName: name }, NOW), id: `p-${name.toLowerCase().replace(/[^a-z0-9]+/g, '-')}`, ...overrides }
}

const dave = person('Dave Okafor')
const jack = person("Dave Okafor's son", { hasStatedName: false, isPlaceholder: true })
const namedJack = person('Jack Okafor')

function reminder(overrides: Partial<Reminder> & { id: string }): Reminder {
  return {
    title: 'Follow up',
    notes: null,
    personIDs: [],
    sourceInteractionID: null,
    startAt: null,
    dueAt: null,
    isSomeday: false,
    status: 'open',
    completedAt: null,
    createdAt: NOW,
    ...overrides,
  }
}

describe('defaultMergeTarget', () => {
  const counts = { factCount: () => 0, interactionCount: () => 0 }

  it('prefers the stated name', () => {
    expect(defaultMergeTarget(jack, namedJack, counts).id).toBe(namedJack.id)
  })

  it('prefers more attached data among equals', () => {
    const a = person('A', { hasStatedName: false })
    const b = person('B', { hasStatedName: false })
    const context = {
      factCount: (id: string) => (id === b.id ? 3 : 0),
      interactionCount: () => 0,
    }
    expect(defaultMergeTarget(a, b, context).id).toBe(b.id)
  })

  it('falls back to the older record', () => {
    const older = person('A', { hasStatedName: false, createdAt: new Date('2025-01-01T12:00:00') })
    const newer = person('B', { hasStatedName: false, createdAt: new Date('2026-01-01T12:00:00') })
    expect(defaultMergeTarget(newer, older, counts).id).toBe(older.id)
  })
})

describe('planMergePeople', () => {
  it('rewrites and dedupes interaction participants', () => {
    const { interaction } = planInteractionBundle(
      { ...emptyInteractionDraft(NOW), participantIDs: [jack.id, namedJack.id], summary: 'Regatta', occurredAt: NOW },
      [jack, namedJack],
      NOW,
    )
    const { plan, preview } = planMergePeople(
      { source: jack, target: namedJack, interactions: [interaction], observations: [], reminders: [], relationships: [] },
      NOW,
    )
    const update = plan.find((w) => w.collection === 'interactions')
    expect((update as { data: { participantIDs: string[] } }).data.participantIDs).toEqual([namedJack.id])
    expect(preview.interactionsMoved).toBe(1)
  })

  it('moves observations without deleting any', () => {
    const fact = makeObservation({ subjectID: jack.id, attribute: 'school', value: 'Riverside' }, NOW)
    const { plan } = planMergePeople(
      { source: jack, target: namedJack, interactions: [], observations: [fact], reminders: [], relationships: [] },
      NOW,
    )
    expect(plan.filter((w) => w.collection === 'observations' && w.op === 'delete')).toHaveLength(0)
    const moved = plan.find((w) => w.collection === 'observations')
    expect((moved as { data: { subjectID: string } }).data.subjectID).toBe(namedJack.id)
  })

  it('rewrites reminder person arrays with dedupe', () => {
    const rem = reminder({ id: 'rem-1', personIDs: [jack.id, namedJack.id, dave.id] })
    const { plan } = planMergePeople(
      { source: jack, target: namedJack, interactions: [], observations: [], reminders: [rem], relationships: [] },
      NOW,
    )
    const update = plan.find((w) => w.collection === 'reminders')
    expect((update as { data: { personIDs: string[] } }).data.personIDs).toEqual([namedJack.id, dave.id])
  })

  it('repoints relationship pairs, preserving reciprocal invariants', () => {
    const pair = relationshipPair({ subjectID: dave.id, otherID: jack.id, kind: 'child', customLabel: 'son', now: NOW })
    const { plan, preview } = planMergePeople(
      { source: jack, target: namedJack, interactions: [], observations: [], reminders: [], relationships: [...pair] },
      NOW,
    )
    const updates = plan.filter((w) => w.collection === 'relationships' && w.op === 'update')
    expect(updates).toHaveLength(2)
    const forward = updates.find((w) => w.id === pair[0].id)
    const backward = updates.find((w) => w.id === pair[1].id)
    expect((forward as { data: { subjectID: string; otherID: string } }).data).toEqual({
      subjectID: dave.id,
      otherID: namedJack.id,
    })
    expect((backward as { data: { subjectID: string; otherID: string } }).data).toEqual({
      subjectID: namedJack.id,
      otherID: dave.id,
    })
    expect(preview.relationshipsRepointed).toBe(1)
  })

  it('removes a self-relationship the merge would create', () => {
    const pair = relationshipPair({ subjectID: jack.id, otherID: namedJack.id, kind: 'sibling', now: NOW })
    const { plan, preview } = planMergePeople(
      { source: jack, target: namedJack, interactions: [], observations: [], reminders: [], relationships: [...pair] },
      NOW,
    )
    const deletes = plan.filter((w) => w.collection === 'relationships' && w.op === 'delete').map((w) => w.id)
    expect(deletes.sort()).toEqual([pair[0].id, pair[1].id].sort())
    expect(preview.pairsRemoved).toBe(1)
  })

  it('collapses a duplicate even when the target pair is canonical in the reverse direction', () => {
    // Hand-built rows with forced ids: the target pair's smaller id is its
    // BACKWARD row (child→parent seen from Jack), so a naive directional key
    // would never collide with the repointed source pair. The invariant key
    // must still collapse it.
    const targetForward = {
      id: 'zz-forward',
      subjectID: dave.id,
      otherID: namedJack.id,
      kind: 'child' as const,
      customLabel: null,
      reciprocalID: 'aa-backward',
      createdAt: NOW,
    }
    const targetBackward = {
      id: 'aa-backward',
      subjectID: namedJack.id,
      otherID: dave.id,
      kind: 'parent' as const,
      customLabel: null,
      reciprocalID: 'zz-forward',
      createdAt: NOW,
    }
    const sourceForward = {
      id: 'mm-forward',
      subjectID: dave.id,
      otherID: jack.id,
      kind: 'child' as const,
      customLabel: 'son',
      reciprocalID: 'nn-backward',
      createdAt: NOW,
    }
    const sourceBackward = {
      id: 'nn-backward',
      subjectID: jack.id,
      otherID: dave.id,
      kind: 'parent' as const,
      customLabel: null,
      reciprocalID: 'mm-forward',
      createdAt: NOW,
    }
    const { plan, preview } = planMergePeople(
      {
        source: jack,
        target: namedJack,
        interactions: [],
        observations: [],
        reminders: [],
        relationships: [sourceForward, sourceBackward, targetForward, targetBackward],
      },
      NOW,
    )
    const deletes = plan.filter((w) => w.collection === 'relationships' && w.op === 'delete').map((w) => w.id)
    expect(deletes.sort()).toEqual(['mm-forward', 'nn-backward'])
    expect(plan.some((w) => w.collection === 'relationships' && (w.id === 'zz-forward' || w.id === 'aa-backward'))).toBe(false)
    expect(preview.pairsRemoved).toBe(1)
  })

  it('collapses a duplicate pair in favor of the target-side original', () => {
    const sourcePair = relationshipPair({ subjectID: dave.id, otherID: jack.id, kind: 'child', now: NOW })
    const targetPair = relationshipPair({ subjectID: dave.id, otherID: namedJack.id, kind: 'child', now: NOW })
    const { plan, preview } = planMergePeople(
      {
        source: jack,
        target: namedJack,
        interactions: [],
        observations: [],
        reminders: [],
        relationships: [...sourcePair, ...targetPair],
      },
      NOW,
    )
    const deletes = plan.filter((w) => w.collection === 'relationships' && w.op === 'delete').map((w) => w.id)
    expect(deletes.sort()).toEqual([sourcePair[0].id, sourcePair[1].id].sort())
    // The target's pair is untouched.
    expect(plan.some((w) => w.collection === 'relationships' && w.id === targetPair[0].id)).toBe(false)
    expect(preview.pairsRemoved).toBe(1)
  })

  it('deletes the source only within the same plan, and never the target', () => {
    const { plan } = planMergePeople(
      { source: jack, target: namedJack, interactions: [], observations: [], reminders: [], relationships: [] },
      NOW,
    )
    const personDeletes = plan.filter((w) => w.collection === 'people' && w.op === 'delete')
    expect(personDeletes).toHaveLength(1)
    expect(personDeletes[0].id).toBe(jack.id)
    expect(plan[plan.length - 1]).toEqual({ op: 'delete', collection: 'people', id: jack.id })
  })

  it('refuses to merge a person into themselves', () => {
    expect(() =>
      planMergePeople(
        { source: jack, target: jack, interactions: [], observations: [], reminders: [], relationships: [] },
        NOW,
      ),
    ).toThrow()
  })
})

describe('planDismissComparison', () => {
  it('appends the key without duplicates', () => {
    const withKeys = { ...dave, dismissedComparisonKeys: ['a~b'] }
    const plan = planDismissComparison(withKeys, 'a~b')
    expect((plan[0] as { data: { dismissedComparisonKeys: string[] } }).data.dismissedComparisonKeys).toEqual(['a~b'])
    const plan2 = planDismissComparison(withKeys, 'c~d')
    expect((plan2[0] as { data: { dismissedComparisonKeys: string[] } }).data.dismissedComparisonKeys).toEqual(['a~b', 'c~d'])
  })
})
