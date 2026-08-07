/// The feed and the person timeline are projections, never stored. A person's
/// history *is* the interactions, reminders, and observations that already point
/// at them — writing a row per event would create a second copy that goes wrong
/// the first time anything is edited. Ported from PersonTimeline.swift.

import { startOfDay } from './dates'
import { attributeLabel, type Observation } from './facts'
import {
  countsAsContact,
  provenancePhrase,
  type Interaction,
  type InteractionKind,
  type InteractionProvenance,
} from './interaction'
import type { Reminder } from './reminders'

export type TimelineEntryKind = 'interaction' | 'reminder' | 'observation'

export interface PersonRef {
  id: string
  name: string
}

export interface TimelineEntry {
  id: string
  kind: TimelineEntryKind
  title: string
  /// A short piece of the longer text, for a row that has room for one.
  excerpt: string | null
  /// When it happened — an interaction's occurredAt, everything else's own date.
  date: Date
  interactionKind: InteractionKind | null
  provenance: InteractionProvenance | null
  /// Everybody else involved.
  otherPeople: PersonRef[]
  /// Whether the underlying item is still open — a follow-up not yet done.
  isOpen: boolean
  sourceInteractionID: string | null
}

const EXCERPT_LENGTH = 140

export function excerptOf(text: string | null): string | null {
  const trimmed = text?.trim()
  if (!trimmed) return null
  if (trimmed.length <= EXCERPT_LENGTH) return trimmed
  return `${trimmed.slice(0, EXCERPT_LENGTH - 1).trimEnd()}…`
}

/// Builds the feed/timeline rows. `viewpointPersonID` removes the person whose
/// page this is from their own "with …" lines; the global feed passes null and
/// sees every participant.
export function entryFromInteraction(
  interaction: Interaction,
  peopleByID: Map<string, { displayName: string }>,
  viewpointPersonID: string | null = null,
): TimelineEntry {
  const otherPeople = interaction.participantIDs
    .filter((id) => id !== viewpointPersonID)
    .map((id) => ({ id, name: peopleByID.get(id)?.displayName ?? 'Somebody' }))

  return {
    id: interaction.id,
    kind: 'interaction',
    title: interaction.summary,
    excerpt: excerptOf(interaction.discussion),
    date: interaction.occurredAt,
    interactionKind: interaction.kind,
    provenance: interaction.provenance,
    otherPeople,
    isOpen: false,
    sourceInteractionID: null,
  }
}

export function entryFromReminder(reminder: Reminder): TimelineEntry {
  return {
    id: reminder.id,
    kind: 'reminder',
    title: reminder.title,
    excerpt: excerptOf(reminder.notes),
    date: reminder.createdAt,
    interactionKind: null,
    provenance: null,
    otherPeople: [],
    isOpen: reminder.status === 'open',
    sourceInteractionID: reminder.sourceInteractionID,
  }
}

export function entryFromObservation(observation: Observation): TimelineEntry {
  return {
    id: observation.id,
    kind: 'observation',
    title: `${attributeLabel(observation.attribute)}: ${observation.value}`,
    excerpt: null,
    date: observation.observedOn,
    interactionKind: null,
    provenance: null,
    otherPeople: [],
    isOpen: false,
    sourceInteractionID: observation.sourceInteractionID,
  }
}

/// The line beneath a row's title: what kind of thing this is and who else.
/// Ported from PersonTimelineEntry.provenanceLine.
export function provenanceLine(entry: TimelineEntry): string {
  const parts: string[] = []

  if (entry.kind === 'interaction' && entry.provenance) {
    parts.push(provenancePhrase(entry.provenance, entry.interactionKind))
  } else if (entry.kind === 'reminder') {
    parts.push(entry.isOpen ? 'follow-up' : 'follow-up · done')
  } else if (entry.kind === 'observation') {
    parts.push('fact noted')
  }

  if (entry.otherPeople.length > 0) {
    parts.push(`with ${entry.otherPeople.map((p) => p.name).join(', ')}`)
  }

  return parts.join(' · ')
}

/// Whether this counts as having actually been in touch — the same rule as
/// deriveLastContact, restated for a row so the two can never disagree.
export function entryIsContact(entry: TimelineEntry): boolean {
  return entry.kind === 'interaction' && entry.provenance !== null && countsAsContact(entry.provenance)
}

// MARK: Grouping

export interface DayGroup {
  day: Date
  entries: TimelineEntry[]
}

export interface MonthGroup {
  month: Date
  entries: TimelineEntry[]
}

function sortedDesc(entries: TimelineEntry[]): TimelineEntry[] {
  return [...entries].sort((a, b) => b.date.getTime() - a.date.getTime())
}

/// Days newest first, entries newest first inside each — the feed's shape.
export function groupByDay(entries: TimelineEntry[]): DayGroup[] {
  const groups = new Map<number, TimelineEntry[]>()
  for (const entry of sortedDesc(entries)) {
    const key = startOfDay(entry.date).getTime()
    const list = groups.get(key) ?? []
    list.push(entry)
    groups.set(key, list)
  }
  return [...groups.entries()]
    .sort((a, b) => b[0] - a[0])
    .map(([key, list]) => ({ day: new Date(key), entries: list }))
}

/// Months newest first — the person page's shape.
export function groupByMonth(entries: TimelineEntry[]): MonthGroup[] {
  const groups = new Map<number, TimelineEntry[]>()
  for (const entry of sortedDesc(entries)) {
    const month = new Date(entry.date.getFullYear(), entry.date.getMonth(), 1)
    const key = month.getTime()
    const list = groups.get(key) ?? []
    list.push(entry)
    groups.set(key, list)
  }
  return [...groups.entries()]
    .sort((a, b) => b[0] - a[0])
    .map(([key, list]) => ({ month: new Date(key), entries: list }))
}

// MARK: Filters

/// The filters a timeline offers, each naming the kinds it keeps. `files` is kept
/// so the filter set stays total with the Mac app's, but nothing in the spike can
/// match it — the chip is simply not shown.
export const TIMELINE_FILTERS = ['everything', 'conversations', 'notes', 'commitments', 'files'] as const
export type TimelineFilter = (typeof TIMELINE_FILTERS)[number]

export const FILTER_LABELS: Record<TimelineFilter, string> = {
  everything: 'Everything',
  conversations: 'Conversations',
  notes: 'Notes',
  commitments: 'Reminders',
  files: 'Files',
}

export function matchesFilter(filter: TimelineFilter, entry: TimelineEntry): boolean {
  switch (filter) {
    case 'everything':
      return true
    case 'conversations':
      return entry.kind === 'interaction'
    case 'notes':
      return entry.kind === 'observation'
    case 'commitments':
      return entry.kind === 'reminder'
    case 'files':
      return false
  }
}
