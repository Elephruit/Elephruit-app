import { describe, expect, it } from 'vitest'
import {
  draftFromReminder,
  emptyFollowUpDraft,
  followUpNeedsTemporalGuard,
  reminderFieldsFromDraft,
  validateFollowUpDraft,
} from './followUpDraft'
import type { Reminder } from './reminders'
import { detectDeadlineFromText } from './temporal'

const USER_ZONE = 'America/Chicago'

function reminder(overrides: Partial<Reminder>): Reminder {
  return {
    id: 'rem-1',
    title: 'Follow up',
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

describe('draftFromReminder', () => {
  it('reads a timed deadline back in its own zone', () => {
    const draft = draftFromReminder(
      reminder({
        title: 'Attend Monday 10am CT meeting with Kelly Tsaur',
        dueAt: new Date('2026-08-10T15:00:00.000Z'),
        duePrecision: 'dateTime',
        scheduleTimeZone: 'America/Chicago',
      }),
      USER_ZONE,
    )
    expect(draft.schedule).toEqual({
      scheduleMode: 'deadline',
      localDate: '2026-08-10',
      localTime: '10:00',
      timeZone: 'America/Chicago',
    })
  })

  it('reads a date-only deadline back without inventing a time', () => {
    const draft = draftFromReminder(
      reminder({ dueAt: new Date(2026, 7, 14), duePrecision: 'date' }),
      Intl.DateTimeFormat().resolvedOptions().timeZone,
    )
    expect(draft.schedule.scheduleMode).toBe('deadline')
    expect(draft.schedule.localDate).toBe('2026-08-14')
    expect(draft.schedule.localTime).toBe('')
  })

  it('maps someday and start reminders onto their modes', () => {
    expect(draftFromReminder(reminder({ isSomeday: true }), USER_ZONE).schedule.scheduleMode).toBe('someday')
    const start = draftFromReminder(
      reminder({ startAt: new Date(2026, 7, 16), startPrecision: 'date' }),
      Intl.DateTimeFormat().resolvedOptions().timeZone,
    )
    expect(start.schedule.scheduleMode).toBe('start')
  })

  it('round-trips: edit, save, reopen keeps date, time, and zone', () => {
    const original = reminder({
      dueAt: new Date('2026-08-10T15:00:00.000Z'),
      duePrecision: 'dateTime',
      scheduleTimeZone: 'America/Chicago',
    })
    const draft = draftFromReminder(original, 'Europe/Berlin')
    const fields = reminderFieldsFromDraft(draft, { timeZone: 'Europe/Berlin' })
    expect(fields.dueAt?.toISOString()).toBe('2026-08-10T15:00:00.000Z')
    expect(fields.scheduleTimeZone).toBe('America/Chicago')
    expect(fields.duePrecision).toBe('dateTime')
  })

  it('round-trips category tags and treats legacy reminders as untagged', () => {
    expect(draftFromReminder(reminder({}), USER_ZONE).categoryTags).toEqual(new Set())

    const draft = draftFromReminder(reminder({ categoryTags: ['work', 'waiting'] }), USER_ZONE)
    expect(draft.categoryTags).toEqual(new Set(['work', 'waiting']))
    expect(reminderFieldsFromDraft(draft, { timeZone: USER_ZONE }).categoryTags).toEqual(['work', 'waiting'])
  })

  it('round-trips a folder and defaults legacy reminders to unfiled', () => {
    expect(draftFromReminder(reminder({}), USER_ZONE).folderID).toBeNull()

    const draft = draftFromReminder(reminder({ folderID: 'folder-trip' }), USER_ZONE)
    expect(draft.folderID).toBe('folder-trip')
    expect(reminderFieldsFromDraft(draft, { timeZone: USER_ZONE }).folderID).toBe('folder-trip')
  })

  it('round-trips checklist items and drops empty draft rows', () => {
    expect(draftFromReminder(reminder({}), USER_ZONE).checklist).toEqual([])

    const draft = draftFromReminder(
      reminder({ checklist: [{ id: 'step-1', title: 'Draft the note', isCompleted: true }] }),
      USER_ZONE,
    )
    draft.checklist.push({ id: 'step-2', title: '  Send it  ', isCompleted: false })
    draft.checklist.push({ id: 'step-3', title: '   ', isCompleted: false })

    expect(reminderFieldsFromDraft(draft, { timeZone: USER_ZONE }).checklist).toEqual([
      { id: 'step-1', title: 'Draft the note', isCompleted: true },
      { id: 'step-2', title: 'Send it', isCompleted: false },
    ])
  })
})

describe('validation and the guard', () => {
  it('requires a title before anything else', () => {
    expect(validateFollowUpDraft(emptyFollowUpDraft(USER_ZONE))).toBeTruthy()
  })

  it('fires only for temporal language with No date selected', () => {
    const scheduled = emptyFollowUpDraft(USER_ZONE)
    scheduled.title = 'Attend Monday 10am CT meeting with Kelly Tsaur'
    expect(followUpNeedsTemporalGuard(scheduled)).toBe(true)

    scheduled.schedule = { scheduleMode: 'deadline', localDate: '2026-08-10', localTime: '10:00', timeZone: USER_ZONE }
    expect(followUpNeedsTemporalGuard(scheduled)).toBe(false)

    const plain = emptyFollowUpDraft(USER_ZONE)
    plain.title = 'Send the neighborhood list'
    expect(followUpNeedsTemporalGuard(plain)).toBe(false)
  })
})

describe('detectDeadlineFromText', () => {
  const context = { now: new Date('2026-08-06T15:00:00'), timeZone: USER_ZONE }

  it('extracts the Monday 10am CT fixture with zone and label', () => {
    const detected = detectDeadlineFromText('Attend Monday 10am CT meeting with Kelly Tsaur', context)
    expect(detected).not.toBeNull()
    expect(detected!.localDate).toBe('2026-08-10')
    expect(detected!.localTime).toBe('10:00')
    expect(detected!.timeZone).toBe('America/Chicago')
    expect(detected!.label).toBe('Monday at 10:00 AM CT')
  })

  it('handles tomorrow with a pm time and no zone', () => {
    const detected = detectDeadlineFromText('call her tomorrow at 3pm', context)
    expect(detected!.localDate).toBe('2026-08-07')
    expect(detected!.localTime).toBe('15:00')
    expect(detected!.timeZone).toBeNull()
  })

  it('returns a date-only detection for a bare weekday', () => {
    const detected = detectDeadlineFromText('send the deck by Friday', context)
    expect(detected!.localDate).toBe('2026-08-07')
    expect(detected!.localTime).toBeNull()
  })

  it('gives up quietly on unparseable phrasing', () => {
    expect(detectDeadlineFromText('send the deck soon', context)).toBeNull()
  })
})
