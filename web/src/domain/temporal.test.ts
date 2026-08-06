import { describe, expect, it } from 'vitest'
import {
  formatScheduleSummary,
  hasTemporalCue,
  isValidTimeZone,
  resolveProposedSchedule,
  resolveScheduleDraft,
  validateScheduleDraft,
  zonedTimeToUtc,
  type ProposedSchedule,
} from './temporal'

const CHICAGO = { timeZone: 'America/Chicago' }

function schedule(overrides: Partial<ProposedSchedule>): ProposedSchedule {
  return {
    mode: 'none',
    localDate: null,
    localTime: null,
    timeZone: null,
    sourceText: null,
    confidence: 'stated',
    ...overrides,
  }
}

describe('zonedTimeToUtc', () => {
  it('resolves Central Daylight Time correctly in August', () => {
    // 2026-08-10 10:00 America/Chicago is UTC-5 (CDT) → 15:00Z.
    const utc = zonedTimeToUtc('2026-08-10', '10:00', 'America/Chicago')
    expect(utc.toISOString()).toBe('2026-08-10T15:00:00.000Z')
  })

  it('resolves Central Standard Time correctly in January', () => {
    // Winter is UTC-6 (CST) → 16:00Z.
    const utc = zonedTimeToUtc('2026-01-12', '10:00', 'America/Chicago')
    expect(utc.toISOString()).toBe('2026-01-12T16:00:00.000Z')
  })

  it('uses the offset of the selected date, not of today', () => {
    // DST conversion must follow the target date across the transition.
    const summer = zonedTimeToUtc('2026-07-01', '12:00', 'Europe/Berlin') // UTC+2
    const winter = zonedTimeToUtc('2026-12-01', '12:00', 'Europe/Berlin') // UTC+1
    expect(summer.toISOString()).toBe('2026-07-01T10:00:00.000Z')
    expect(winter.toISOString()).toBe('2026-12-01T11:00:00.000Z')
  })
})

describe('resolveProposedSchedule', () => {
  it('turns the Monday 10am CT meeting into a timed Central deadline', () => {
    const resolved = resolveProposedSchedule(
      schedule({
        mode: 'deadline',
        localDate: '2026-08-10',
        localTime: '10:00',
        timeZone: 'America/Chicago',
        sourceText: 'Monday 10am CT',
      }),
      CHICAGO,
    )
    expect(resolved.dueAt?.toISOString()).toBe('2026-08-10T15:00:00.000Z')
    expect(resolved.startAt).toBeNull()
    expect(resolved.duePrecision).toBe('dateTime')
    expect(resolved.scheduleTimeZone).toBe('America/Chicago')
    expect(resolved.isSomeday).toBe(false)
  })

  it('keeps a date-only deadline at day precision with no zone attached', () => {
    const resolved = resolveProposedSchedule(
      schedule({ mode: 'deadline', localDate: '2026-08-14', sourceText: 'by Friday' }),
      CHICAGO,
    )
    expect(resolved.duePrecision).toBe('date')
    expect(resolved.scheduleTimeZone).toBeNull()
    // Stored at browser-local midnight of the 14th.
    expect(resolved.dueAt?.getFullYear()).toBe(2026)
    expect(resolved.dueAt?.getMonth()).toBe(7)
    expect(resolved.dueAt?.getDate()).toBe(14)
    expect(resolved.dueAt?.getHours()).toBe(0)
  })

  it('puts a start on startAt and never on dueAt', () => {
    const resolved = resolveProposedSchedule(
      schedule({ mode: 'start', localDate: '2026-08-10', sourceText: 'Monday' }),
      CHICAGO,
    )
    expect(resolved.startAt).not.toBeNull()
    expect(resolved.dueAt).toBeNull()
    expect(resolved.startPrecision).toBe('date')
  })

  it('maps someday and none to their unscheduled shapes', () => {
    expect(resolveProposedSchedule(schedule({ mode: 'someday' }), CHICAGO).isSomeday).toBe(true)
    const none = resolveProposedSchedule(schedule({ mode: 'none' }), CHICAGO)
    expect(none.dueAt).toBeNull()
    expect(none.startAt).toBeNull()
    expect(none.isSomeday).toBe(false)
  })

  it('degrades malformed proposals to unscheduled instead of guessing', () => {
    expect(resolveProposedSchedule(schedule({ mode: 'deadline', localDate: null }), CHICAGO).dueAt).toBeNull()
    expect(resolveProposedSchedule(schedule({ mode: 'deadline', localDate: 'next monday' }), CHICAGO).dueAt).toBeNull()
  })

  it('falls back to the user zone when the proposed zone is invalid', () => {
    const resolved = resolveProposedSchedule(
      schedule({ mode: 'deadline', localDate: '2026-08-10', localTime: '10:00', timeZone: 'CT' }),
      CHICAGO,
    )
    expect(resolved.scheduleTimeZone).toBe('America/Chicago')
    expect(resolved.dueAt?.toISOString()).toBe('2026-08-10T15:00:00.000Z')
  })
})

