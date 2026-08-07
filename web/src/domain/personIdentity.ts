/// Who somebody is at a glance. For a named person that is their name; for an
/// unnamed one it is the relationship word plus up to three distinguishing
/// facts — "Son · Age 13 · 8th grade · Sailor" — chosen by relationship kind,
/// so two unnamed sons stop being identical rows. Pure selection over the
/// fact ledger; restricted facts never surface here.

import { attributeLabel, currentValues, FactAttributes, type FactAttribute, type Observation } from './facts'
import type { Person } from './person'
import { kindLabel, type Relationship, type RelationshipKind } from './relationships'

export interface IdentityDetail {
  attribute: FactAttribute
  label: string
  value: string
}

export interface RelationshipIdentitySummary {
  primaryLabel: string
  details: IdentityDetail[]
  accessibleLabel: string
}

/// Detail priority per relationship kind — the facts most likely to tell two
/// people of that kind apart.
function detailPriority(kind: RelationshipKind): FactAttribute[] {
  switch (kind) {
    case 'child':
    case 'pet':
      return [FactAttributes.observedAge, FactAttributes.schoolGrade, FactAttributes.school, FactAttributes.quickFact]
    case 'colleague':
    case 'manager':
    case 'directReport':
    case 'worksWith':
      return [FactAttributes.role, FactAttributes.employer, FactAttributes.location, FactAttributes.quickFact]
    default:
      return [FactAttributes.location, FactAttributes.employer, FactAttributes.quickFact]
  }
}

/// Natural phrasing: "Age 13", "8th grade", "Riverside Middle School", "Sailor".
function formatDetail(attribute: FactAttribute, value: string): string {
  if (attribute === FactAttributes.observedAge) return `Age ${value}`
  if (attribute === FactAttributes.schoolGrade) return /grade/i.test(value) ? value : `${value} grade`
  return value
}

function sentenceCase(text: string): string {
  if (!text) return text
  return text[0].toUpperCase() + text.slice(1)
}

export function relationshipIdentitySummary(args: {
  subject: Person
  other: Person
  relationship: Relationship
  observations: Observation[]
}): RelationshipIdentitySummary {
  const { other, relationship, observations } = args

  const primaryLabel = other.hasStatedName
    ? other.displayName
    : sentenceCase(relationship.customLabel ?? kindLabel(relationship.kind))

  const details: IdentityDetail[] = []
  for (const attribute of detailPriority(relationship.kind)) {
    if (details.length >= 3) break
    const current = currentValues(observations, attribute).filter((o) => o.sensitivity !== 'restricted')
    const first = current[0]
    if (!first || !first.value.trim()) continue
    details.push({ attribute, label: attributeLabel(attribute), value: formatDetail(attribute, first.value.trim()) })
  }

  const relationWord = relationship.customLabel ?? kindLabel(relationship.kind)
  const accessibleParts = other.hasStatedName
    ? [other.displayName, relationWord, ...details.map((d) => d.value)]
    : [sentenceCase(relationWord), ...details.map((d) => d.value)]

  return {
    primaryLabel,
    details,
    accessibleLabel: accessibleParts.join(', '),
  }
}

/// Pairs of unnamed people on the same subject that may be hard to tell apart:
/// same kind and same custom label. The comparison key is order-independent so
/// a dismissal persists regardless of row order.
export interface UnnamedPairSuggestion {
  key: string
  kind: RelationshipKind
  label: string | null
  people: [Person, Person]
}

export function comparisonKey(a: Person, b: Person): string {
  return [a.id, b.id].sort().join('~')
}

export function unnamedPairSuggestions(
  relationships: Relationship[],
  peopleByID: Map<string, Person>,
  dismissedKeys: Set<string>,
): UnnamedPairSuggestion[] {
  const groups = new Map<string, { kind: RelationshipKind; label: string | null; people: Person[] }>()
  for (const relationship of relationships) {
    const other = peopleByID.get(relationship.otherID)
    if (!other || other.hasStatedName) continue
    const label = relationship.customLabel?.trim().toLowerCase() ?? null
    const groupKey = `${relationship.kind}|${label ?? ''}`
    const group = groups.get(groupKey) ?? { kind: relationship.kind, label: relationship.customLabel ?? null, people: [] }
    if (!group.people.some((p) => p.id === other.id)) group.people.push(other)
    groups.set(groupKey, group)
  }

  const suggestions: UnnamedPairSuggestion[] = []
  for (const group of groups.values()) {
    if (group.people.length < 2) continue
    for (let i = 0; i < group.people.length; i++) {
      for (let j = i + 1; j < group.people.length; j++) {
        const key = comparisonKey(group.people[i], group.people[j])
        if (dismissedKeys.has(key)) continue
        suggestions.push({ key, kind: group.kind, label: group.label, people: [group.people[i], group.people[j]] })
      }
    }
  }
  return suggestions
}
