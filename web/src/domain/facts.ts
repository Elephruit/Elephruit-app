/// Facts about people, ported from the Mac app's `PersonObservation.swift`.
///
/// The rules that must survive the port, in one place:
/// - A fact is an append-only dated observation, never an overwritten field.
/// - The current answer is *derived* at read time — newest current observation wins
///   per single-valued attribute — rather than trusted from the supersede chain.
/// - An attribute is an open string with a curated registry, and anything typed folds
///   back into the curated set when it matches ("School" gives the School card).
/// - Stored confidence is never rewritten; only the displayed confidence decays.

import { startOfDay, wholeDaysBetween } from './dates'

export type FactAttribute = string

export type FactConfidence = 'stated' | 'inferred' | 'uncertain'
export type FactSensitivity = 'normal' | 'sensitive' | 'restricted'
export type FactContext = 'professional' | 'personal' | 'identity'

export interface Observation {
  id: string
  subjectID: string
  attribute: FactAttribute
  /// What was said, verbatim where possible. Never re-worded by the app.
  value: string
  /// When the observation was made — the date the user heard it, not typed it.
  observedOn: Date
  /// When the value became or becomes true, when that differs from observedOn.
  effectiveOn: Date | null
  /// The last time this was checked and still held. Starts equal to observedOn.
  lastConfirmedOn: Date
  confidence: FactConfidence
  sensitivity: FactSensitivity
  /// Where a custom fact belongs on the working board. Older observations
  /// omit this and continue to use the curated attribute grouping.
  context?: FactContext
  /// The interaction this came out of. A fact that has a source must never lose it.
  sourceInteractionID: string | null
  /// The imported document this came out of, when it came out of one.
  /// Optional and backward compatible; observations predating dossiers lack it.
  sourceDocumentID?: string | null
  /// The observation this one replaces — the chain that makes correction non-destructive.
  supersedesID: string | null
  supersededOn: Date | null
  /// Free text added when correcting — "I misheard this". Lives on the superseded row.
  correctionNote: string | null
  createdAt: Date
}

// MARK: Attributes

export const FactAttributes = {
  // Identity and contact
  preferredName: 'preferredName',
  pronouns: 'pronouns',
  email: 'email',
  phone: 'phone',
  timeZone: 'timeZone',
  language: 'language',
  birthday: 'birthday',
  anniversary: 'anniversary',
  contactCadence: 'contactCadence',
  // Life context
  location: 'location',
  employer: 'employer',
  role: 'role',
  lifeEvent: 'lifeEvent',
  health: 'health',
  // Preferences
  like: 'like',
  dislike: 'dislike',
  giftIdea: 'giftIdea',
  communicationPreference: 'communicationPreference',
  foodAndDrink: 'foodAndDrink',
  family: 'family',
  interest: 'interest',
  conversationTopic: 'conversationTopic',
  quickFact: 'quickFact',
  // Derived-from-dated-observation
  observedAge: 'observedAge',
  schoolGrade: 'schoolGrade',
  school: 'school',
  lookingFor: 'lookingFor',
  significance: 'significance',
  reflection: 'reflection',
  promise: 'promise',
  currentProject: 'currentProject',
  professionalGoal: 'professionalGoal',
  painPoint: 'painPoint',
  decisionRole: 'decisionRole',
  stakeholder: 'stakeholder',
} as const

/// Every attribute the interface offers a dedicated card for, in display order.
/// `health` is a known attribute but deliberately not curated — same as the Mac app.
export const CURATED_ATTRIBUTES: FactAttribute[] = [
  FactAttributes.significance,
  FactAttributes.preferredName,
  FactAttributes.pronouns,
  FactAttributes.email,
  FactAttributes.phone,
  FactAttributes.timeZone,
  FactAttributes.language,
  FactAttributes.birthday,
  FactAttributes.anniversary,
  FactAttributes.contactCadence,
  FactAttributes.conversationTopic,
  FactAttributes.family,
  FactAttributes.observedAge,
  FactAttributes.schoolGrade,
  FactAttributes.school,
  FactAttributes.foodAndDrink,
  FactAttributes.interest,
  FactAttributes.like,
  FactAttributes.dislike,
  FactAttributes.lifeEvent,
  FactAttributes.location,
  FactAttributes.employer,
  FactAttributes.role,
  FactAttributes.currentProject,
  FactAttributes.professionalGoal,
  FactAttributes.painPoint,
  FactAttributes.decisionRole,
  FactAttributes.stakeholder,
  FactAttributes.giftIdea,
  FactAttributes.communicationPreference,
  FactAttributes.lookingFor,
  FactAttributes.quickFact,
  FactAttributes.promise,
  FactAttributes.reflection,
]

