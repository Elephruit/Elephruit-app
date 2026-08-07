import { describe, expect, it } from 'vitest'
import { makePerson } from './capture'
import { feedOverview } from './overview'
import type { Reminder } from './reminders'

const NOW = new Date('2026-08-06T10:00:00')

function reminder(overrides: Partial<Reminder>): Reminder {
  return {
    id: Math.random().toString(36).slice(2),
    title: 'Something owed',
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

function person(name: string, lastContactDaysAgo: number | null, isPlaceholder = false) {
  const made = makePerson({ displayName: name, isPlaceholder, hasStatedName: !isPlaceholder }, NOW)
  made.lastContactAt =
    lastContactDaysAgo === null ? null : new Date(NOW.getTime() - lastContactDaysAgo * 86_400_000)
  return made
}

describe('feedOverview', () => {
  it('counts the overdue and today buckets and surfaces the oldest debt', () => {
    const overview = feedOverview(
      [
        reminder({ title: 'Oldest', dueAt: new Date('2026-07-31T17:00:00') }),
        reminder({ title: 'Newer', dueAt: new Date('2026-08-04T17:00:00') }),
        reminder({ title: 'Flights', dueAt: new Date('2026-08-06T21:00:00') }),
        reminder({ title: 'Later', dueAt: new Date('2026-08-20T12:00:00') }),
      ],
      [],
      NOW,
    )
    expect(overview.overdue).toBe(2)
    expect(overview.oldestOverdueDays).toBe(6)
    expect(overview.today).toBe(1)
    expect(overview.firstTodayTitle).toBe('Flights')
  })

  it('ignores completed reminders entirely', () => {
    const overview = feedOverview(
      [reminder({ dueAt: new Date('2026-07-30T12:00:00'), status: 'completed', completedAt: NOW })],
      [],
      NOW,
    )
    expect(overview.overdue).toBe(0)
    expect(overview.oldestOverdueDays).toBeNull()
  })

  it('counts a start date arriving today as today, because the bucket does', () => {
    const overview = feedOverview([reminder({ startAt: new Date('2026-08-06T09:00:00') })], [], NOW)
    expect(overview.today).toBe(1)
  })

  it('lists the quiet, most neglected first, and never placeholders or the never-contacted', () => {
    const overview = feedOverview(
      [],
      [
        person('Recent', 3),
        person('Quiet', 50),
        person('Quieter', 70),
        person('Never', null),
        person("Dave's son", 90, true),
      ],
      NOW,
    )
    expect(overview.quiet.map((s) => s.displayName)).toEqual(['Quieter', 'Quiet'])
  })
})
