/// Live subscriptions. onSnapshot is both the cache and the update channel —
/// there is no fetch layer to invalidate, so these hooks stay thin: subscribe,
/// deserialize, hand the domain plain objects with real Dates.

import {
  collection,
  limit as limitTo,
  onSnapshot,
  orderBy,
  query,
  where,
  type Query,
} from 'firebase/firestore'
import { useCallback, useEffect, useMemo, useState } from 'react'
import type { AiCredential } from '../ai/credentials'
import { archivedFolderIDs, isSuppressedByArchive, type Folder } from '../domain/folder'
import type { Interaction } from '../domain/interaction'
import type { Observation } from '../domain/facts'
import type { MemoryRecord } from '../domain/memory'
import type { Note } from '../domain/note'
import { parseDocument, type NoteDocument } from '../domain/noteDocument'
import type { Person } from '../domain/person'
import { foldedForMatching } from '../domain/person'
import type { Relationship } from '../domain/relationships'
import type { Reminder } from '../domain/reminders'
import type { SourceDocument } from '../domain/sources'
import { projectFeed, type MemoryMomentViewModel } from './memoryProjection'
import { collectionRef, docRef } from './collections'
import { deserialize } from './converters'
import { db } from './firebase'

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
  return useMemo(
    () =>
      people &&
      [...people].sort((a, b) =>
        foldedForMatching(a.displayName).localeCompare(foldedForMatching(b.displayName)),
      ),
    [people],
  )
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

