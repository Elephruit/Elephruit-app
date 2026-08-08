/// How two people are related, ported from the Mac app's `RelationshipKind.swift`.
///
/// A relationship is one fact seen from two sides. Storing only one half means the
/// other person's page has to search everyone for someone who claims them; storing
/// both halves independently means they can disagree, which is worse. So the inverse
/// map is total (a test asserts the involution), and a relationship is always
/// created as a pair of rows maintained as a unit.

import { FactAttributes, type FactAttribute } from './facts'
import { newID } from './ids'

export const RELATIONSHIP_KINDS = [
  'partner',
  'parent',
  'child',
  'auntUncle',
  'nieceNephew',
  'sibling',
  'friend',
  'colleague',
  'manager',
  'directReport',
  'introducedBy',
  'introduced',
  'worksWith',
  'householdMember',
  'petOwner',
  'pet',
  'unknown',
] as const

export type RelationshipKind = (typeof RELATIONSHIP_KINDS)[number]

export interface Relationship {
  id: string
  /// Whose page this row reads on.
  subjectID: string
  otherID: string
  kind: RelationshipKind
  /// The user's own word ("son"). Never mirrored to the reciprocal — what Jack
  /// calls Maya is not derivable from what Maya calls Jack.
  customLabel: string | null
  /// The other half of the pair.
  reciprocalID: string
  createdAt: Date
}

/// The relationship seen from the other person's side. Total: every kind has one.
export const INVERSE: Record<RelationshipKind, RelationshipKind> = {
  partner: 'partner',
  parent: 'child',
  child: 'parent',
  auntUncle: 'nieceNephew',
  nieceNephew: 'auntUncle',
  sibling: 'sibling',
  friend: 'friend',
  colleague: 'colleague',
  manager: 'directReport',
  directReport: 'manager',
  introducedBy: 'introduced',
  introduced: 'introducedBy',
  worksWith: 'worksWith',
  householdMember: 'householdMember',
  petOwner: 'pet',
  pet: 'petOwner',
  unknown: 'unknown',
}

export function isSymmetric(kind: RelationshipKind): boolean {
  return INVERSE[kind] === kind
}

const KIND_LABELS: Record<RelationshipKind, string> = {
  partner: 'partner',
  parent: 'parent',
  child: 'child',
  auntUncle: 'aunt / uncle',
  nieceNephew: 'niece / nephew',
  sibling: 'sibling',
  friend: 'friend',
  colleague: 'colleague',
  manager: 'manager',
  directReport: 'direct report',
  introducedBy: 'introduced by',
  introduced: 'introduced',
  worksWith: 'works with',
  householdMember: 'household',
  petOwner: 'owner',
  pet: 'pet',
  unknown: 'unknown relationship',
}

export function kindLabel(kind: RelationshipKind): string {
  return KIND_LABELS[kind]
}

/// How the relationship reads on the subject's page — "Maya's son". The label is
/// the user's own word and wins when there is one. This phrase also stands in for
/// the *name* of somebody recorded before their name was known, so it has to read
/// as a description of a person rather than a category.
export function possessivePhrase(subjectName: string, kind: RelationshipKind, label?: string | null): string {
  const word = label?.trim()
  const noun = word && word.length > 0 ? word : KIND_LABELS[kind]
  return `${subjectName}'s ${noun}`
}

/// What a capture form offers to record about somebody in this relationship.
/// Suggestions only — every editor also offers "anything else", and
/// `customAttribute` will make an attribute out of whatever the user types.
export const SUGGESTED_ATTRIBUTES: Record<RelationshipKind, FactAttribute[]> = {
  child: [FactAttributes.observedAge, FactAttributes.schoolGrade, FactAttributes.school, FactAttributes.quickFact],
  nieceNephew: [FactAttributes.observedAge, FactAttributes.schoolGrade, FactAttributes.school, FactAttributes.quickFact],
  partner: [FactAttributes.employer, FactAttributes.quickFact],
  parent: [FactAttributes.employer, FactAttributes.quickFact],
  auntUncle: [FactAttributes.employer, FactAttributes.quickFact],
  sibling: [FactAttributes.employer, FactAttributes.quickFact],
  householdMember: [FactAttributes.employer, FactAttributes.quickFact],
  colleague: [FactAttributes.role, FactAttributes.employer, FactAttributes.quickFact],
  manager: [FactAttributes.role, FactAttributes.employer, FactAttributes.quickFact],
  directReport: [FactAttributes.role, FactAttributes.employer, FactAttributes.quickFact],
  worksWith: [FactAttributes.role, FactAttributes.employer, FactAttributes.quickFact],
  pet: [FactAttributes.observedAge, FactAttributes.quickFact],
  friend: [FactAttributes.location, FactAttributes.quickFact],
  introducedBy: [FactAttributes.location, FactAttributes.quickFact],
  introduced: [FactAttributes.location, FactAttributes.quickFact],
  petOwner: [FactAttributes.location, FactAttributes.quickFact],
  unknown: [FactAttributes.location, FactAttributes.employer, FactAttributes.quickFact],
}

