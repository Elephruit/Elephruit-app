/// A recorded exchange with one or more people, ported from the Mac app's
/// interaction model. There, kind rode on a namespaced tag and provenance on a
/// shared column; here they are real fields — but the semantics are unchanged,
/// most importantly the three-way provenance and the rule that only a *logged*
/// interaction counts as contact.

export const INTERACTION_KINDS = ['in-person', 'phone', 'video', 'message', 'email', 'other'] as const
export type InteractionKind = (typeof INTERACTION_KINDS)[number]

export const INTERACTION_KIND_LABELS: Record<InteractionKind, string> = {
  'in-person': 'In person',
  phone: 'Phone',
  video: 'Video',
  message: 'Message',
  email: 'Email',
  other: 'Other',
}

/// How the app came to know about an interaction. The app can see that a button
/// was pressed; it cannot see whether anyone answered. Recording "spoke to Maya"
/// on the strength of a button press would put a fact in the timeline nobody
/// stated. The spike only ever writes `logged`; the enum stays whole so the other
/// two arrive later without a migration.
export type InteractionProvenance = 'logged' | 'initiated' | 'detected'

export const PROVENANCE_LABELS: Record<InteractionProvenance, string> = {
  logged: 'Logged',
  initiated: 'Started',
  detected: 'From your calendar',
}

/// Whether this counts as "we actually spoke" for the last-contact line. Only a
/// logged interaction does — pressing Call and getting voicemail is not contact,
/// and letting it count would make the one number this app is trusted for wrong.
export function countsAsContact(provenance: InteractionProvenance): boolean {
  return provenance === 'logged'
}

export interface Interaction {
  id: string
  kind: InteractionKind
  provenance: InteractionProvenance
  /// One line saying what happened. Required, trimmed.
  summary: string
  /// The longer account, when there is one.
  discussion: string | null
  /// Everyone involved besides the user, deduped, order preserved. The user is
  /// implicit and never listed.
  participantIDs: string[]
  /// When it happened — not when it was typed.
  occurredAt: Date
  createdAt: Date
}

/// The phrase a timeline row opens with — "phone — logged", "started",
/// "detected from your calendar". Ported from InteractionProvenance.phrase.
export function provenancePhrase(provenance: InteractionProvenance, kind: InteractionKind | null): string {
  switch (provenance) {
    case 'logged':
      return kind ? `${INTERACTION_KIND_LABELS[kind].toLowerCase()} — logged` : 'logged'
    case 'initiated':
      return kind ? `${INTERACTION_KIND_LABELS[kind].toLowerCase()} started from Elephruit` : 'started'
    case 'detected':
      return 'detected from your calendar'
  }
}
