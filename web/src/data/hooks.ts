/// Live subscriptions. onSnapshot is both the cache and the update channel —
/// there is no fetch layer to invalidate, so these hooks stay thin: subscribe,
/// deserialize, hand the domain plain objects with real Dates.

import {
  limit as limitTo,
  onSnapshot,
  orderBy,
  query,
  where,
  type Query,
} from 'firebase/firestore'
import { useEffect, useState } from 'react'
import type { Interaction } from '../domain/interaction'
import type { Observation } from '../domain/facts'
import type { Person } from '../domain/person'
import { foldedForMatching } from '../domain/person'
import type { Relationship } from '../domain/relationships'
import type { Reminder } from '../domain/reminders'
import { collectionRef, docRef } from './collections'
import { deserialize } from './converters'

/// `undefined` means still loading; an empty array means genuinely empty. The
/// distinction keeps empty states from flashing while the first snapshot loads.
function useQuerySnapshot<T>(make: () => Query, deps: unknown[]): T[] | undefined {
  const [rows, setRows] = useState<T[] | undefined>(undefined)

  useEffect(() => {
    setRows(undefined)
    const unsubscribe = onSnapshot(make(), (snapshot) => {
      setRows(
        snapshot.docs.map((docSnapshot) => {
          const data = deserialize(docSnapshot.data()) as T & { id: string }
          data.id = docSnapshot.id
          return data
        }),
      )
    })
    return unsubscribe
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps)

  return rows
}

export function usePeople(uid: string): Person[] | undefined {
  const people = useQuerySnapshot<Person>(() => query(collectionRef(uid, 'people')), [uid])
  return people?.sort((a, b) => foldedForMatching(a.displayName).localeCompare(foldedForMatching(b.displayName)))
}

export function usePerson(uid: string, personID: string): Person | null | undefined {
  const [person, setPerson] = useState<Person | null | undefined>(undefined)

  useEffect(() => {
    setPerson(undefined)
    return onSnapshot(docRef(uid, 'people', personID), (snapshot) => {
      if (!snapshot.exists()) {
        setPerson(null)
        return
      }
      const data = deserialize(snapshot.data()) as Person
      data.id = snapshot.id
      setPerson(data)
    })
  }, [uid, personID])

  return person
}

export function useFeed(uid: string, count = 100): Interaction[] | undefined {
  return useQuerySnapshot<Interaction>(
    () => query(collectionRef(uid, 'interactions'), orderBy('occurredAt', 'desc'), limitTo(count)),
    [uid, count],
  )
}

/// The person-timeline query — the one composite index in firestore.indexes.json.
export function usePersonInteractions(uid: string, personID: string): Interaction[] | undefined {
  return useQuerySnapshot<Interaction>(
    () =>
      query(
        collectionRef(uid, 'interactions'),
        where('participantIDs', 'array-contains', personID),
        orderBy('occurredAt', 'desc'),
      ),
    [uid, personID],
  )
}

export function useObservationsFor(uid: string, personID: string): Observation[] | undefined {
  return useQuerySnapshot<Observation>(
    () => query(collectionRef(uid, 'observations'), where('subjectID', '==', personID)),
    [uid, personID],
  )
}

export function useRelationshipsFor(uid: string, personID: string): Relationship[] | undefined {
  return useQuerySnapshot<Relationship>(
    () => query(collectionRef(uid, 'relationships'), where('subjectID', '==', personID)),
    [uid, personID],
  )
}

export function useAllRelationships(uid: string): Relationship[] | undefined {
  return useQuerySnapshot<Relationship>(() => query(collectionRef(uid, 'relationships')), [uid])
}

/// The whole collection, bucketed client-side — spike scale, and it keeps the
/// index list down to the one the person timeline needs.
export function useReminders(uid: string): Reminder[] | undefined {
  return useQuerySnapshot<Reminder>(() => query(collectionRef(uid, 'reminders')), [uid])
}

export function useRemindersFor(uid: string, personID: string): Reminder[] | undefined {
  return useQuerySnapshot<Reminder>(
    () => query(collectionRef(uid, 'reminders'), where('personIDs', 'array-contains', personID)),
    [uid, personID],
  )
}
