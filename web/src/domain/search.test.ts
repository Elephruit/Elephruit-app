import { describe, expect, it } from 'vitest'
import type { Folder } from './folder'
import type { Interaction } from './interaction'
import type { Person } from './person'
import type { Reminder } from './reminders'
import { search } from './search'

const now = new Date('2026-11-01T09:00:00Z')

const travel: Folder = {
  id: 'travel',
  title: 'Travel',
  summary: null,
  colorName: 'blue',
  parentID: null,
  startAt: null,
  dueAt: null,
  archivedAt: null,
  createdAt: now,
  updatedAt: now,
}

const chicago: Folder = {
  ...travel,
  id: 'chicago',
  title: 'Chicago, October',
  parentID: 'travel',
  archivedAt: now,
}

const tickets: Reminder = {
  id: 'tickets',
  title: 'Buy tickets for the Pokémon exhibit at the Field Museum',
  notes: null,
  personIDs: [],
  folderID: 'chicago',
  sourceInteractionID: null,
  startAt: null,
  dueAt: null,
  isSomeday: false,
  status: 'open',
  completedAt: null,
  createdAt: now,
}

const groceries: Reminder = { ...tickets, id: 'groceries', title: 'Buy milk', folderID: null }

const ana: Person = {
  id: 'ana',
  displayName: 'Ana Torres',
  givenName: 'Ana',
  familyName: 'Torres',
  roleTitle: 'Curator',
  organizationName: 'Field Museum',
  colorName: 'green',
  isPlaceholder: false,
  hasStatedName: true,
  createdAt: now,
  lastContactAt: now,
}

const chat: Interaction = {
  id: 'chat',
  kind: 'phone',
  provenance: 'logged',
  summary: 'Called about the museum booking',
  discussion: 'She said the Pokémon exhibit sells out early.',
  participantIDs: ['ana'],
  occurredAt: now,
  createdAt: now,
}

const everything = { people: [ana], folders: [travel, chicago], reminders: [tickets, groceries], interactions: [chat] }

describe('search', () => {
  it('finds nothing for an empty query rather than everything', () => {
    expect(search('   ', everything)).toEqual({ live: [], archived: [] })
  })

  /// The request, verbatim: still searchable, but archived. No token typed.
  it('finds a reminder inside an archived trip without being asked to', () => {
    const { archived } = search('pokémon', everything)
    expect(archived.map((hit) => hit.id)).toContain('tickets')
  })

  it('keeps archived matches out of the live group', () => {
    const { live } = search('pokémon', everything)
    expect(live.map((hit) => hit.id)).not.toContain('tickets')
  })

  it('treats a reminder as archived because its folder is', () => {
    const { archived } = search('pokémon', everything)
    expect(archived.find((hit) => hit.id === 'tickets')?.archived).toBe(true)
  })

  it('leaves an unfiled reminder live', () => {
    const { live } = search('buy', everything)
    expect(live.map((hit) => hit.id)).toContain('groceries')
  })

  it('matches without the accent', () => {
    expect(search('pokemon', everything).archived.map((hit) => hit.id)).toContain('tickets')
  })

  it('searches across kinds at once', () => {
    const { live, archived } = search('museum', everything)
    const kinds = new Set([...live, ...archived].map((hit) => hit.kind))
    expect(kinds).toEqual(new Set(['person', 'reminder', 'interaction']))
  })

  it('ranks a title match above a body-only one', () => {
    const { live } = search('museum', everything)
    // Ana's org is "Field Museum"; the interaction only mentions it in its
    // summary, which is its title — so both are title-ish. Ana wins on the
    // organization weight plus recency being equal.
    expect(live[0].kind).toBe('interaction')
  })

  it('prefers a whole-word start over a match inside a word', () => {
    const folders = [
      { ...travel, id: 'a', title: 'Rescheduling' },
      { ...travel, id: 'b', title: 'The schedule' },
    ]
    const { live } = search('schedule', { folders })
    expect(live[0].id).toBe('b')
  })

  it('finds a folder by its summary', () => {
    const withSummary = [{ ...travel, id: 'x', title: 'Nothing', summary: 'deep dish pizza' }]
    expect(search('pizza', { folders: withSummary }).live.map((h) => h.id)).toEqual(['x'])
  })

  it('names the folder a reminder belongs to, so two similar rows differ', () => {
    const { archived } = search('pokémon', everything)
    expect(archived.find((hit) => hit.id === 'tickets')?.detail).toBe('Chicago, October')
  })

  it('leaves placeholder people out — a record with nothing in it is not a result', () => {
    const ghost: Person = { ...ana, id: 'ghost', displayName: 'Ana’s son', isPlaceholder: true }
    expect(search('ana', { people: [ana, ghost] }).live.map((hit) => hit.id)).toEqual(['ana'])
  })

  it('respects the limit on each group independently', () => {
    const many = Array.from({ length: 60 }, (_, i) => ({ ...travel, id: `c${i}`, title: `Trip ${i}` }))
    expect(search('trip', { folders: many }, 10).live).toHaveLength(10)
  })

  it('copes with collections that were not passed at all', () => {
    expect(search('anything', {})).toEqual({ live: [], archived: [] })
  })
})