describe('hasTemporalCue', () => {
  it('catches the screenshot fixture even if the model returned no schedule', () => {
    expect(hasTemporalCue('Attend Monday 10am CT meeting with Kelly Tsaur')).toBe(true)
  })

  it('catches the cue families the parser is told about', () => {
    for (const text of [
      'call her tomorrow',
      'send it by Friday',
      'lunch at 12',
      'flight on August 14',
      'review 8/10',
      'standup 9:30',
      'deck due 2026-08-14',
      'dinner tonight',
      'next week checkin',
      'noon walk',
      'Mon 10 sync',
    ]) {
      expect(hasTemporalCue(text), text).toBe(true)
    }
  })

  it('stays quiet on ordinary language', () => {
    for (const text of [
      'Send the neighborhood list',
      'we sat with the design team',
      'ask about the wedding photographer',
      'she wed last spring',
      'talk through the monthly budget',
      'work on the deck',
    ]) {
      expect(hasTemporalCue(text), text).toBe(false)
    }
  })
})

describe('formatScheduleSummary', () => {
  const base = {
    startAt: null as Date | null,
    dueAt: null as Date | null,
    isSomeday: false,
    scheduleTimeZone: null as string | null,
    duePrecision: null as 'date' | 'dateTime' | null,
    startPrecision: null as 'date' | 'dateTime' | null,
  }

  it('shows a timed deadline in its own zone with the zone name', () => {
    const label = formatScheduleSummary(
      {
        ...base,
        dueAt: new Date('2026-08-10T15:00:00.000Z'),
        duePrecision: 'dateTime',
        scheduleTimeZone: 'America/Chicago',
      },
      'en-US',
    )
    expect(label).toContain('Aug 10')
    expect(label).toContain('10:00')
    expect(label).toContain('CDT')
  })

  it('labels date-only deadlines, starts, someday, and no date distinctly', () => {
    expect(
      formatScheduleSummary({ ...base, dueAt: new Date(2026, 7, 10), duePrecision: 'date' }, 'en-US'),
    ).toMatch(/^Due /)
    expect(
      formatScheduleSummary({ ...base, startAt: new Date(2026, 7, 10), startPrecision: 'date' }, 'en-US'),
    ).toMatch(/^Starts /)
    expect(formatScheduleSummary({ ...base, isSomeday: true }, 'en-US')).toBe('Someday')
    expect(formatScheduleSummary(base, 'en-US')).toBeNull()
  })
})

describe('draft validation and resolution', () => {
  it('validates only what the active mode needs', () => {
    expect(validateScheduleDraft({ scheduleMode: 'none', localDate: '', localTime: '', timeZone: '' })).toBeNull()
    expect(validateScheduleDraft({ scheduleMode: 'someday', localDate: '', localTime: '', timeZone: '' })).toBeNull()
    expect(validateScheduleDraft({ scheduleMode: 'deadline', localDate: '', localTime: '', timeZone: '' })).toBeTruthy()
    expect(
      validateScheduleDraft({ scheduleMode: 'deadline', localDate: '2026-08-10', localTime: '', timeZone: '' }),
    ).toBeNull()
    expect(
      validateScheduleDraft({
        scheduleMode: 'deadline',
        localDate: '2026-08-10',
        localTime: '10:00',
        timeZone: 'America/Chicago',
      }),
    ).toBeNull()
    expect(
      validateScheduleDraft({ scheduleMode: 'deadline', localDate: '2026-08-10', localTime: '10:00', timeZone: 'CT' }),
    ).toBeTruthy()
  })

  it('resolves drafts through the same conversion as proposals', () => {
    const resolved = resolveScheduleDraft(
      { scheduleMode: 'deadline', localDate: '2026-08-10', localTime: '10:00', timeZone: 'America/Chicago' },
      CHICAGO,
    )
    expect(resolved.dueAt?.toISOString()).toBe('2026-08-10T15:00:00.000Z')
    expect(resolved.duePrecision).toBe('dateTime')
  })

  it('knows a real zone from an abbreviation', () => {
    expect(isValidTimeZone('America/Chicago')).toBe(true)
    expect(isValidTimeZone('CT')).toBe(false)
  })
})
