import { describe, expect, it } from 'vitest'
import { planFromResolved, resolveProposal, type CaptureProposal } from './assist'
import { makePerson } from './capture'
import type { Person } from './person'

/// The feed-contract regression fixture (polish plan, Phase 0 → Phase 3).
///
/// Today the feed subscribes only to `interactions`. A capture that saves
/// people, facts, a relationship, and a follow-up — but whose proposed
/// interaction the user removed in review — writes real entities and yet
/// renders a feed that claims nothing was logged. This fixture reproduces the
/// exact Kelly/Harbinder state from the screenshots.
///
/// `it.fails` inverts the verdict: the test body asserts the *intended*
/// contract (every non-empty save produces at least one feed-visible record),
/// which is false today, so the suite stays green while the defect stays
/// pinned. When Phase 3 introduces `MemoryRecord` and every save writes one,
/// the body starts passing, `it.fails` starts failing, and this flips to a
/// plain `it` alongside the real memory-domain tests.

const NOW = new Date('2026-08-06T15:00:00')

function person(name: string, overrides: Partial<Person> = {}): Person {
  return { ...makePerson({ displayName: name }, NOW), id: `p-${name.toLowerCase().replace(/\s+/g, '-')}`, ...overrides }
}

const kellyHarbinderProposal: CaptureProposal = {
  interaction: {
    kind: 'other',
    summary: 'Harbinder introduced me to Kelly Tsaur',
    discussion: null,
  },
  participantNames: ['Kelly Tsaur', 'Harbinder Raina'],
  facts: [
    { personName: 'Kelly Tsaur', attribute: 'role', value: 'Head of Payer/Provider Industry Vertical', confidence: 'stated' },
    { personName: 'Kelly Tsaur', attribute: 'employer', value: 'ZS', confidence: 'stated' },
  ],
  relationships: [
    { subjectName: 'Kelly Tsaur', kind: 'introducedBy', label: null, otherName: 'Harbinder Raina', facts: [] },
  ],
  followUps: [{ title: 'Attend Monday 10am CT meeting with Kelly Tsaur', personNames: ['Kelly Tsaur'] }],
}

describe('feed contract (Kelly/Harbinder regression)', () => {
  it.fails('a save with the interaction removed still writes something the feed can render — fixed in Phase 3', () => {
    const { items } = resolveProposal(kellyHarbinderProposal, [], NOW)
    const withoutInteraction = new Set(items.filter((i) => i.type !== 'interaction').map((i) => i.id))
    const plan = planFromResolved(items, withoutInteraction, NOW)

    // The save is real: two people, two facts, a relationship pair, a follow-up.
    expect(plan.filter((w) => w.collection === 'people' && w.op === 'set').length).toBeGreaterThanOrEqual(2)
    expect(plan.filter((w) => w.collection === 'observations')).toHaveLength(2)
    expect(plan.filter((w) => w.collection === 'relationships')).toHaveLength(2)
    expect(plan.filter((w) => w.collection === 'reminders')).toHaveLength(1)

    // The intended contract: every non-empty save is feedable. Today nothing
    // in this plan is visible to the interaction-only feed subscription.
    const feedVisible = plan.filter(
      (w) => w.collection === 'interactions' || (w.collection as string) === 'memories',
    )
    expect(feedVisible.length).toBeGreaterThan(0)
  })

  it.fails('a dossier-style save (facts only, no event at all) is feedable — fixed in Phase 3', () => {
    const dave = person('Dave Okafor')
    const { items } = resolveProposal(
      {
        interaction: null,
        participantNames: [],
        facts: [{ personName: 'Dave Okafor', attribute: 'location', value: 'Chicago', confidence: 'stated' }],
        relationships: [],
        followUps: [],
      },
      [dave],
      NOW,
    )
    const plan = planFromResolved(items, new Set(items.map((i) => i.id)), NOW)

    expect(plan.length).toBeGreaterThan(0)
    const feedVisible = plan.filter(
      (w) => w.collection === 'interactions' || (w.collection as string) === 'memories',
    )
    expect(feedVisible.length).toBeGreaterThan(0)
  })
})
