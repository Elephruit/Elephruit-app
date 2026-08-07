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
