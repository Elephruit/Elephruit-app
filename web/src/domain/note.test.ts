import { describe, expect, it } from 'vitest'
import {
  DOCUMENT_BYTE_BUDGET,
  displayTitle,
  documentByteSize,
  documentRefusal,
  excerptOf,
  makeNote,
  planCreateNote,
  planDeleteNote,
  planSaveNote,
  planUpdateNote,
  type Note,
} from './note'
import { emptyDocument, normalizeParagraph, type NoteDocument } from './noteDocument'

const now = new Date('2026-11-01T09:00:00Z')

function note(overrides: Partial<Note> = {}): Note {
  return { ...makeNote({}, now), ...overrides }
}

function documentOf(...lines: string[]): NoteDocument {
  return {
    version: 1,
    pieces: lines.map((text) => ({ type: 'prose', paragraph: normalizeParagraph({ runs: [{ text }] }) })),
  }
}

describe('creation', () => {
  it('writes only the metadata — content waits for the first save', () => {
    const { plan } = planCreateNote({}, now)
    expect(plan).toHaveLength(1)
    expect(plan[0].collection).toBe('notes')
  })

  it('files into a container when told to', () => {
    expect(makeNote({ containerID: 'chicago' }, now).containerID).toBe('chicago')
  })

  it('starts unarchived and unpinned', () => {
    const fresh = makeNote({}, now)
    expect(fresh.archivedAt).toBeNull()
    expect(fresh.pinnedAt).toBeNull()
  })
})

describe('saving', () => {
  it('writes the metadata and the content as one plan', () => {
    const { plan } = planSaveNote(note({ id: 'n1' }), documentOf('Deep dish list'), now)
    expect(plan.map((write) => write.collection)).toEqual(['notes', 'noteContents'])
    expect(plan.every((write) => write.id === 'n1')).toBe(true)
  })

  /// The projection is derived on every save rather than stored once, so it
  /// cannot drift from the document it describes.
  it('recomputes the projection from the document', () => {
    const { bodyText } = planSaveNote(note(), documentOf('One', 'Two'), now)
    expect(bodyText).toBe('One\nTwo')
  })

  it('caps the projection so a long note does not bloat every list', () => {
    const long = documentOf('x'.repeat(5000))
    const { bodyText } = planSaveNote(note(), long, now)
    expect(bodyText.length).toBe(2048)
  })

  it('does not cap the stored document — only its projection', () => {
    const long = documentOf('x'.repeat(5000))
    const { plan } = planSaveNote(note(), long, now)
    const content = plan.find((write) => write.collection === 'noteContents')
    expect(JSON.stringify(content)).toContain('x'.repeat(5000))
  })
})

/// Firestore refuses a document over 1 MiB. Discovered as a failed write it is
/// a save that silently did not happen; refused here it is a sentence.
describe('the size ceiling', () => {
  it('lets an ordinary note through', () => {
    expect(documentRefusal(documentOf('A normal note.'))).toBeNull()
  })

  it('refuses one past the budget, and says what to do', () => {
    const huge = documentOf('x'.repeat(DOCUMENT_BYTE_BUDGET + 1000))
    const refusal = documentRefusal(huge)
    expect(refusal).toContain('too large to save')
    expect(refusal).toContain('Split it into two notes')
  })

  it('plans nothing at all when it refuses', () => {
    const huge = documentOf('x'.repeat(DOCUMENT_BYTE_BUDGET + 1000))
    const { plan, refusal } = planSaveNote(note(), huge, now)
    expect(refusal).not.toBeNull()
    expect(plan).toEqual([])
  })

  /// `string.length` counts UTF-16 units; the limit is measured in UTF-8 bytes.
  it('counts bytes, not characters, so emoji are not under-counted', () => {
    const emoji = documentOf('🐘'.repeat(100))
    const plain = documentOf('x'.repeat(100))
    expect(documentByteSize(emoji)).toBeGreaterThan(documentByteSize(plain) + 200)
  })
})

describe('deleting', () => {
  it('takes the content with it in the same batch', () => {
    const { plan } = planDeleteNote('n1')
    expect(plan).toEqual([
      { op: 'delete', collection: 'noteContents', id: 'n1' },
      { op: 'delete', collection: 'notes', id: 'n1' },
    ])
  })
})

describe('what a row shows', () => {
  it('prefers the note’s own title', () => {
    expect(displayTitle({ title: 'Packing', bodyText: 'socks' })).toBe('Packing')
  })

  /// An untitled note is not an error state, so it is not drawn as one.
  it('falls back to the first line with anything in it', () => {
    expect(displayTitle({ title: '  ', bodyText: '\n\nDeep dish places\nPequod' })).toBe('Deep dish places')
  })

  it('says Untitled note only when there is genuinely nothing', () => {
    expect(displayTitle({ title: '', bodyText: '' })).toBe('Untitled note')
  })

  it('does not repeat the title in the excerpt', () => {
    expect(excerptOf({ title: '', bodyText: 'Places\nPequod\nLou Malnati' })).toBe('Pequod Lou Malnati')
  })

  it('strips markdown furniture from the excerpt', () => {
    expect(excerptOf({ title: 'X', bodyText: '# Heading\n- [ ] Buy tickets' })).toBe('Heading Buy tickets')
  })

  it('has no excerpt when the note is only a title', () => {
    expect(excerptOf({ title: 'Packing', bodyText: 'Packing' })).toBeNull()
  })

  it('truncates a long excerpt on a character, not mid-word forever', () => {
    const excerpt = excerptOf({ title: 'T', bodyText: 'word '.repeat(100) }, 40)
    expect(excerpt).toHaveLength(40)
    expect(excerpt?.endsWith('…')).toBe(true)
  })
})

describe('metadata updates', () => {
  it('stamps updatedAt so lists re-sort', () => {
    const { plan } = planUpdateNote('n1', { containerID: 'chicago' }, now)
    expect(plan[0]).toEqual({
      op: 'update',
      collection: 'notes',
      id: 'n1',
      data: { containerID: 'chicago', updatedAt: now },
    })
  })
})

describe('an empty note', () => {
  it('opens with somewhere to put the caret', () => {
    expect(emptyDocument().pieces).toHaveLength(1)
  })
})
