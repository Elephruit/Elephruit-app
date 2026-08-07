import { describe, expect, it } from 'vitest'
import type { Interaction } from './interaction'
import {
  entryFromInteraction,
  entryFromObservation,
  entryFromReminder,
  entryIsContact,
  excerptOf,
  groupByDay,
  groupByMonth,
  matchesFilter,
  projectPersonTimeline,
  provenanceLine,
  type TimelineEntry,
} from './timeline'
import type { Observation } from './facts'
import type { Reminder } from './reminders'

const people = new Map([
  ['ana', { displayName: 'Ana Torres' }],
  ['sam', { displayName: 'Sam Ruiz' }],
])

const interaction: Interaction = {
  id: 'int-1',
  kind: 'phone',
  provenance: 'logged',
  summary: 'Caught up about the move',
  discussion: 'Long chat about Portland neighborhoods and the timing of the move next spring.',
  participantIDs: ['ana', 'sam'],
  occurredAt: new Date('2026-08-05T10:00:00'),
  createdAt: new Date('2026-08-05T10:10:00'),
}

const reminder: Reminder = {
  id: 'rem-1',
  title: 'Send neighborhood list',
  notes: null,
  personIDs: ['ana'],
  sourceInteractionID: 'int-1',
  startAt: null,
  dueAt: null,
  isSomeday: false,
  status: 'open',
  completedAt: null,
  createdAt: new Date('2026-08-05T10:10:00'),
}

const observation: Observation = {
  id: 'obs-1',
  subjectID: 'ana',
  attribute: 'location',
  value: 'Portland',
  observedOn: new Date('2026-07-01T09:00:00'),
  effectiveOn: null,
  lastConfirmedOn: new Date('2026-07-01T09:00:00'),
  confidence: 'stated',
  sensitivity: 'normal',
  sourceInteractionID: null,
  supersedesID: null,
  supersededOn: null,
  correctionNote: null,
  createdAt: new Date('2026-07-01T09:00:00'),
}

describe('entries', () => {
  it('shows every participant on the feed and everyone-but-you on your page', () => {
    const feedRow = entryFromInteraction(interaction, people, null)
    expect(feedRow.otherPeople.map((p) => p.name)).toEqual(['Ana Torres', 'Sam Ruiz'])

    const anaRow = entryFromInteraction(interaction, people, 'ana')
    expect(anaRow.otherPeople.map((p) => p.name)).toEqual(['Sam Ruiz'])
    expect(provenanceLine(anaRow)).toBe('phone — logged · with Sam Ruiz')
  })

  it('describes reminders and facts without pretending they are conversations', () => {
    const reminderRow = entryFromReminder(reminder)
    expect(provenanceLine(reminderRow)).toBe('follow-up')
    expect(entryIsContact(reminderRow)).toBe(false)

    const factRow = entryFromObservation(observation)
    expect(factRow.title).toBe('Lives in: Portland')
    expect(provenanceLine(factRow)).toBe('fact noted')
    expect(entryIsContact(factRow)).toBe(false)
    expect(entryIsContact(entryFromInteraction(interaction, people))).toBe(true)
  })

  it('cuts excerpts at 140 characters without splitting mid-word garbage', () => {
    expect(excerptOf('short note')).toBe('short note')
    expect(excerptOf('   ')).toBeNull()
    const long = 'a'.repeat(200)
    expect(excerptOf(long)!.length).toBe(140)
    expect(excerptOf(long)!.endsWith('…')).toBe(true)
  })

  it('keeps facts extracted from an interaction inside that interaction', () => {
    const sourced = { ...observation, id: 'obs-sourced', sourceInteractionID: interaction.id }
    const rows = projectPersonTimeline({
      interactions: [interaction],
      observations: [observation, sourced],
      reminders: [],
      peopleByID: people,
      viewpointPersonID: 'ana',
    })

    expect(rows.map((row) => row.id)).toEqual(['int-1', 'obs-1'])
  })
})

describe('grouping', () => {
  const entries: TimelineEntry[] = [
    entryFromInteraction(interaction, people),
    entryFromReminder(reminder),
    entryFromObservation(observation),
  ]

  it('groups the feed by day, newest first', () => {
    const days = groupByDay(entries)
    expect(days).toHaveLength(2)
    expect(days[0].entries.map((e) => e.id)).toEqual(['rem-1', 'int-1'])
    expect(days[1].entries.map((e) => e.id)).toEqual(['obs-1'])
  })

  it('groups the person page by month, newest first', () => {
    const months = groupByMonth(entries)
    expect(months).toHaveLength(2)
    expect(months[0].month.getMonth()).toBe(7) // August
    expect(months[1].month.getMonth()).toBe(6) // July
  })
})

describe('filters', () => {
  const rows = {
    interaction: entryFromInteraction(interaction, people),
    reminder: entryFromReminder(reminder),
    observation: entryFromObservation(observation),
  }

  it('partitions the timeline the way the Mac app does, and files matches nothing', () => {
    expect(matchesFilter('everything', rows.interaction)).toBe(true)
    expect(matchesFilter('conversations', rows.interaction)).toBe(true)
    expect(matchesFilter('conversations', rows.reminder)).toBe(false)
    expect(matchesFilter('notes', rows.observation)).toBe(true)
    expect(matchesFilter('commitments', rows.reminder)).toBe(true)
    expect(matchesFilter('files', rows.interaction)).toBe(false)
    expect(matchesFilter('files', rows.reminder)).toBe(false)
    expect(matchesFilter('files', rows.observation)).toBe(false)
  })
})
