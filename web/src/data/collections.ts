import { collection, doc, type CollectionReference, type DocumentReference } from 'firebase/firestore'
import type { CollectionName } from '../domain/writePlan'
import { db } from './firebase'

/// Every document lives under users/{uid}/<collection>/<id> — the shape the
/// security rules mirror with a single match block.
export function collectionRef(uid: string, name: CollectionName): CollectionReference {
  return collection(db, 'users', uid, name)
}

export function docRef(uid: string, name: CollectionName, id: string): DocumentReference {
  return doc(db, 'users', uid, name, id)
}
