/// The one shape every capture path produces. Domain code plans writes; exactly
/// one place (src/data/applyPlan.ts) executes a plan, always as a single atomic
/// batch. That mirrors the Mac app's rule that there is one repository method a
/// capture goes through — a platform-specific write path is a review failure.

export const COLLECTIONS = [
  'people',
  'interactions',
  'relationships',
  'observations',
  'reminders',
  /// Projects and folders — the one shape a trip, a house move, or Travel all
  /// take. See src/domain/container.ts.
  'containers',
  /// A note's metadata and its capped plain-text projection.
  'notes',
  /// A note's rich content, under the same id. A sibling rather than a
  /// subcollection — see src/domain/note.ts.
  'noteContents',
  /// Provenance metadata for imported dossiers — never raw file content.
  'sources',
  /// The feed's durable grouping records — one per meaningful save.
  'memories',
] as const
export type CollectionName = (typeof COLLECTIONS)[number]

export type DocWrite =
  | { op: 'set'; collection: CollectionName; id: string; data: unknown }
  | { op: 'update'; collection: CollectionName; id: string; data: Record<string, unknown> }
  | { op: 'delete'; collection: CollectionName; id: string }

export type WritePlan = DocWrite[]

/// Firestore batches cap at 500 operations. No plan this app builds comes close,
/// but a silent partial write would be worse than a loud refusal.
export const MAX_PLAN_LENGTH = 500

export function assertPlanFits(plan: WritePlan): void {
  if (plan.length === 0) {
    throw new Error('Refusing to apply an empty write plan.')
  }
  if (plan.length > MAX_PLAN_LENGTH) {
    throw new Error(`Write plan has ${plan.length} operations; the batch limit is ${MAX_PLAN_LENGTH}.`)
  }
}
