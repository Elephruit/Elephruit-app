import { describe, expect, it } from 'vitest'
import {
  NOTE_PARAGRAPH_KINDS,
  emptyDocument,
  isDocumentEmpty,
  normalizeMarks,
  normalizeParagraph,
  normalizeRuns,
  outlineOf,
  parseDocument,
  projectToText,
  type NoteDocument,
  type NotePiece,
} from './noteDocument'

/// The gate: a document containing every piece kind must survive being written
/// and read back **exactly**. Everything the editor does sits on top of this,
/// so a failure here is a failure of the whole format, not of a feature.
const everything: NoteDocument = {
  version: 1,
  pieces: [
    { type: 'prose', paragraph: normalizeParagraph({ kind: 'heading1', runs: [{ text: 'Chicago' }] }) },
    {
      type: 'prose',
      paragraph: normalizeParagraph({
        kind: 'paragraph',
        runs: [
          { text: 'Book the ' },
          { text: 'Field Museum', marks: ['bold', 'italic'] },
          { text: ' first — see ' },
          { text: 'the plan', link: { kind: 'wiki', value: 'Trip plan' } },
          { text: ' and ', marks: [] },
          { text: 'this', link: { kind: 'url', value: 'https://example.org' } },
        ],
      }),
    },
    { type: 'prose', paragraph: normalizeParagraph({ kind: 'heading2', runs: [{ text: 'To book' }] }) },
    { type: 'prose', paragraph: normalizeParagraph({ kind: 'checklist', runs: [{ text: 'Hotel' }], isTicked: true }) },
    { type: 'prose', paragraph: normalizeParagraph({ kind: 'checklist', runs: [{ text: 'Tickets' }], indent: 2 }) },
    { type: 'prose', paragraph: normalizeParagraph({ kind: 'bulleted', runs: [{ text: 'Deep dish' }] }) },
    { type: 'prose', paragraph: normalizeParagraph({ kind: 'numbered', runs: [{ text: 'One' }] }) },
    { type: 'prose', paragraph: normalizeParagraph({ kind: 'numbered', runs: [{ text: 'Two' }] }) },
    { type: 'prose', paragraph: normalizeParagraph({ kind: 'quote', runs: [{ text: 'Somebody else' }] }) },
    {
      type: 'prose',
      paragraph: normalizeParagraph({ kind: 'code', runs: [{ text: 'const x = 1' }], language: 'ts' }),
    },
    {
      type: 'prose',
      paragraph: normalizeParagraph({ kind: 'callout', runs: [{ text: 'Sells out' }], tone: 'warning' }),
    },
    { type: 'prose', paragraph: normalizeParagraph({ kind: 'heading3', runs: [{ text: 'Notes' }] }) },
    { type: 'prose', paragraph: normalizeParagraph({ runs: [{ text: 'Strike', marks: ['strikethrough'] }] }) },
    { type: 'prose', paragraph: normalizeParagraph({ runs: [{ text: 'code', marks: ['code'] }] }) },
    { type: 'prose', paragraph: normalizeParagraph({ runs: [{ text: 'under', marks: ['underline'] }] }) },
    { type: 'prose', paragraph: normalizeParagraph({ runs: [{ text: 'Emoji 🐘 and accents é' }] }) },
    { type: 'object', object: { type: 'divider' } },
    {
      type: 'object',
      object: {
        type: 'table',
        table: { hasHeaderRow: true, rows: [[[{ text: 'Day' }], [{ text: 'Plan' }]], [[{ text: 'Fri' }], [{ text: 'Museum' }]]] },
      },
    },
    { type: 'object', object: { type: 'reference', itemID: 'person-1' } },
    { type: 'object', object: { type: 'page', noteID: 'note-2' } },
    { type: 'object', object: { type: 'image', attachmentID: 'att-1', caption: [{ text: 'The bean' }] } },
    { type: 'object', object: { type: 'file', attachmentID: 'att-2' } },
    { type: 'object', object: { type: 'webClip', attachmentID: 'att-3' } },
    // The trailing empty paragraph — the shape that broke the Mac's conversion.
    { type: 'prose', paragraph: normalizeParagraph({}) },
  ],
}

function roundTrip(document: NoteDocument): NoteDocument {
  return parseDocument(JSON.parse(JSON.stringify(document)))
}

describe('the round trip is the identity', () => {
  it('survives every piece kind at once', () => {
    expect(roundTrip(everything)).toEqual(everything)
  })

  it('survives the empty document', () => {
    expect(roundTrip(emptyDocument())).toEqual(emptyDocument())
  })

  it('survives a trailing empty paragraph', () => {
    const document: NoteDocument = {
      version: 1,
      pieces: [
        { type: 'prose', paragraph: normalizeParagraph({ runs: [{ text: 'One' }] }) },
        { type: 'prose', paragraph: normalizeParagraph({}) },
      ],
    }
    expect(roundTrip(document)).toEqual(document)
    expect(roundTrip(document).pieces).toHaveLength(2)
  })

  it('survives every paragraph kind on its own', () => {
    for (const kind of NOTE_PARAGRAPH_KINDS) {
      const document: NoteDocument = {
        version: 1,
        pieces: [{ type: 'prose', paragraph: normalizeParagraph({ kind, runs: [{ text: 'x' }] }) }],
      }
      expect(roundTrip(document), kind).toEqual(document)
    }
  })

  /// Dropping what this client cannot render is how an editor silently destroys
  /// the parts of a note written somewhere else.
  it('preserves an object kind it has never heard of', () => {
    const alien = { type: 'hologram', payload: { spin: 3 } }
    const parsed = parseDocument({ version: 9, pieces: [{ type: 'object', object: alien }] })
    expect(parsed.pieces[0]).toEqual({ type: 'object', object: { type: 'unknown', raw: alien } })
  })

  it('keeps a version it does not recognise rather than rewriting it', () => {
    expect(parseDocument({ version: 99, pieces: [] }).version).toBe(1)
    expect(parseDocument({ version: 99, pieces: [{ type: 'prose', paragraph: {} }] }).version).toBe(99)
  })
})

