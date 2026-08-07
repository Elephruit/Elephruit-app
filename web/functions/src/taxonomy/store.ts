import { createHash } from 'node:crypto'
import { FieldValue, type Firestore, type Timestamp } from 'firebase-admin/firestore'

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

export interface TaxonomyGapStore {
  record(gap: TaxonomyGap): Promise<void>
  list(limit: number): Promise<TaxonomyGapSummary[]>
}

function documentID(gap: TaxonomyGap): string {
  return createHash('sha256').update(`${gap.field}\0${gap.value}`).digest('hex').slice(0, 32)
}

function iso(value: unknown): string {
  return (value as Timestamp | undefined)?.toDate?.().toISOString() ?? new Date(0).toISOString()
}

export class FirestoreTaxonomyGapStore implements TaxonomyGapStore {
  constructor(private readonly db: Firestore) {}

  async record(gap: TaxonomyGap): Promise<void> {
    const ref = this.db.collection('aiTaxonomyGaps').doc(documentID(gap))
    await this.db.runTransaction(async (transaction) => {
      const snapshot = await transaction.get(ref)
      if (snapshot.exists) {
        transaction.update(ref, { count: FieldValue.increment(1), lastSeenAt: FieldValue.serverTimestamp() })
      } else {
        transaction.create(ref, {
          field: gap.field,
          value: gap.value,
          count: 1,
          firstSeenAt: FieldValue.serverTimestamp(),
          lastSeenAt: FieldValue.serverTimestamp(),
        })
      }
    })
  }

  async list(maximum: number): Promise<TaxonomyGapSummary[]> {
    const snapshot = await this.db.collection('aiTaxonomyGaps').orderBy('lastSeenAt', 'desc').limit(maximum).get()
    return snapshot.docs.map((document) => {
      const data = document.data()
      return {
        id: document.id,
        field: data.field as TaxonomyGap['field'],
        value: String(data.value ?? ''),
        count: Number(data.count ?? 0),
        firstSeenAt: iso(data.firstSeenAt),
        lastSeenAt: iso(data.lastSeenAt),
      }
    })
  }
}