/// The interactions search reads. Deliberately a bigger window than the feed's
/// 100 and still a window: this is the one collection that grows without bound,
/// and CLIENT_SEARCH_CEILING in domain/search.ts is where the whole approach
/// stops being right.
export function useSearchableInteractions(uid: string, count = 500): Interaction[] | undefined {
  return useFeed(uid, count)
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

/// The whole collection, filtered client-side — same spike-scale posture as
/// useReminders; the day brief reads several people's ledgers at once.
export function useAllObservations(uid: string): Observation[] | undefined {
  return useQuerySnapshot<Observation>(() => query(collectionRef(uid, 'observations')), [uid])
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

/// The reminders a *live* surface should draw: everything except the work of a
/// project or folder that has been archived.
///
/// A hook rather than a filter each page applies, because the rule has to hold
/// everywhere at once. Follow-ups, the Feed's Next up, the open count and the
/// day brief are four surfaces asking the same question, and the fourth one
/// added is the one that would have got it wrong. See `isSuppressedByArchive`
/// for why the reminders' own status is never touched.
///
/// Returns `undefined` until *both* subscriptions have settled. They arrive
/// independently and reminders usually win, so answering early means an
/// archived trip's work flashes into Overdue for a frame.
export function useLiveReminders(uid: string): Reminder[] | undefined {
  const reminders = useReminders(uid)
  const folders = useFolders(uid)

  return useMemo(() => {
    if (!reminders || !folders) return undefined
    const archived = archivedFolderIDs(folders)
    if (archived.size === 0) return reminders
    return reminders.filter((reminder) => !isSuppressedByArchive(reminder, archived))
  }, [reminders, folders])
}

/// The whole tree. Folders are few — a handful of them across a life — so this
/// is the one collection where the spike-scale posture is not a compromise but
/// the right answer.
export function useFolders(uid: string): Folder[] | undefined {
  return useQuerySnapshot<Folder>(() => query(collectionRef(uid, 'folders')), [uid])
}

export function useFolder(uid: string, folderID: string): Folder | null | undefined {
  const [folder, setFolder] = useState<Folder | null | undefined>(undefined)

  useEffect(() => {
    setFolder(undefined)
    return onSnapshot(docRef(uid, 'folders', folderID), (snapshot) => {
      if (!snapshot.exists()) {
        setFolder(null)
        return
      }
      const data = deserialize(snapshot.data()) as Folder
      data.id = snapshot.id
      setFolder(data)
    })
  }, [uid, folderID])

  return folder
}

export function useRemindersIn(uid: string, folderID: string): Reminder[] | undefined {
  return useQuerySnapshot<Reminder>(
    () => query(collectionRef(uid, 'reminders'), where('folderID', '==', folderID)),
    [uid, folderID],
  )
}

export function useRemindersFor(uid: string, personID: string): Reminder[] | undefined {
  return useQuerySnapshot<Reminder>(
    () => query(collectionRef(uid, 'reminders'), where('personIDs', 'array-contains', personID)),
    [uid, personID],
  )
}

export function useNotes(uid: string): Note[] | undefined {
  return useQuerySnapshot<Note>(() => query(collectionRef(uid, 'notes')), [uid])
}

export function useNote(uid: string, noteID: string): Note | null | undefined {
  const [note, setNote] = useState<Note | null | undefined>(undefined)

  useEffect(() => {
    setNote(undefined)
    return onSnapshot(docRef(uid, 'notes', noteID), (snapshot) => {
      if (!snapshot.exists()) {
        setNote(null)
        return
      }
      const data = deserialize(snapshot.data()) as Note
      data.id = snapshot.id
      setNote(data)
    })
  }, [uid, noteID])

  return note
}

/// A note's rich content, read only when the note is open.
///
/// `null` means the note has metadata but has never been saved — a note created
/// and not yet typed into. That is a real state, distinct from `undefined`
/// meaning the read has not finished, and the editor must tell them apart or it
/// will show an empty page over a note that is merely still loading.
export function useNoteContent(uid: string, noteID: string): NoteDocument | null | undefined {
  const [content, setContent] = useState<NoteDocument | null | undefined>(undefined)

  useEffect(() => {
    setContent(undefined)
    return onSnapshot(docRef(uid, 'noteContents', noteID), (snapshot) => {
      setContent(snapshot.exists() ? parseDocument(deserialize(snapshot.data())) : null)
    })
  }, [uid, noteID])

  return content
}

export function useSources(uid: string): SourceDocument[] | undefined {
  return useQuerySnapshot<SourceDocument>(() => query(collectionRef(uid, 'sources')), [uid])
}

export interface MemoryFeedResult {
  status: 'loading' | 'error' | 'ready'
  moments: MemoryMomentViewModel[]
  retry: () => void
}

/// The feed's one read model: the memories stream joined to its entities,
/// plus the legacy projection for everything that predates memory records.
/// `ready` only once every source has loaded — the empty state can never
/// flash while anything is still on its way. Local batch writes surface in
/// these snapshots synchronously (Firestore latency compensation), which is
/// what makes a fresh save appear without a reload.
export function useMemoryFeed(uid: string): MemoryFeedResult {
  const [nonce, setNonce] = useState(0)
  const [memories, setMemories] = useState<MemoryRecord[] | undefined>(undefined)
  const [failed, setFailed] = useState(false)

  useEffect(() => {
    setMemories(undefined)
    setFailed(false)
    const unsubscribe = onSnapshot(
      query(collectionRef(uid, 'memories'), orderBy('occurredAt', 'desc'), limitTo(100)),
      (snapshot) => {
        setMemories(
          snapshot.docs.map((docSnapshot) => {
            const data = deserialize(docSnapshot.data()) as MemoryRecord
            data.id = docSnapshot.id
            return data
          }),
        )
      },
      () => setFailed(true),
    )
    return unsubscribe
  }, [uid, nonce])

  const people = usePeople(uid)
  const interactions = useFeed(uid)
  const observations = useAllObservations(uid)
  const relationships = useAllRelationships(uid)
  const reminders = useReminders(uid)
  const sources = useSources(uid)

  const retry = useCallback(() => setNonce((n) => n + 1), [])

  const loaded =
    memories !== undefined &&
    people !== undefined &&
    interactions !== undefined &&
    observations !== undefined &&
    relationships !== undefined &&
    reminders !== undefined &&
    sources !== undefined

  const moments = useMemo(() => {
    if (!loaded) return []
    return projectFeed({
      memories: memories!,
      people: people!,
      interactions: interactions!,
      observations: observations!,
      relationships: relationships!,
      reminders: reminders!,
      sources: sources!,
    })
  }, [loaded, memories, people, interactions, observations, relationships, reminders, sources])

  return {
    status: failed ? 'error' : loaded ? 'ready' : 'loading',
    moments,
    retry,
  }
}

/// Server-written credential metadata, owner-readable under the rules. The
/// ref is deliberately built inline rather than through collections.ts:
/// aiCredentials is not a WritePlan collection, and keeping it out of that
/// vocabulary means applyPlan can never address it.
export function useAiCredentials(uid: string): AiCredential[] | undefined {
  return useQuerySnapshot<AiCredential>(
    () => query(collection(db, 'users', uid, 'aiCredentials'), orderBy('createdAt', 'desc')),
    [uid],
  )
}
