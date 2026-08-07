/// The domain speaks Date and null; Firestore speaks Timestamp and rejects
/// undefined outright. These two deep converters are the entire boundary — no
/// domain type knows it is stored, and no component ever sees a Timestamp.

import { Timestamp } from 'firebase/firestore'

/// Domain value → Firestore data. Dates become Timestamps; undefined becomes
/// null so an optional field is stored explicitly rather than throwing.
export function serialize(value: unknown): unknown {
  if (value === undefined || value === null) return null
  if (value instanceof Date) return Timestamp.fromDate(value)
  if (Array.isArray(value)) return value.map(serialize)
  if (typeof value === 'object' && value.constructor === Object) {
    const out: Record<string, unknown> = {}
    for (const [key, entry] of Object.entries(value)) {
      out[key] = serialize(entry)
    }
    return out
  }
  return value
}

/// Firestore data → domain value. Timestamps become Dates.
export function deserialize(value: unknown): unknown {
  if (value === null || value === undefined) return null
  if (value instanceof Timestamp) return value.toDate()
  if (Array.isArray(value)) return value.map(deserialize)
  if (typeof value === 'object' && value.constructor === Object) {
    const out: Record<string, unknown> = {}
    for (const [key, entry] of Object.entries(value)) {
      out[key] = deserialize(entry)
    }
    return out
  }
  return value
}
