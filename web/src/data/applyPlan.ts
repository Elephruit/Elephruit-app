/// The only write path. Every capture surface builds a WritePlan in the domain
/// layer and hands it here; it commits as one atomic batch or not at all. If a
/// second way of writing ever appears, that is a bug, not a convenience.

import { writeBatch } from 'firebase/firestore'
import { assertPlanFits, type WritePlan } from '../domain/writePlan'
import { docRef } from './collections'
import { serialize } from './converters'
import { db } from './firebase'

export async function applyPlan(uid: string, plan: WritePlan): Promise<void> {
  assertPlanFits(plan)

  const batch = writeBatch(db)
  for (const write of plan) {
    const ref = docRef(uid, write.collection, write.id)
    switch (write.op) {
      case 'set':
        batch.set(ref, serialize(write.data) as Record<string, unknown>)
        break
      case 'update':
        batch.update(ref, serialize(write.data) as Record<string, unknown>)
        break
      case 'delete':
        batch.delete(ref)
        break
    }
  }
  await batch.commit()
}