/// A gendered word for a relationship, when the user supplied one. The app never
/// infers gender — not from a name, not from anything. This exists only so that a
/// user who typed "Maya's son Jack" gets "son" carried as the label rather than
/// flattened to "child".
export function genderedKind(word: string): RelationshipKind | null {
  switch (word.toLowerCase()) {
    case 'son':
    case 'daughter':
    case 'kid':
    case 'child':
      return 'child'
    case 'niece':
    case 'nephew':
    case 'nibling':
      return 'nieceNephew'
    case 'aunt':
    case 'uncle':
    case 'pibling':
      return 'auntUncle'
    case 'mother':
    case 'father':
    case 'mum':
    case 'mom':
    case 'dad':
    case 'parent':
      return 'parent'
    case 'brother':
    case 'sister':
    case 'sibling':
      return 'sibling'
    case 'husband':
    case 'wife':
    case 'spouse':
    case 'partner':
    case 'boyfriend':
    case 'girlfriend':
      return 'partner'
    case 'boss':
    case 'manager':
      return 'manager'
    case 'report':
    case 'reports':
      return 'directReport'
    case 'colleague':
    case 'coworker':
    case 'co-worker':
    case 'teammate':
      return 'colleague'
    case 'friend':
      return 'friend'
    case 'dog':
    case 'cat':
    case 'pet':
      return 'pet'
    case 'roommate':
    case 'housemate':
    case 'flatmate':
      return 'householdMember'
    default:
      return null
  }
}

// MARK: Grouping

export const RELATIONSHIP_GROUPS = ['family', 'household', 'work', 'other'] as const
export type RelationshipGroup = (typeof RELATIONSHIP_GROUPS)[number]

export const GROUP_TITLES: Record<RelationshipGroup, string> = {
  family: 'Family',
  household: 'Household',
  work: 'Work',
  other: 'Introduction & friends',
}

/// Which group a relationship is shown under. Every group is a category rather
/// than an exception; no group is defined by what it is not.
export function groupOf(kind: RelationshipKind): RelationshipGroup {
  switch (kind) {
    case 'partner':
    case 'parent':
    case 'child':
    case 'auntUncle':
    case 'nieceNephew':
    case 'sibling':
      return 'family'
    case 'householdMember':
    case 'petOwner':
    case 'pet':
      return 'household'
    case 'colleague':
    case 'manager':
    case 'directReport':
    case 'worksWith':
      return 'work'
    case 'friend':
    case 'introducedBy':
    case 'introduced':
    case 'unknown':
      return 'other'
  }
}

// MARK: The pair

/// Both halves of a relationship, built together so they cannot disagree.
///
/// Invariants: the forward row carries the user's word and the backward row never
/// does; the two rows cross-reference each other by ID; both share one creation
/// instant; and a person cannot be related to themselves.
export function relationshipPair(args: {
  subjectID: string
  otherID: string
  kind: RelationshipKind
  customLabel?: string | null
  now: Date
}): [Relationship, Relationship] {
  const { subjectID, otherID, kind, now } = args
  if (subjectID === otherID) {
    throw new Error('A person cannot be related to themselves.')
  }

  const forwardID = newID()
  const backwardID = newID()
  const label = args.customLabel?.trim()

  const forward: Relationship = {
    id: forwardID,
    subjectID,
    otherID,
    kind,
    customLabel: label && label.length > 0 ? label : null,
    reciprocalID: backwardID,
    createdAt: now,
  }
  const backward: Relationship = {
    id: backwardID,
    subjectID: otherID,
    otherID: subjectID,
    kind: INVERSE[kind],
    customLabel: null,
    reciprocalID: forwardID,
    createdAt: now,
  }
  return [forward, backward]
}
