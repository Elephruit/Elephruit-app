/// Structured time for follow-ups. The parser proposes a schedule as local
/// wall-clock parts plus an IANA zone; these helpers turn that into real
/// Reminder dates (and back into words) without ever routing through noon.
/// Pure TypeScript — the only platform dependency is Intl, which is how the
/// zone math avoids shipping a timezone database.

import type { Reminder } from './reminders'

export type ScheduleMode = 'none' | 'deadline' | 'start' | 'someday'

/// What the parser proposes, flat for structured outputs: deadline/start carry
/// a date (and optionally time+zone); someday/none carry nulls. sourceText
/// preserves the phrase ("Monday 10am CT") for review display and the
/// safeguard; confidence marks hedged or ambiguous readings for confirmation.
export interface ProposedSchedule {
  mode: ScheduleMode
  /// YYYY-MM-DD in the schedule's own zone.
  localDate: string | null
  /// 24-hour HH:mm, or null for a date-only schedule.
  localTime: string | null
  /// IANA identifier; required whenever a time is present.
  timeZone: string | null
  sourceText: string | null
  confidence: 'stated' | 'inferred' | 'uncertain'
}

export interface TemporalContext {
  /// The user's current IANA zone — the default when a proposal has none.
  timeZone: string
}

/// The Reminder-shaped outcome of resolving a proposal or a draft.
export interface ResolvedSchedule {
  startAt: Date | null
  dueAt: Date | null
  isSomeday: boolean
  scheduleTimeZone: string | null
  duePrecision: 'date' | 'dateTime' | null
  startPrecision: 'date' | 'dateTime' | null
}

export const UNSCHEDULED: ResolvedSchedule = {
  startAt: null,
  dueAt: null,
  isSomeday: false,
  scheduleTimeZone: null,
  duePrecision: null,
  startPrecision: null,
}

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/
const TIME_RE = /^([01]\d|2[0-3]):[0-5]\d$/

export function isValidTimeZone(zone: string): boolean {
  try {
    new Intl.DateTimeFormat('en-US', { timeZone: zone })
    return true
  } catch {
    return false
  }
}

/// The zone's offset from UTC at a given instant, in milliseconds, via Intl —
/// positive east of Greenwich.
function zoneOffsetMs(timeZone: string, at: Date): number {
  const dtf = new Intl.DateTimeFormat('en-US', {
    timeZone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    hourCycle: 'h23',
  })
  const parts = dtf.formatToParts(at)
  const num = (type: string) => Number(parts.find((p) => p.type === type)?.value ?? 0)
  const asUTC = Date.UTC(num('year'), num('month') - 1, num('day'), num('hour'), num('minute'), num('second'))
  return asUTC - at.getTime()
}

/// Local wall-clock in an IANA zone → the real UTC instant. Two passes over
/// the offset handle instants near a DST transition.
export function zonedTimeToUtc(localDate: string, localTime: string, timeZone: string): Date {
  const naive = new Date(`${localDate}T${localTime}:00Z`).getTime()
  const first = zoneOffsetMs(timeZone, new Date(naive))
  const second = zoneOffsetMs(timeZone, new Date(naive - first))
  return new Date(naive - second)
}

/// A date-only schedule lives at local midnight in the *user's* zone — the
/// bucket math compares against the user's start of day, so this is the value
/// that makes "due Friday" turn overdue when Friday ends, not at noon.
export function localDateToBrowserMidnight(localDate: string): Date {
  const [year, month, day] = localDate.split('-').map(Number)
  return new Date(year, month - 1, day)
}

/// Proposal → Reminder dates. Malformed or incomplete proposals degrade to
/// unscheduled rather than guessing — the temporal safeguard catches the ones
/// whose titles still sound scheduled.
export function resolveProposedSchedule(schedule: ProposedSchedule, context: TemporalContext): ResolvedSchedule {
  if (schedule.mode === 'someday') return { ...UNSCHEDULED, isSomeday: true }
  if (schedule.mode === 'none') return { ...UNSCHEDULED }

  if (!schedule.localDate || !DATE_RE.test(schedule.localDate)) return { ...UNSCHEDULED }

  const hasTime = schedule.localTime !== null && TIME_RE.test(schedule.localTime ?? '')
  const zone = schedule.timeZone && isValidTimeZone(schedule.timeZone) ? schedule.timeZone : context.timeZone

  const instant = hasTime
    ? zonedTimeToUtc(schedule.localDate, schedule.localTime!, zone)
    : localDateToBrowserMidnight(schedule.localDate)
  const precision: 'date' | 'dateTime' = hasTime ? 'dateTime' : 'date'

  if (schedule.mode === 'deadline') {
    return {
      startAt: null,
      dueAt: instant,
      isSomeday: false,
      scheduleTimeZone: hasTime ? zone : null,
      duePrecision: precision,
      startPrecision: null,
    }
  }
  return {
    startAt: instant,
    dueAt: null,
    isSomeday: false,
    scheduleTimeZone: hasTime ? zone : null,
    duePrecision: null,
    startPrecision: precision,
  }
}

// MARK: The temporal safety net

const WEEKDAYS = 'monday|tuesday|wednesday|thursday|friday|saturday|sunday'
const MONTHS =
  'january|february|march|april|may|june|july|august|september|october|november|december'
const MONTH_ABBREVS = 'jan|feb|mar|apr|jun|jul|aug|sep|sept|oct|nov|dec'

