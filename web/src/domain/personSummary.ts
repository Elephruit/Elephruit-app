import { FactAttributes, currentValues, type Observation } from './facts'
import type { Interaction } from './interaction'
import { profileFocusOf, type Person, type ProfileFocus } from './person'
import type { Relationship } from './relationships'
import type { Reminder } from './reminders'

export interface PersonSummary {
  focus: ProfileFocus
  role: string | null
  organization: string | null
  location: string | null
  introducedBy: Person | null
  firstMetOn: Date | null
  firstMetContext: string | null
  firstMeetingPlanned: boolean
  nextReminder: Reminder | null
}

function current(observations: Observation[], attribute: string): string | null {
  return currentValues(observations, attribute)
    .find((value) => value.sensitivity !== 'restricted')?.value ?? null
}

/// One read model for the header and working board. Direct identity fields win
/// when present; the observation ledger fills the gaps so a fact cannot be
/// visible in the sidebar and mysteriously absent from the person's nameplate.
export function summarizePerson(args: {
  person: Person
  people: Person[]
  observations: Observation[]
  relationships: Relationship[]
  interactions: Interaction[]
  reminders: Reminder[]
  now: Date
}): PersonSummary {
  const { person, people, observations, relationships, interactions, reminders, now } = args
  const origin = person.connectionOrigin ?? null
  const introducedByRelationship = relationships.find((relationship) => relationship.kind === 'introducedBy')
  const introducedByID = origin?.introducedByPersonID ?? introducedByRelationship?.otherID ?? null
  const firstLoggedInteraction = [...interactions]
    .filter((interaction) => interaction.provenance === 'logged')
    .sort((a, b) => a.occurredAt.getTime() - b.occurredAt.getTime())[0]
  const firstMetOn = origin?.firstMetOn ?? firstLoggedInteraction?.occurredAt ?? null

  const open = reminders
    .filter((reminder) => reminder.status === 'open')
    .sort((a, b) => {
      const left = a.dueAt ?? a.startAt
      const right = b.dueAt ?? b.startAt
      if (left === null) return 1
      if (right === null) return -1
      return left.getTime() - right.getTime()
    })

  return {
    focus: profileFocusOf(person),
    role: person.roleTitle?.trim() || current(observations, FactAttributes.role),
    organization: person.organizationName?.trim() || current(observations, FactAttributes.employer),
    location: current(observations, FactAttributes.location),
    introducedBy: introducedByID ? people.find((candidate) => candidate.id === introducedByID) ?? null : null,
    firstMetOn,
    firstMetContext: origin?.context ?? null,
    firstMeetingPlanned: origin?.status === 'introductionPlanned' && (firstMetOn === null || firstMetOn > now),
    nextReminder: open[0] ?? null,
  }
}
