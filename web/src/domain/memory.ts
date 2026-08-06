/// The feed's durable contract: every meaningful save creates exactly one
/// MemoryRecord — a lightweight grouping-and-provenance record naming the
/// entities written together — so a capture that produced facts, a
/// relationship, and a follow-up but no conversation is still one visible
/// moment. Kind names what it was (a conversation, a profile update, an
/// import); the record never duplicates entity content and never carries
/// attachment bytes. Dates are real Dates like everywhere else in the domain;
/// the converters own the Timestamp boundary.

import { newID } from './ids'
import type { Person } from './person'
import type { WritePlan } from './writePlan'

export type MemoryKind = 'interaction' | 'profileUpdate' | 'dossierImport' | 'manualUpdate'

export type MemoryOrigin =
  | 'capture'
  | 'manualInteraction'
  | 'manualFact'
  | 'manualRelationship'
  | 'manualReminder'
  | 'dossier'

export interface MemoryRecord {
  id: string
  kind: MemoryKind
  title: string
  /// The interaction's occurredAt when one exists; otherwise the save time.
  occurredAt: Date
  createdAt: Date
  personIDs: string[]
  interactionID: string | null
  observationIDs: string[]
  relationshipIDs: string[]
  reminderIDs: string[]
  sourceDocumentIDs: string[]
  origin: MemoryOrigin
}

export interface MemoryDraft {
  kind: MemoryKind
  title: string
  occurredAt: Date
  personIDs: string[]
  interactionID?: string | null
  observationIDs?: string[]
  relationshipIDs?: string[]
  reminderIDs?: string[]
  sourceDocumentIDs?: string[]
  origin: MemoryOrigin
}

export function makeMemoryRecord(draft: MemoryDraft, now: Date): MemoryRecord {
  return {
    id: newID(),
    kind: draft.kind,
    title: draft.title.trim() || 'Memory',
    occurredAt: draft.occurredAt,
    createdAt: now,
    personIDs: [...new Set(draft.personIDs)],
    interactionID: draft.interactionID ?? null,
    observationIDs: draft.observationIDs ?? [],
    relationshipIDs: draft.relationshipIDs ?? [],
    reminderIDs: draft.reminderIDs ?? [],
    sourceDocumentIDs: draft.sourceDocumentIDs ?? [],
    origin: draft.origin,
  }
}

export function planMemoryRecord(draft: MemoryDraft, now: Date): { plan: WritePlan; memory: MemoryRecord } {
  const memory = makeMemoryRecord(draft, now)
  return { plan: [{ op: 'set', collection: 'memories', id: memory.id, data: memory }], memory }
}

/// The provenance label a moment shows — never mislabeling a non-conversation
/// as one.
export const MEMORY_KIND_LABELS: Record<MemoryKind, string> = {
  interaction: 'Conversation',
  profileUpdate: 'Profile update',
  dossierImport: 'Dossier import',
  manualUpdate: 'Manual update',
}

/// The deterministic default title, chosen when the review draft is created
/// and editable by the user before save. Precedence per the polish plan.
export function defaultMemoryTitle(args: {
  interactionSummary: string | null
  dossierFileCount?: number
  primaryPerson?: Pick<Person, 'displayName'> | null
  createdPeople: Array<Pick<Person, 'displayName'>>
  connectedPair?: [Pick<Person, 'displayName'>, Pick<Person, 'displayName'>] | null
  hasFacts: boolean
  hasRelationships: boolean
  followUpOnly?: boolean
}): string {
  if (args.interactionSummary?.trim()) return args.interactionSummary.trim()
  if (args.dossierFileCount && args.primaryPerson) {
    return `Built out ${args.primaryPerson.displayName} from ${args.dossierFileCount} file${args.dossierFileCount === 1 ? '' : 's'}`
  }
  if (args.createdPeople.length === 1 && !args.hasRelationships) {
    return `Added ${args.createdPeople[0].displayName}`
  }
  if (args.connectedPair && !args.hasFacts && !args.followUpOnly) {
    return `Connected ${args.connectedPair[0].displayName} and ${args.connectedPair[1].displayName}`
  }
  if (args.followUpOnly && args.primaryPerson) {
    return `Added a follow-up for ${args.primaryPerson.displayName}`
  }
  if (args.primaryPerson) return `Updated ${args.primaryPerson.displayName}`
  if (args.createdPeople.length > 0) return `Added ${args.createdPeople[0].displayName}`
  return 'Memory'
}
