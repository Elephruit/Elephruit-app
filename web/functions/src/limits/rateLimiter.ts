/// Fixed-window rate limiting behind an interface. The Firestore
/// implementation counts in a transaction per (uid, operation, window) —
/// honest about its limits: under a concurrent burst two transactions can
/// both read count=N-1 and retry serially, so the ceiling is approximately
/// enforced, which is what a cost-and-abuse guard needs. If limits ever
/// need to be exact under load, this interface moves to Redis/Memorystore
/// without touching callers.
///
/// Documents live in aiRateLimits/ (denied to all clients by rules) and
/// carry expireAt so a Firestore TTL policy reaps them in production; the
/// emulator ignores TTL, which is harmless.

import type { Firestore } from 'firebase-admin/firestore'

export interface RatePolicy {
  limit: number
  windowSeconds: number
}

export interface RateLimiter {
  /// True when the operation is allowed (and the consumption recorded).
  consume(uid: string, operation: string, policy: RatePolicy): Promise<boolean>
}

export function windowStart(nowMs: number, windowSeconds: number): number {
  return Math.floor(nowMs / 1000 / windowSeconds) * windowSeconds
}

export function counterDocId(uid: string, operation: string, windowStartSeconds: number): string {
  return `c_${uid}_${operation}_${windowStartSeconds}`
}

export class FirestoreRateLimiter implements RateLimiter {
  constructor(
    private readonly db: Firestore,
    private readonly nowMs: () => number = () => Date.now(),
  ) {}

  async consume(uid: string, operation: string, policy: RatePolicy): Promise<boolean> {
    const start = windowStart(this.nowMs(), policy.windowSeconds)
    const ref = this.db.collection('aiRateLimits').doc(counterDocId(uid, operation, start))
    // Records expire well after the window closes; TTL cleanup is cost
    // hygiene, not correctness.
    const expireAt = new Date((start + policy.windowSeconds) * 1000 + 3_600_000)

    return this.db.runTransaction(async (tx) => {
      const snapshot = await tx.get(ref)
      const count = (snapshot.data()?.count as number | undefined) ?? 0
      if (count >= policy.limit) return false
      tx.set(ref, { count: count + 1, windowStart: start, expireAt }, { merge: true })
      return true
    })
  }
}
