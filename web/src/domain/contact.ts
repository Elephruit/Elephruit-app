/// When you last actually spoke to someone — ported from the Mac app's
/// PersonContext, where every field is derived and nothing is stored. Writing a
/// reminder about someone is not contact with them; only interactions whose
/// provenance counts (logged, today the only kind this app writes) move the date.

import { startOfDay, wholeDaysBetween } from './dates'
import { countsAsContact, type Interaction } from './interaction'

/// The newest moment of real contact with one person, or null if there has never
/// been one. Derived from the interactions; the person document's `lastContactAt`
/// field is only ever a cache of this.
export function deriveLastContact(interactions: Interaction[], personID: string): Date | null {
  let latest: Date | null = null
  for (const interaction of interactions) {
    if (!countsAsContact(interaction.provenance)) continue
    if (!interaction.participantIDs.includes(personID)) continue
    if (latest === null || interaction.occurredAt.getTime() > latest.getTime()) {
      latest = interaction.occurredAt
    }
  }
  return latest
}

/// "yesterday", "3 weeks ago", "in 4 days" — whichever reads best at that
/// distance. Ported verbatim from ContactMoment.relativeDescription.
export function relativeDescription(date: Date, now: Date): string {
  const days = wholeDaysBetween(date, startOfDay(now))

  if (days < -1) return `in ${-days} days`
  if (days === -1) return 'tomorrow'
  if (days === 0) return 'today'
  if (days === 1) return 'yesterday'
  if (days <= 6) return `${days} days ago`
  if (days <= 13) return 'last week'
  if (days <= 59) return `${Math.floor(days / 7)} weeks ago`
  return `${Math.floor(days / 30)} months ago`
}

/// The one line at the top of a person's page. Says what is true, never what to
/// do about it — the recommendation half is FollowUpPolicy, opt-in and separate.
/// Two different absences are two different sentences: a populated profile with
/// no conversations must never claim nothing was recorded.
export function lastContactLine(lastContactAt: Date | null, now: Date, hasProfileData = false): string {
  if (lastContactAt === null) return hasProfileData ? 'No conversations logged yet' : 'Nothing recorded yet'
  return `Last spoke ${relativeDescription(lastContactAt, now)}`
}

export function daysSinceContact(lastContactAt: Date | null, now: Date): number | null {
  if (lastContactAt === null) return null
  return Math.max(0, wholeDaysBetween(lastContactAt, startOfDay(now)))
}

// MARK: Follow-up suggestions

/// Six weeks: long enough that a nudge is not nagging, short enough that it
/// arrives while getting back in touch is still natural.
export const DEFAULT_FOLLOW_UP_THRESHOLD_DAYS = 42

export interface FollowUpSuggestion {
  personID: string
  displayName: string
  daysSinceContact: number
}

/// Which people are worth mentioning, most-overdue first. Someone with no
/// recorded contact at all is never suggested — there is nothing to follow up on,
/// and treating an empty record as "overdue by forever" would fill the list with
/// everyone the user ever typed a name for. Suggestions never write anything:
/// no reminder, no notification. And the feature is off by default — an app that
/// starts telling you who you have neglected, unprompted, is a worse product than
/// one that answers when asked.
export function followUpSuggestions(
  people: Array<{ personID: string; displayName: string; lastContactAt: Date | null }>,
  now: Date,
  thresholdDays: number = DEFAULT_FOLLOW_UP_THRESHOLD_DAYS,
): FollowUpSuggestion[] {
  const suggestions: FollowUpSuggestion[] = []
  for (const person of people) {
    const days = daysSinceContact(person.lastContactAt, now)
    if (days === null || days < thresholdDays) continue
    suggestions.push({ personID: person.personID, displayName: person.displayName, daysSinceContact: days })
  }
  return suggestions.sort((a, b) => b.daysSinceContact - a.daysSinceContact)
}
