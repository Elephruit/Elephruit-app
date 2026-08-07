/// The read direction of the AI street: assembling what the model is allowed
/// to see for a day brief. Pure selection and phrasing over data other rules
/// already derived — current fact values, reminder buckets, contact recency.
///
/// The privacy line is drawn here, not in the caller: restricted-sensitivity
/// facts never enter the payload, so no prompt-building mistake downstream can
/// leak them. Sensitive facts are included — the user pasted their own key and
/// asked to be prepared; hiding "normal" context would make the brief useless —
/// but restricted means restricted.

import { lastContactLine } from './contact'
import { startOfDay, wholeDaysBetween } from './dates'
import {
  attributeLabel,
  confidenceNeedsLabel,
  CONFIDENCE_LABELS,
  currentValues,
  effectiveConfidence,
  populatedAttributes,
  type Observation,
} from './facts'
import type { Interaction } from './interaction'
import type { Person } from './person'
import { kindLabel, type Relationship } from './relationships'
import { bucketFor, type Reminder } from './reminders'
import { excerptOf } from './timeline'

export interface BriefingFact {
  label: string
  value: string
  /// Present only when the displayed confidence has decayed below stated.
  confidence?: string
}

export interface BriefingPerson {
  name: string
  role: string | null
  lastContact: string
  facts: BriefingFact[]
  relationships: string[]
  openFollowUps: string[]
  recentInteractions: Array<{ when: string; kind: string; summary: string; notes: string | null }>
}

export interface BriefingInput {
  date: string
  people: BriefingPerson[]
}

/// Who a day brief is about when the user doesn't say: everyone attached to an
/// overdue or today follow-up, most urgent first, deduplicated.
export function defaultBriefingPersonIDs(reminders: Reminder[], now: Date): string[] {
  const ids: string[] = []
  const seen = new Set<string>()
  const open = reminders.filter((reminder) => reminder.status === 'open')
  for (const bucket of ['overdue', 'today'] as const) {
    for (const reminder of open) {
      if (bucketFor(reminder, now) !== bucket) continue
      for (const id of reminder.personIDs) {
        if (seen.has(id)) continue
        seen.add(id)
        ids.push(id)
      }
    }
  }
  return ids
}

function followUpPhrase(reminder: Reminder, now: Date): string {
  const bucket = bucketFor(reminder, now)
  if (bucket === 'overdue' && reminder.dueAt) {
    const days = wholeDaysBetween(startOfDay(reminder.dueAt), startOfDay(now))
    return `${reminder.title} (due ${days} day${days === 1 ? '' : 's'} ago)`
  }
  if (bucket === 'today') return `${reminder.title} (due today)`
  if (reminder.dueAt) {
    return `${reminder.title} (due ${reminder.dueAt.toLocaleDateString(undefined, { month: 'short', day: 'numeric' })})`
  }
  return reminder.title
}

export function briefingInputFor(
  targets: Person[],
  observationsByPerson: Map<string, Observation[]>,
  relationships: Relationship[],
  peopleByID: Map<string, Person>,
  reminders: Reminder[],
  interactions: Interaction[],
  now: Date,
): BriefingInput {
  const people = targets.map((person): BriefingPerson => {
    const observations = (observationsByPerson.get(person.id) ?? []).filter(
      (observation) => observation.sensitivity !== 'restricted',
    )

    const facts: BriefingFact[] = []
    for (const attribute of populatedAttributes(observations)) {
      for (const observation of currentValues(observations, attribute)) {
        const confidence = effectiveConfidence(observation, now)
        facts.push({
          label: attributeLabel(attribute),
          value: observation.value,
          ...(confidenceNeedsLabel(confidence) ? { confidence: CONFIDENCE_LABELS[confidence] } : {}),
        })
      }
    }

    const related = relationships
      .filter((relationship) => relationship.subjectID === person.id)
      .map((relationship) => {
        const other = peopleByID.get(relationship.otherID)
        const label = relationship.customLabel ?? kindLabel(relationship.kind)
        if (!other) return `${label}: unknown`
        return other.hasStatedName ? `${label}: ${other.displayName}` : `${label}: unnamed ("${other.displayName}")`
      })

    const openFollowUps = reminders
      .filter((reminder) => reminder.status === 'open' && reminder.personIDs.includes(person.id))
      .map((reminder) => followUpPhrase(reminder, now))

    const recentInteractions = interactions
      .filter((interaction) => interaction.participantIDs.includes(person.id))
      .sort((a, b) => b.occurredAt.getTime() - a.occurredAt.getTime())
      .slice(0, 5)
      .map((interaction) => ({
        when: interaction.occurredAt.toLocaleDateString(undefined, { month: 'short', day: 'numeric' }),
        kind: interaction.kind,
        summary: interaction.summary,
        notes: interaction.discussion ? excerptOf(interaction.discussion) : null,
      }))

    return {
      name: person.displayName,
      role: [person.roleTitle, person.organizationName].filter(Boolean).join(' · ') || null,
      lastContact: lastContactLine(person.lastContactAt, now),
      facts,
      relationships: related,
      openFollowUps,
      recentInteractions,
    }
  })

  return {
    date: now.toLocaleDateString(undefined, { weekday: 'long', year: 'numeric', month: 'long', day: 'numeric' }),
    people,
  }
}
