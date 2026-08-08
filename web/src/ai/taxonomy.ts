import { httpsCallable } from 'firebase/functions'
import { functions } from '../data/firebase'

export interface TaxonomyGap {
  field: 'relationship.kind'
  value: string
}

export interface TaxonomyGapSummary extends TaxonomyGap {
  id: string
  count: number
  firstSeenAt: string
  lastSeenAt: string
}

function taxonomyShaped(gap: TaxonomyGap): TaxonomyGap | null {
  const value = gap.value.normalize('NFKC').trim().toLowerCase()
  if (!/^[a-z][a-z -]*$/.test(value) || value.length > 32 || value.split(/\s+/).length > 3) return null
  return { field: gap.field, value }
}

/// Best-effort and deliberately non-blocking: telemetry must never turn a
/// successful capture back into an error. The callable repeats validation.
export async function reportAiTaxonomyGaps(gaps: TaxonomyGap[]): Promise<void> {
  const safe = gaps.map(taxonomyShaped).filter((gap): gap is TaxonomyGap => gap !== null)
  if (!safe.length) return
  try {
    await httpsCallable<{ gaps: TaxonomyGap[] }, { accepted: number }>(functions, 'reportAiTaxonomyGaps')({ gaps: safe })
  } catch {
    // Reporting is diagnostic only. The editable proposal remains authoritative.
  }
}

export async function listAiTaxonomyGaps(): Promise<TaxonomyGapSummary[]> {
  const response = await httpsCallable<Record<string, never>, { gaps: TaxonomyGapSummary[] }>(
    functions,
    'listAiTaxonomyGaps',
  )({})
  return response.data.gaps
}

export function taxonomyListErrorMessage(error: unknown): string {
  const code = typeof (error as { code?: unknown } | null)?.code === 'string'
    ? (error as { code: string }).code
    : ''
  if (code === 'functions/permission-denied' || code === 'permission-denied') {
    return 'This account is signed in, but its developer access was rejected. Refresh sign-in and try again.'
  }
  if (code === 'functions/not-found' || code === 'not-found') {
    return 'This server build does not include taxonomy reports. Restart the Functions server from this worktree.'
  }
  return 'Could not load taxonomy reports. Check the Functions server and try again.'
}
