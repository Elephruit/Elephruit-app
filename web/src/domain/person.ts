/// A person record. Deliberately light next to the Mac app's PersonProfile —
/// the spike records who somebody is and what happens with them, not their
/// address book entry. Two flags carry real weight:
///
/// - `isPlaceholder`: created only so somebody could be mentioned.
/// - `hasStatedName`: false means displayName is a *phrase* standing in for a
///   name ("Ana's son"), and the record belongs in the to-fill-in queue.

export const PALETTE_COLORS = [
  'red',
  'orange',
  'yellow',
  'green',
  'mint',
  'teal',
  'cyan',
  'blue',
  'indigo',
  'purple',
  'pink',
  'brown',
  'graphite',
] as const

export type PaletteColor = (typeof PALETTE_COLORS)[number]

export type ProfileFocus = 'professional' | 'personal'

export type ConnectionOriginStatus = 'met' | 'introductionPlanned' | 'unknown'

/// How this person entered the user's life. This is deliberately separate from
/// relationships between people: “introduced by Harbinder” is both a network
/// edge and part of the user's own history with Kelly.
export interface ConnectionOrigin {
  status: ConnectionOriginStatus
  firstMetOn: Date | null
  context: string | null
  introducedByPersonID: string | null
}

export interface Person {
  id: string
  displayName: string
  givenName: string | null
  familyName: string | null
  roleTitle: string | null
  organizationName: string | null
  /// Controls presentation emphasis, never which facts a person may have.
  /// Optional so records created before the working-board redesign load cleanly.
  profileFocus?: ProfileFocus
  connectionOrigin?: ConnectionOrigin | null
  colorName: PaletteColor
  isPlaceholder: boolean
  hasStatedName: boolean
  createdAt: Date
  /// A named cache of deriveLastContact() over this person's interactions,
  /// maintained only inside the same batch that logs an interaction. The person
  /// page shows the derived value; lists may lean on this.
  lastContactAt: Date | null
  /// Optional, backward compatible: unnamed-duplicate comparisons the user
  /// marked "They are different", keyed order-independently by the pair.
  dismissedComparisonKeys?: string[]
}

export function profileFocusOf(person: Person): ProfileFocus {
  return person.profileFocus ?? (person.roleTitle || person.organizationName ? 'professional' : 'personal')
}

/// The monogram for an avatar: first letters of the first two words.
export function initials(name: string): string {
  return name
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((word) => word[0].toUpperCase())
    .join('')
}

/// A naive first/rest split, used only when naming a previously unnamed person —
/// which is exactly when a naive split is safe, because there is nothing to preserve.
export function nameParts(fullName: string): { givenName: string | null; familyName: string | null } {
  const words = fullName.trim().split(/\s+/).filter(Boolean)
  if (words.length === 0) return { givenName: null, familyName: null }
  if (words.length === 1) return { givenName: words[0], familyName: null }
  return { givenName: words[0], familyName: words.slice(1).join(' ') }
}

/// A stable colour for a new person, picked from the name so re-creating the
/// same person lands on the same colour rather than a random one.
export function paletteColorFor(name: string): PaletteColor {
  let hash = 0
  for (const char of name) {
    hash = (hash * 31 + char.charCodeAt(0)) >>> 0
  }
  return PALETTE_COLORS[hash % PALETTE_COLORS.length]
}

/// Case- and diacritic-insensitive comparison key, the same folding idea the Mac
/// app's TextNormalizer uses for matching typed names against records.
export function foldedForMatching(text: string): string {
  return text
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .trim()
    .replace(/\s+/g, ' ')
}
