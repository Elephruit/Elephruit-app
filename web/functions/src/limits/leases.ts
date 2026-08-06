/// Concurrent-stream leases: one document per user holding its active
/// leases, pruned of expired entries inside the acquiring transaction.
/// Instances die without running finally blocks sometimes — the TTL on each
/// lease (longer than the function timeout) is what makes a crashed stream
/// release its slot instead of pinning it forever.

import type { Firestore } from 'firebase-admin/firestore'

export interface StreamLeases {
  /// True when a slot was acquired. Callers must release(requestId) in a
  /// finally block; expiry covers the crashes that never reach it.
  acquire(uid: string, requestId: string, maxConcurrent: number, ttlSeconds: number): Promise<boolean>
  release(uid: string, requestId: string): Promise<void>
}

export function leaseDocId(uid: string): string {
  return `l_${uid}`
}

export class FirestoreStreamLeases implements StreamLeases {
  constructor(
    private readonly db: Firestore,
    private readonly nowMs: () => number = () => Date.now(),
  ) {}

  private ref(uid: string) {
    return this.db.collection('aiRateLimits').doc(leaseDocId(uid))
  }

  async acquire(uid: string, requestId: string, maxConcurrent: number, ttlSeconds: number): Promise<boolean> {
    const now = this.nowMs()
    const expiresAtMs = now + ttlSeconds * 1000
    return this.db.runTransaction(async (tx) => {
      const snapshot = await tx.get(this.ref(uid))
      const leases = (snapshot.data()?.leases as Record<string, number> | undefined) ?? {}
      const live = Object.fromEntries(Object.entries(leases).filter(([, expiry]) => expiry > now))
      if (Object.keys(live).length >= maxConcurrent) return false
      live[requestId] = expiresAtMs
      const latestExpiry = Math.max(...Object.values(live))
      tx.set(this.ref(uid), { leases: live, expireAt: new Date(latestExpiry + 3_600_000) })
      return true
    })
  }

  async release(uid: string, requestId: string): Promise<void> {
    const now = this.nowMs()
    await this.db.runTransaction(async (tx) => {
      const snapshot = await tx.get(this.ref(uid))
      if (!snapshot.exists) return
      const leases = (snapshot.data()?.leases as Record<string, number> | undefined) ?? {}
      const remaining = Object.fromEntries(
        Object.entries(leases).filter(([id, expiry]) => id !== requestId && expiry > now),
      )
      const latestExpiry = Object.values(remaining).length > 0 ? Math.max(...Object.values(remaining)) : now
      tx.set(this.ref(uid), { leases: remaining, expireAt: new Date(latestExpiry + 3_600_000) })
    })
  }
}