const ATTRIBUTE_LABELS: Record<string, string> = {
  preferredName: 'Goes by',
  pronouns: 'Pronouns',
  email: 'Email',
  phone: 'Phone',
  timeZone: 'Time zone',
  language: 'Languages',
  birthday: 'Birthday',
  anniversary: 'Anniversary',
  contactCadence: 'Keep in touch',
  location: 'Lives in',
  employer: 'Works at',
  role: 'Role',
  lifeEvent: 'Life context',
  health: 'Health',
  like: 'Likes',
  dislike: 'Avoid',
  giftIdea: 'Gift ideas',
  communicationPreference: 'How to reach them',
  foodAndDrink: 'Food & drink',
  family: 'Family',
  interest: 'Interests',
  conversationTopic: 'Ask about',
  quickFact: 'Good to know',
  observedAge: 'Age',
  schoolGrade: 'Grade',
  school: 'School',
  lookingFor: 'Looking for',
  significance: 'Why they matter',
  reflection: 'Private notes',
  promise: 'Reminders',
  currentProject: 'Current projects',
  professionalGoal: 'Professional goals',
  painPoint: 'Challenges',
  decisionRole: 'Decision role',
  stakeholder: 'Key stakeholders',
}

export function attributeLabel(attribute: FactAttribute): string {
  const known = ATTRIBUTE_LABELS[attribute]
  if (known) return known
  // Mirrors Swift's `rawValue.capitalized` fallback: each word capitalised.
  return attribute.replace(/(^|\s)\S/g, (c) => c.toUpperCase())
}

/// Whether more than one value can be true at once. Someone lives in exactly one
/// place and likes many things — the difference between superseding and joining.
const SINGLE_VALUED = new Set<FactAttribute>([
  FactAttributes.preferredName,
  FactAttributes.pronouns,
  FactAttributes.email,
  FactAttributes.phone,
  FactAttributes.timeZone,
  FactAttributes.birthday,
  FactAttributes.anniversary,
  FactAttributes.contactCadence,
  FactAttributes.location,
  FactAttributes.employer,
  FactAttributes.role,
  FactAttributes.observedAge,
  FactAttributes.schoolGrade,
  FactAttributes.school,
  FactAttributes.significance,
  FactAttributes.decisionRole,
])

export function isMultiValued(attribute: FactAttribute): boolean {
  return !SINGLE_VALUED.has(attribute)
}

/// Never included in an export, whatever a share profile says.
export function isAlwaysPrivate(attribute: FactAttribute): boolean {
  return attribute === FactAttributes.reflection
}

export function isCurated(attribute: FactAttribute): boolean {
  return CURATED_ATTRIBUTES.includes(attribute)
}

// MARK: Capture

export type CaptureKind = 'text' | 'wholeNumber' | 'schoolGrade'

export function captureKind(attribute: FactAttribute): CaptureKind {
  if (attribute === FactAttributes.observedAge) return 'wholeNumber'
  if (attribute === FactAttributes.schoolGrade) return 'schoolGrade'
  return 'text'
}

const CAPTURE_PROMPTS: Record<string, string> = {
  preferredName: 'What they prefer to be called',
  pronouns: 'Their pronouns',
  email: 'Email address',
  phone: 'Phone number',
  timeZone: 'Their time zone',
  language: 'Languages they speak',
  birthday: 'Birthday — month and day is enough',
  anniversary: 'Anniversary or meaningful date',
  contactCadence: 'How often you want to stay in touch',
  observedAge: 'Age now',
  schoolGrade: 'Grade — “8th”, “senior”',
  school: 'Which school',
  employer: 'Where they work',
  role: 'What they do',
  location: 'Where they live',
  quickFact: 'Worth remembering',
  foodAndDrink: 'Diet, allergies, what they drink',
  interest: 'What they are into',
  conversationTopic: 'Worth asking about',
  currentProject: 'What they are working on',
  professionalGoal: 'What they are trying to achieve',
  painPoint: 'What is getting in their way',
  decisionRole: 'How they influence the decision',
  stakeholder: 'Who else matters to their work',
}

export function capturePrompt(attribute: FactAttribute): string {
  return CAPTURE_PROMPTS[attribute] ?? attributeLabel(attribute)
}

