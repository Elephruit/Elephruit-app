import { z } from 'zod'
import { PublicError } from '../log/errors.js'
import type { TaxonomyGap, TaxonomyGapStore, TaxonomyGapSummary } from './store.js'

const ReportSchema = z.object({
  gaps: z.array(z.object({
    field: z.literal('relationship.kind'),
    value: z.string().min(1).max(80),
  })).max(10),
})

/// Values resolved by a newer relationship taxonomy. Older clients may have
/// reported them before the new persisted kinds shipped; keep those historical
/// rows out of the unresolved admin queue and refuse to increment them again.
const RESOLVED_RELATIONSHIP_VALUES = new Set([
  'niece',
  'nephew',
  'nibling',
  'niece and nephew',
  'aunt',
  'uncle',
  'pibling',
  'aunt and uncle',
])

function sanitizedValue(value: string): string {
  return value
    .normalize('NFKC')
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9 -]/g, '')
    .replace(/\s+/g, ' ')
    .slice(0, 32)
}

export async function handleReportTaxonomyGaps(
  store: TaxonomyGapStore,
  input: unknown,
): Promise<{ accepted: number }> {
  const parsed = ReportSchema.safeParse(input)
  if (!parsed.success) throw new PublicError('INVALID_REQUEST', 'Invalid taxonomy report.')

  const unique = new Map<string, TaxonomyGap>()
  for (const gap of parsed.data.gaps) {
    const value = sanitizedValue(gap.value)
    if (!value || value.split(/\s+/).length > 3 || RESOLVED_RELATIONSHIP_VALUES.has(value)) continue
    const normalized = { field: gap.field, value } satisfies TaxonomyGap
    unique.set(`${normalized.field}:${normalized.value}`, normalized)
  }
  await Promise.all([...unique.values()].map((gap) => store.record(gap)))
  return { accepted: unique.size }
}

export async function handleListTaxonomyGaps(
  store: TaxonomyGapStore,
): Promise<{ gaps: TaxonomyGapSummary[] }> {
  const gaps = await store.list(100)
  return { gaps: gaps.filter((gap) => !RESOLVED_RELATIONSHIP_VALUES.has(sanitizedValue(gap.value))) }
}