describe('normalizing', () => {
  it('drops a mark this build has never heard of', () => {
    expect(normalizeMarks(['bold', 'rainbow', 'code'])).toEqual(['bold', 'code'])
  })

  /// Two equal documents must encode identically, or the round-trip test above
  /// is really a test of array ordering.
  it('puts marks in canonical order however they arrive', () => {
    expect(normalizeMarks(['code', 'italic', 'bold'])).toEqual(['bold', 'italic', 'code'])
  })

  it('merges adjacent runs with the same formatting', () => {
    const runs = normalizeRuns([
      { text: 'Hello ' },
      { text: 'world' },
      { text: '!', marks: ['bold'] },
    ])
    expect(runs).toEqual([{ text: 'Hello world' }, { text: '!', marks: ['bold'] }])
  })

  it('does not merge across a differing link', () => {
    const runs = normalizeRuns([
      { text: 'a', link: { kind: 'url', value: 'x' } },
      { text: 'b', link: { kind: 'url', value: 'y' } },
    ])
    expect(runs).toHaveLength(2)
  })

  it('drops empty runs', () => {
    expect(normalizeRuns([{ text: '' }, { text: 'kept' }])).toEqual([{ text: 'kept' }])
  })

  it('strips a tick from anything that is not a checklist', () => {
    expect(normalizeParagraph({ kind: 'heading1', isTicked: true }).isTicked).toBeUndefined()
  })

  it('strips an indent from anything that does not nest', () => {
    expect(normalizeParagraph({ kind: 'quote', indent: 3 }).indent).toBeUndefined()
    expect(normalizeParagraph({ kind: 'bulleted', indent: 3 }).indent).toBe(3)
  })

  it('brings a wild indent into range', () => {
    expect(normalizeParagraph({ kind: 'bulleted', indent: 99 }).indent).toBe(5)
  })

  it('strips a language from anything that is not code', () => {
    expect(normalizeParagraph({ kind: 'paragraph', language: 'ts' }).language).toBeUndefined()
  })

  it('gives a callout a tone rather than leaving it toneless', () => {
    expect(normalizeParagraph({ kind: 'callout' }).tone).toBe('note')
  })

  it('reads an unknown paragraph kind as prose rather than refusing the note', () => {
    expect(normalizeParagraph({ kind: 'interpretive-dance' as never }).kind).toBe('paragraph')
  })
})

describe('reading a document', () => {
  it('never returns a document with nowhere to put the caret', () => {
    expect(parseDocument({ pieces: [] }).pieces).toHaveLength(1)
    expect(parseDocument(null).pieces).toHaveLength(1)
    expect(parseDocument('nonsense').pieces).toHaveLength(1)
  })

  it('knows an effectively empty document from one with a space in it', () => {
    expect(isDocumentEmpty(emptyDocument())).toBe(true)
    expect(isDocumentEmpty(everything)).toBe(false)
  })

  it('builds an outline from the headings only', () => {
    expect(outlineOf(everything)).toEqual([
      { position: 0, level: 1, title: 'Chicago' },
      { position: 2, level: 2, title: 'To book' },
      { position: 11, level: 3, title: 'Notes' },
    ])
  })

  it('leaves an empty heading out of the outline', () => {
    const document: NoteDocument = {
      version: 1,
      pieces: [{ type: 'prose', paragraph: normalizeParagraph({ kind: 'heading1', runs: [] }) }],
    }
    expect(outlineOf(document)).toEqual([])
  })
})

describe('the plain-text projection', () => {
  /// A wiki link lives as an attribute on a run. A projection emitting only the
  /// visible text would drop the brackets and quietly unmake every link in the
  /// note on the next save.
  it('keeps a wiki link’s brackets so reconciliation still finds it', () => {
    expect(projectToText(everything)).toContain('[[Trip plan]]')
  })

  it('writes a url link as markdown', () => {
    expect(projectToText(everything)).toContain('[this](https://example.org)')
  })

  it('marks a ticked box as ticked and an unticked one as not', () => {
    const text = projectToText(everything)
    expect(text).toContain('- [x] Hotel')
    expect(text).toContain('- [ ] Tickets')
  })

  it('numbers a numbered list from one, and restarts after other content', () => {
    const pieces: NotePiece[] = [
      { type: 'prose', paragraph: normalizeParagraph({ kind: 'numbered', runs: [{ text: 'a' }] }) },
      { type: 'prose', paragraph: normalizeParagraph({ kind: 'numbered', runs: [{ text: 'b' }] }) },
      { type: 'prose', paragraph: normalizeParagraph({ runs: [{ text: 'break' }] }) },
      { type: 'prose', paragraph: normalizeParagraph({ kind: 'numbered', runs: [{ text: 'c' }] }) },
    ]
    expect(projectToText({ version: 1, pieces })).toBe('1. a\n2. b\nbreak\n1. c')
  })

  it('fences code with its language', () => {
    expect(projectToText(everything)).toContain('```ts\nconst x = 1\n```')
  })

  it('indents a nested list item', () => {
    expect(projectToText(everything)).toContain('    - [ ] Tickets')
  })
})
