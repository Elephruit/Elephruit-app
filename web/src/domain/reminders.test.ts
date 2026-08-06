import { describe, expect, it } from 'vitest'
import { bucketFor, completedList, sections, type Reminder } from './reminders'

const NOW = new Date('2026-08-06T15:00:00')

let counter = 0
function reminder(overrides: Partial<Reminder>): Reminder {
  counter += 1
  return {
    id: `rem-${counter}`,
    title: `Reminder ${counter}`,
    notes: null,
    personIDs: [],
    sourceInteractionID: null,
    startAt: null,
    dueAt: null,
    isSomeday: false,
    status: 'open',
    completedAt: null,
    createdAt: new Date('2026-08-01T09:00:00'),
    ...overrides,
  }
}

describe('bucketFor', () => {
  it('follows the decision table: someday wins, deadline decides, past start means available', () => {
    expect(bucketFor(reminder({ isSomeday: true, dueAt: new Date('2020-01-01T12:00:00') }), NOW)).toBe('someday')
    expect(bucketFor(reminder({ dueAt: new Date('2026-08-05T23:00:00') }), NOW)).toBe('overdue')
    expect(bucketFor(reminder({ dueAt: new Date('2026-08-06T22:00:00') }), NOW)).toBe('today')
    expect(bucketFor(reminder({ dueAt: new Date('2026-08-09T12:00:00') }), NOW)).toBe('upcoming')
    expect(bucketFor(reminder({ startAt: new Date('2026-08-06T08:00:00') }), NOW)).toBe('today')
    expect(bucketFor(reminder({ startAt: new Date('2026-07-20T12:00:00') }), NOW)).toBe('anytime')
    expect(bucketFor(reminder({ startAt: new Date('2026-08-10T12:00:00') }), NOW)).toBe('upcoming')
    expect(bucketFor(reminder({}), NOW)).toBe('anytime')
  })

  it('lets a deadline decide ahead of a start date', () => {
    const both = reminder({ startAt: new Date('2026-07-01T12:00:00'), dueAt: new Date('2026-09-01T12:00:00') })
    expect(bucketFor(both, NOW)).toBe('upcoming')
    const late = reminder({ startAt: new Date('2026-08-10T12:00:00'), dueAt: new Date('2026-08-01T12:00:00') })
    expect(bucketFor(late, NOW)).toBe('overdue')
  })
})

describe('sections', () => {
  it('omits empty buckets instead of rendering them, and never shows completed work', () => {
    const done = reminder({ status: 'completed', completedAt: new Date('2026-08-02T12:00:00') })
    const open = reminder({})
    const groups = sections([done, open], NOW)
    expect(groups.map((g) => g.bucket)).toEqual(['anytime'])
    expect(groups[0].reminders.map((r) => r.id)).toEqual([open.id])
  })

  it('orders overdue oldest-first and today/upcoming by their relevant date', () => {
    const oldOverdue = reminder({ dueAt: new Date('2026-07-01T12:00:00') })
    const newOverdue = reminder({ dueAt: new Date('2026-08-04T12:00:00') })
    const laterToday = reminder({ dueAt: new Date('2026-08-06T18:00:00') })
    const earlierToday = reminder({ startAt: new Date('2026-08-06T09:00:00') })
    const nextWeek = reminder({ dueAt: new Date('2026-08-12T12:00:00') })
    const tomorrow = reminder({ startAt: new Date('2026-08-07T12:00:00') })

    const groups = sections([newOverdue, laterToday, nextWeek, oldOverdue, earlierToday, tomorrow], NOW)
    expect(groups.map((g) => g.bucket)).toEqual(['overdue', 'today', 'upcoming'])
    expect(groups[0].reminders.map((r) => r.id)).toEqual([oldOverdue.id, newOverdue.id])
    expect(groups[1].reminders.map((r) => r.id)).toEqual([earlierToday.id, laterToday.id])
    expect(groups[2].reminders.map((r) => r.id)).toEqual([tomorrow.id, nextWeek.id])
  })

  it('orders the undated buckets newest-created-first', () => {
    const older = reminder({ createdAt: new Date('2026-08-01T12:00:00') })
    const newer = reminder({ createdAt: new Date('2026-08-05T12:00:00') })
    const groups = sections([older, newer], NOW)
    expect(groups[0].reminders.map((r) => r.id)).toEqual([newer.id, older.id])
  })

  it('lists completed reminders newest completion first', () => {
    const first = reminder({ status: 'completed', completedAt: new Date('2026-08-01T12:00:00') })
    const second = reminder({ status: 'completed', completedAt: new Date('2026-08-05T12:00:00') })
    expect(completedList([first, second]).map((r) => r.id)).toEqual([second.id, first.id])
  })
})
