/// Follow-up scheduling, ported from the Mac app's ReminderStore.
///
/// The load-bearing distinction: a start date brings something into view without
/// ever turning red; only a deadline can make something late. A past start date
/// with no deadline means *available* — which is what Anytime means — not overdue.

import { isSameDay, startOfDay } from './dates'

export type ReminderStatus = 'open' | 'completed'

export interface Reminder {
  id: string
  title: string
  notes: string | null
  /// The people this is owed to or about.
  personIDs: string[]
  /// Who is expected to act. Missing on older records means the user.
  responsibility?: 'mine' | 'theirs'
  /// The interaction it fell out of, when it fell out of one.
  sourceInteractionID: string | null
  /// The imported document it fell out of, for dossier-derived follow-ups.
  sourceDocumentID?: string | null
  /// When it becomes available. Cannot make it late.
  startAt: Date | null
  /// The only date that can make something overdue.
  dueAt: Date | null
  isSomeday: boolean
  status: ReminderStatus
  completedAt: Date | null
  createdAt: Date
  /// The IANA zone a timed schedule was expressed in — "Monday 10am CT" stays
  /// Central for display and editing wherever the user happens to be. Absent
  /// on reminders from before structured schedules; null for date-only ones.
  scheduleTimeZone?: string | null
  /// Whether dueAt means a calendar day or an instant. A date-only deadline
  /// turns overdue when its local day ends; a date-time one at that moment.
  /// Absent means the pre-precision behavior (day granularity).
  duePrecision?: 'date' | 'dateTime' | null
  startPrecision?: 'date' | 'dateTime' | null
}

/// The five buckets, in reading order: a deadline that has passed, work that
/// belongs to today, work with a future date, work with no date, and work
/// deliberately parked.
export const BUCKETS = ['overdue', 'today', 'upcoming', 'anytime', 'someday'] as const
export type Bucket = (typeof BUCKETS)[number]

export const BUCKET_TITLES: Record<Bucket, string> = {
  overdue: 'Overdue',
  today: 'Today',
  upcoming: 'Upcoming',
  anytime: 'Anytime',
  someday: 'Someday',
}

/// Which bucket one reminder belongs to. A deadline decides ahead of a start
/// date, because only a deadline can make anything late.
export function bucketFor(reminder: Reminder, now: Date): Bucket {
  if (reminder.isSomeday) return 'someday'

  const today = startOfDay(now)

  if (reminder.dueAt) {
    // A timed deadline is late the moment it passes; a date-only one when its
    // day ends. Reminders predating precision keep the day-granular rule.
    if (reminder.duePrecision === 'dateTime' && reminder.dueAt.getTime() < now.getTime()) return 'overdue'
    if (reminder.dueAt.getTime() < today.getTime()) return 'overdue'
    if (isSameDay(reminder.dueAt, today)) return 'today'
    return 'upcoming'
  }

  if (reminder.startAt) {
    if (reminder.startAt.getTime() <= today.getTime() || isSameDay(reminder.startAt, today)) {
      return isSameDay(reminder.startAt, today) ? 'today' : 'anytime'
    }
    return 'upcoming'
  }

  return 'anytime'
}

export interface BucketGroup {
  bucket: Bucket
  reminders: Reminder[]
}

const DISTANT_FUTURE = 8.64e15

function relevantDate(reminder: Reminder): number {
  return reminder.dueAt?.getTime() ?? reminder.startAt?.getTime() ?? DISTANT_FUTURE
}

/// The open reminders, bucketed and ordered. Absent buckets are absent, not empty.
/// Per-bucket order: overdue oldest first (the thing most needing an answer is the
/// one avoided longest), today/upcoming by their relevant date, anytime/someday
/// newest created first.
export function sections(reminders: Reminder[], now: Date): BucketGroup[] {
  const open = reminders.filter((r) => r.status === 'open')

  const byBucket = new Map<Bucket, Reminder[]>()
  for (const reminder of open) {
    const bucket = bucketFor(reminder, now)
    const list = byBucket.get(bucket) ?? []
    list.push(reminder)
    byBucket.set(bucket, list)
  }

  const groups: BucketGroup[] = []
  for (const bucket of BUCKETS) {
    const list = byBucket.get(bucket)
    if (!list || list.length === 0) continue
    switch (bucket) {
      case 'overdue':
        list.sort((a, b) => (a.dueAt?.getTime() ?? 0) - (b.dueAt?.getTime() ?? 0))
        break
      case 'today':
      case 'upcoming':
        list.sort((a, b) => relevantDate(a) - relevantDate(b))
        break
      case 'anytime':
      case 'someday':
        list.sort((a, b) => b.createdAt.getTime() - a.createdAt.getTime())
        break
    }
    groups.push({ bucket, reminders: list })
  }
  return groups
}

/// The next open reminder per person — the soonest deadline-or-start; undated
/// reminders only win when a person has nothing dated at all.
export function nextOpenReminderByPerson(reminders: Reminder[]): Map<string, Reminder> {
  const best = new Map<string, Reminder>()
  for (const reminder of reminders) {
    if (reminder.status !== 'open') continue
    for (const personID of reminder.personIDs) {
      const current = best.get(personID)
      if (!current || relevantDate(reminder) < relevantDate(current)) {
        best.set(personID, reminder)
      }
    }
  }
  return best
}

/// Completed reminders, newest completion first — behind a toggle, never mixed in.
export function completedList(reminders: Reminder[]): Reminder[] {
  return reminders
    .filter((r) => r.status === 'completed')
    .sort((a, b) => (b.completedAt?.getTime() ?? 0) - (a.completedAt?.getTime() ?? 0))
}
