import { describe, expect, it } from 'vitest'
import type { TaxonomyGap, TaxonomyGapStore, TaxonomyGapSummary } from './store.js'
import { handleListTaxonomyGaps, handleReportTaxonomyGaps } from './handlers.js'

class MemoryStore implements TaxonomyGapStore {
  recorded: TaxonomyGap[] = []
  rows: TaxonomyGapSummary[] = []

  async record(gap: TaxonomyGap): Promise<void> {
    this.recorded.push(gap)
  }

  async list(): Promise<TaxonomyGapSummary[]> {
    return this.rows
  }
}

describe('taxonomy gap handlers', () => {
  it('sanitizes, deduplicates, and bounds taxonomy-only reports', async () => {
    const store = new MemoryStore()
    const result = await handleReportTaxonomyGaps(store, {
      gaps: [
        { field: 'relationship.kind', value: '  Godparent  ' },
        { field: 'relationship.kind', value: 'GODPARENT' },
        { field: 'relationship.kind', value: 'Former colleague!' },
      ],
    })

    expect(result).toEqual({ accepted: 2 })
    expect(store.recorded).toEqual([
      { field: 'relationship.kind', value: 'godparent' },
      { field: 'relationship.kind', value: 'former colleague' },
    ])
  })

  it('rejects fields and payloads outside the reporting contract', async () => {
    const store = new MemoryStore()
    await expect(handleReportTaxonomyGaps(store, {
      gaps: [{ field: 'person.name', value: 'Madeline Brooks' }],
    })).rejects.toThrow('Invalid taxonomy report')
    expect(store.recorded).toEqual([])
  })

  it('returns the store summaries for the admin view', async () => {
    const store = new MemoryStore()
    store.rows = [{
      id: 'gap-1', field: 'relationship.kind', value: 'godparent', count: 3,
      firstSeenAt: '2026-08-01T00:00:00.000Z', lastSeenAt: '2026-08-07T00:00:00.000Z',
    }]
    await expect(handleListTaxonomyGaps(store)).resolves.toEqual({ gaps: store.rows })
  })
})
