/// The feed's daily summary, derived from rules that already exist elsewhere:
/// the reminder buckets decide what is owed, and the suggestion engine decides
/// who has gone quiet. This file only counts; it never writes and it invents no
/// new thresholds.

import { followUpSuggestions, type FollowUpSuggestion } from './contact'
import { startOfDay, wholeDaysBetween } from './dates'
import type { Person } from './person'
import { bucketFor, type Reminder } from './reminders'

export interface FeedOverview {
  overdue: number
  /// How long the most-neglected overdue item has been late, in whole days.
  oldestOverdueDays: number | null
  /// The today bucket — due today, or becoming available today.
  today: number
  firstTodayTitle: string | null
  /// Most quiet first, placeholders excluded; empty when nobody qualifies.
  quiet: FollowUpSuggestion[]
}

export function feedOverview(reminders: Reminder[], people: Person[], now: Date): FeedOverview {
  const open = reminders.filter((reminder) => reminder.status === 'open')
  const overdue = open.filter((reminder) => bucketFor(reminder, now) === 'overdue')
  const today = open.filter((reminder) => bucketFor(reminder, now) === 'today')

  let oldestOverdueDays: number | null = null
  for (const reminder of overdue) {
    if (!reminder.dueAt) continue
    const days = wholeDaysBetween(startOfDay(reminder.dueAt), startOfDay(now))
    if (oldestOverdueDays === null || days > oldestOverdueDays) oldestOverdueDays = days
  }

  const quiet = followUpSuggestions(
    people
      .filter((person) => !person.isPlaceholder)
      .map((person) => ({
        personID: person.id,
        displayName: person.displayName,
        lastContactAt: person.lastContactAt,
      })),
    now,
  )

  return {
    overdue: overdue.length,
    oldestOverdueDays,
    today: today.length,
    firstTodayTitle: today[0]?.title ?? null,
    quiet,
  }
}
