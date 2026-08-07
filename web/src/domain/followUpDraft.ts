/// One follow-up draft for every surface that edits one — the standalone
/// sheet, the AI-review editor, and dossier-derived follow-ups all share this
/// model and its conversions, so there is exactly one place that knows how a
/// reminder's dates become editable fields and back.

import type { Reminder } from './reminders'
import {
  hasTemporalCue,
  resolveScheduleDraft,
  utcToZonedFields,
  validateScheduleDraft,
  type ResolvedSchedule,
  type ScheduleDraftFields,
  type TemporalContext,
} from './temporal'

export interface FollowUpDraft {
  title: string
  notes: string
  personIDs: Set<string>
  categoryTags: Set<string>
  schedule: ScheduleDraftFields
}

export function emptyFollowUpDraft(userZone: string): FollowUpDraft {
  return {
    title: '',
    notes: '',
    personIDs: new Set(),
    categoryTags: new Set(),
    schedule: { scheduleMode: 'none', localDate: '', localTime: '', timeZone: userZone },
  }
}

/// A stored reminder reopened for editing. Timed schedules read back in their
/// own zone; date-only ones in browser-local; legacy reminders (no precision)
/// read back date-only so editing them does not invent a time of day.
export function draftFromReminder(reminder: Reminder, userZone: string): FollowUpDraft {
  const schedule: ScheduleDraftFields = { scheduleMode: 'none', localDate: '', localTime: '', timeZone: userZone }

  if (reminder.isSomeday) {
    schedule.scheduleMode = 'someday'
  } else if (reminder.dueAt) {
    schedule.scheduleMode = 'deadline'
    if (reminder.duePrecision === 'dateTime') {
      const zone = reminder.scheduleTimeZone ?? userZone
      const fields = utcToZonedFields(reminder.dueAt, zone)
      schedule.localDate = fields.localDate
      schedule.localTime = fields.localTime
      schedule.timeZone = zone
    } else {
      const fields = utcToZonedFields(reminder.dueAt, userZone)
      schedule.localDate = fields.localDate
    }
  } else if (reminder.startAt) {
    schedule.scheduleMode = 'start'
    if (reminder.startPrecision === 'dateTime') {
      const zone = reminder.scheduleTimeZone ?? userZone
      const fields = utcToZonedFields(reminder.startAt, zone)
      schedule.localDate = fields.localDate
      schedule.localTime = fields.localTime
      schedule.timeZone = zone
    } else {
      const fields = utcToZonedFields(reminder.startAt, userZone)
      schedule.localDate = fields.localDate
    }
  }

  return {
    title: reminder.title,
    notes: reminder.notes ?? '',
    personIDs: new Set(reminder.personIDs),
    categoryTags: new Set(reminder.categoryTags ?? []),
    schedule,
  }
}

export function validateFollowUpDraft(draft: FollowUpDraft): string | null {
  if (!draft.title.trim()) return 'Say what you need to do.'
  return validateScheduleDraft(draft.schedule)
}

/// Whether saving needs the temporal safeguard: explicit temporal language
/// with No date selected.
export function followUpNeedsTemporalGuard(draft: FollowUpDraft): boolean {
  return draft.schedule.scheduleMode === 'none' && hasTemporalCue(`${draft.title} ${draft.notes}`)
}

export interface ReminderFields {
  title: string
  notes: string | null
  personIDs: string[]
  categoryTags: string[]
  startAt: Date | null
  dueAt: Date | null
  isSomeday: boolean
  scheduleTimeZone: string | null
  duePrecision: 'date' | 'dateTime' | null
  startPrecision: 'date' | 'dateTime' | null
}

/// Draft → the exact fields planCreateReminder/planUpdateReminder take.
export function reminderFieldsFromDraft(draft: FollowUpDraft, context: TemporalContext): ReminderFields {
  const resolved: ResolvedSchedule = resolveScheduleDraft(draft.schedule, context)
  return {
    title: draft.title.trim(),
    notes: draft.notes.trim() || null,
    personIDs: [...draft.personIDs],
    categoryTags: [...draft.categoryTags],
    startAt: resolved.startAt,
    dueAt: resolved.dueAt,
    isSomeday: resolved.isSomeday,
    scheduleTimeZone: resolved.scheduleTimeZone,
    duePrecision: resolved.duePrecision,
    startPrecision: resolved.startPrecision,
  }
}