/// An attribute made from something the user typed.
///
/// Normalised to lower case with the spacing collapsed, then folded back into the
/// curated set when it matches a curated attribute's raw value or display label —
/// typing "School" must give the School card, not a second card beside it that
/// neither supersedes nor merges. Returns null for nothing at all.
export function customAttribute(text: string): FactAttribute | null {
  const words = text.toLowerCase().split(/\s+/).filter(Boolean)
  if (words.length === 0) return null

  const normalised = words.join(' ')
  const existing = CURATED_ATTRIBUTES.find(
    (a) => attributeLabel(a).toLowerCase() === normalised || a.toLowerCase() === normalised,
  )
  return existing ?? normalised
}

// MARK: Confidence and sensitivity

export const CONFIDENCE_LABELS: Record<FactConfidence, string> = {
  stated: 'Confirmed',
  inferred: 'Estimated',
  uncertain: 'Unconfirmed',
}

/// Whether the interface must label this rather than presenting it as plain fact.
/// An estimate that looks like a fact is worse than no estimate.
export function confidenceNeedsLabel(confidence: FactConfidence): boolean {
  return confidence !== 'stated'
}

export const SENSITIVITY_LABELS: Record<FactSensitivity, string> = {
  normal: 'Normal',
  sensitive: 'Sensitive',
  restricted: 'Private',
}

/// Whether a fact at this level may ever leave the app.
export function isExportable(sensitivity: FactSensitivity): boolean {
  return sensitivity === 'normal'
}

// MARK: Staleness

/// How long a fact of each kind is believed without rechecking, in days.
/// Absent means "does not go stale". `observedAge` and `schoolGrade` are deliberately
/// absent: they are estimator inputs, not claims to nag about.
export const SHELF_LIFE_DAYS: Record<string, number> = {
  location: 730,
  employer: 548,
  role: 548,
  lifeEvent: 180,
  health: 180,
  lookingFor: 120,
  school: 1095,
}

export function isCurrent(o: Observation): boolean {
  return o.supersededOn === null
}

export function daysSinceConfirmed(o: Observation, asOf: Date): number {
  return Math.max(0, wholeDaysBetween(startOfDay(o.lastConfirmedOn), asOf))
}

export function isStale(o: Observation, asOf: Date): boolean {
  const shelfLife = SHELF_LIFE_DAYS[o.attribute]
  if (shelfLife === undefined) return false
  return daysSinceConfirmed(o, asOf) > shelfLife
}

/// The confidence to *display*, which decays even though the record does not.
/// The stored confidence is never rewritten — that would destroy the distinction
/// between "they told me this" and "they told me this a long time ago".
export function effectiveConfidence(o: Observation, asOf: Date): FactConfidence {
  return isStale(o, asOf) ? 'uncertain' : o.confidence
}

// MARK: The ledger

/// The current values for one attribute, newest first.
///
/// For a single-valued attribute this is at most one entry: the newest current
/// observation wins and the rest are history, whether or not anyone remembered to
/// mark them superseded. Deriving that rather than trusting the supersedesID chain
/// means an import or merge that leaves two unsuperseded "lives in" rows still
/// produces one right answer.
export function currentValues(observations: Observation[], attribute: FactAttribute): Observation[] {
  const live = observations
    .filter((o) => o.attribute === attribute && isCurrent(o))
    .sort((a, b) => b.observedOn.getTime() - a.observedOn.getTime())
  return isMultiValued(attribute) ? live : live.slice(0, 1)
}

/// Superseded observations for one attribute, newest first — the "was" list.
export function history(observations: Observation[], attribute: FactAttribute): Observation[] {
  const current = new Set(currentValues(observations, attribute).map((o) => o.id))
  return observations
    .filter((o) => o.attribute === attribute && !current.has(o.id))
    .sort((a, b) => b.observedOn.getTime() - a.observedOn.getTime())
}

/// Every attribute this person has anything current recorded for, curated order
/// first, then the rest alphabetically.
export function populatedAttributes(observations: Observation[]): FactAttribute[] {
  const present = new Set(observations.filter(isCurrent).map((o) => o.attribute))
  const curated = CURATED_ATTRIBUTES.filter((a) => present.has(a))
  const rest = [...present].filter((a) => !curated.includes(a)).sort()
  return [...curated, ...rest]
}

/// Facts the app has stopped vouching for, oldest-confirmed first. Surfaced so the
/// user can confirm or correct them — never acted on, never quietly hidden.
export function staleObservations(observations: Observation[], asOf: Date): Observation[] {
  return observations
    .filter((o) => isCurrent(o) && isStale(o, asOf))
    .sort((a, b) => a.lastConfirmedOn.getTime() - b.lastConfirmedOn.getTime())
}

/// The single current value of an attribute, if it has one.
export function valueOf(observations: Observation[], attribute: FactAttribute): string | null {
  return currentValues(observations, attribute)[0]?.value ?? null
}