const CUES: RegExp[] = [
  /\b(today|tomorrow|tonight)\b/i,
  new RegExp(`\\b(${WEEKDAYS})\\b`, 'i'),
  // Weekday abbreviations only when followed by a number ("Mon 10am"), so
  // ordinary words like "sat with" or "wed" cannot trip the guard.
  /\b(mon|tue|tues|wed|thu|thur|thurs|fri|sat|sun)\.?\s+\d/i,
  new RegExp(`\\b(${MONTHS})\\s+\\d{1,2}\\b`, 'i'),
  new RegExp(`\\b(${MONTH_ABBREVS})\\.?\\s+\\d{1,2}\\b`, 'i'),
  /\b\d{1,2}\/\d{1,2}(\/\d{2,4})?\b/,
  /\b\d{4}-\d{2}-\d{2}\b/,
  /\b\d{1,2}(:\d{2})?\s?(am|pm)\b/i,
  /\b\d{1,2}:\d{2}\b/,
  /\bat\s+\d{1,2}\b/i,
  /\b(noon|midnight)\b/i,
  new RegExp(`\\b(next|this)\\s+(week|weekend|month|${WEEKDAYS})\\b`, 'i'),
  new RegExp(`\\b(by|before|on|after)\\s+(${WEEKDAYS}|today|tomorrow|${MONTHS})\\b`, 'i'),
]

/// Whether text contains an explicit temporal phrase. Deterministic — this is
/// the guard that keeps "Attend Monday 10am CT meeting" from being silently
/// saved with no date when the model missed the schedule.
export function hasTemporalCue(text: string): boolean {
  return CUES.some((cue) => cue.test(text))
}

// MARK: Display

function shortZoneName(date: Date, timeZone: string, locale?: string): string {
  const parts = new Intl.DateTimeFormat(locale, { timeZone, timeZoneName: 'short' }).formatToParts(date)
  return parts.find((p) => p.type === 'timeZoneName')?.value ?? ''
}

function dayLabel(date: Date, timeZone: string | undefined, locale?: string): string {
  return date.toLocaleDateString(locale, {
    weekday: 'short',
    month: 'short',
    day: 'numeric',
    ...(timeZone ? { timeZone } : {}),
  })
}

function timeLabel(date: Date, timeZone: string | undefined, locale?: string): string {
  return date.toLocaleTimeString(locale, {
    hour: 'numeric',
    minute: '2-digit',
    ...(timeZone ? { timeZone } : {}),
  })
}

/// The structured schedule line a list row shows — never the title's embedded
/// phrase. `Mon, Aug 10 · 10:00 AM CDT`, `Due Mon, Aug 10`, `Starts …`,
/// `Someday`, or null for no date.
export function formatScheduleSummary(
  reminder: Pick<Reminder, 'startAt' | 'dueAt' | 'isSomeday' | 'scheduleTimeZone' | 'duePrecision' | 'startPrecision'>,
  locale?: string,
): string | null {
  if (reminder.isSomeday) return 'Someday'

  if (reminder.dueAt) {
    const zone = reminder.scheduleTimeZone ?? undefined
    if (reminder.duePrecision === 'dateTime') {
      const zoneName = zone ? ` ${shortZoneName(reminder.dueAt, zone, locale)}` : ''
      return `${dayLabel(reminder.dueAt, zone, locale)} · ${timeLabel(reminder.dueAt, zone, locale)}${zoneName}`
    }
    return `Due ${dayLabel(reminder.dueAt, undefined, locale)}`
  }

  if (reminder.startAt) {
    const zone = reminder.scheduleTimeZone ?? undefined
    if (reminder.startPrecision === 'dateTime') {
      const zoneName = zone ? ` ${shortZoneName(reminder.startAt, zone, locale)}` : ''
      return `Starts ${dayLabel(reminder.startAt, zone, locale)} · ${timeLabel(reminder.startAt, zone, locale)}${zoneName}`
    }
    return `Starts ${dayLabel(reminder.startAt, undefined, locale)}`
  }

  return null
}

// MARK: Draft validation

export interface ScheduleDraftFields {
  scheduleMode: ScheduleMode
  localDate: string
  localTime: string
  timeZone: string
}

export function validateScheduleDraft(draft: ScheduleDraftFields): string | null {
  if (draft.scheduleMode === 'none' || draft.scheduleMode === 'someday') return null
  if (!DATE_RE.test(draft.localDate)) return 'Choose a date.'
  if (draft.localTime && !TIME_RE.test(draft.localTime)) return 'The time must be HH:mm.'
  if (draft.localTime && !isValidTimeZone(draft.timeZone)) return 'Choose a valid time zone.'
  return null
}

/// Draft fields → Reminder dates, shared by the follow-up sheet and review
/// editors so nobody keeps a second copy of this conversion.
export function resolveScheduleDraft(draft: ScheduleDraftFields, context: TemporalContext): ResolvedSchedule {
  if (draft.scheduleMode === 'someday') return { ...UNSCHEDULED, isSomeday: true }
  if (draft.scheduleMode === 'none') return { ...UNSCHEDULED }
  return resolveProposedSchedule(
    {
      mode: draft.scheduleMode,
      localDate: draft.localDate,
      localTime: draft.localTime || null,
      timeZone: draft.timeZone || null,
      sourceText: null,
      confidence: 'stated',
    },
    context,
  )
}
