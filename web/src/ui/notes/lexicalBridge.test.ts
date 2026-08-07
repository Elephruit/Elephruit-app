/// The bake-off, kept as a test.
///
/// The question the editor choice turned on was whether a real Lexical editor
/// can carry every piece of the stored format and hand it back unchanged. This
/// runs a headless editor, applies a document, reads it back, and asserts
/// equality — so the answer stays true rather than having been true once.

import { createHeadlessEditor } from '@lexical/headless'
import { CodeNode } from '@lexical/code'
import { LinkNode } from '@lexical/link'
import { ListItemNode, ListNode } from '@lexical/list'
import { HeadingNode, QuoteNode } from '@lexical/rich-text'
import { describe, expect, it } from 'vitest'
import { normalizeParagraph, type NoteDocument, type NotePiece } from '../../domain/noteDocument'
import { applyDocumentToEditor, documentFromEditorState, unsupportedPieces } from './lexicalBridge'

function editor() {
  return createHeadlessEditor({
    namespace: 'test',
    nodes: [HeadingNode, QuoteNode, ListNode, ListItemNode, CodeNode, LinkNode],
    onError: (error) => {
      throw error
    },
  })
}

/// Applies a document to a real editor and reads back what it stores.
function roundTrip(document: NoteDocument): NoteDocument {
  const instance = editor()
  instance.update(() => applyDocumentToEditor(document), { discrete: true })
  const preserved = unsupportedPieces(document)
  return documentFromEditorState(instance.getEditorState(), preserved)
}

function prose(kind: string, text: string, extra: Record<string, unknown> = {}): NotePiece {
  return {
    type: 'prose',
    paragraph: normalizeParagraph({ kind: kind as never, runs: text ? [{ text }] : [], ...extra }),
  }
}

describe('the editor round trip', () => {
  it('carries every paragraph kind unchanged', () => {
    const document: NoteDocument = {
      version: 1,
      pieces: [
        prose('heading1', 'Chicago'),
        prose('heading2', 'To book'),
        prose('heading3', 'Notes'),
        prose('paragraph', 'Ordinary prose.'),
        prose('quote', 'Somebody else’s words'),
        prose('code', 'const x = 1', { language: 'ts' }),
        prose('bulleted', 'Deep dish'),
        prose('numbered', 'One'),
        prose('checklist', 'Hotel', { isTicked: true }),
      ],
    }
    expect(roundTrip(document)).toEqual(document)
  })

  it('carries every inline mark unchanged', () => {
    const document: NoteDocument = {
      version: 1,
      pieces: [
        {
          type: 'prose',
          paragraph: normalizeParagraph({
            runs: [
              { text: 'plain ' },
              { text: 'bold', marks: ['bold'] },
              { text: ' ' },
              { text: 'italic', marks: ['italic'] },
              { text: ' ' },
              { text: 'under', marks: ['underline'] },
              { text: ' ' },
              { text: 'strike', marks: ['strikethrough'] },
              { text: ' ' },
              { text: 'code', marks: ['code'] },
              { text: ' ' },
              { text: 'both', marks: ['bold', 'italic'] },
            ],
          }),
        },
      ],
    }
    expect(roundTrip(document)).toEqual(document)
  })

  it('carries a url link unchanged', () => {
    const document: NoteDocument = {
      version: 1,
      pieces: [
        {
          type: 'prose',
          paragraph: normalizeParagraph({
            runs: [{ text: 'the museum', link: { kind: 'url', value: 'https://fieldmuseum.org' } }],
          }),
        },
      ],
    }
    expect(roundTrip(document)).toEqual(document)
  })

  /// A wiki link survives as `[[Target]]`, which is what keeps the projection's
  /// brackets and therefore keeps link reconciliation working.
  it('carries a wiki link unchanged', () => {
    const document: NoteDocument = {
      version: 1,
      pieces: [
        {
          type: 'prose',
          paragraph: normalizeParagraph({
            runs: [{ text: 'the plan', link: { kind: 'wiki', value: 'Trip plan' } }],
          }),
        },
      ],
    }
    expect(roundTrip(document)).toEqual(document)
  })

  it('carries a nested list item’s indent', () => {
    const document: NoteDocument = {
      version: 1,
      pieces: [prose('bulleted', 'Top'), prose('bulleted', 'Under', { indent: 1 })],
    }
    expect(roundTrip(document)).toEqual(document)
  })

  it('carries a ticked box as ticked and an unticked one as not', () => {
    const document: NoteDocument = {
      version: 1,
      pieces: [prose('checklist', 'Done', { isTicked: true }), prose('checklist', 'Not done')],
    }
    const back = roundTrip(document)
    expect(back.pieces[0]).toEqual(prose('checklist', 'Done', { isTicked: true }))
    expect(back.pieces[1]).toEqual(prose('checklist', 'Not done'))
  })

  it('carries emoji and accents', () => {
    const document: NoteDocument = { version: 1, pieces: [prose('paragraph', 'Pokémon 🐘 café')] }
    expect(roundTrip(document)).toEqual(document)
  })

  it('survives the empty document', () => {
    const document: NoteDocument = { version: 1, pieces: [prose('paragraph', '')] }
    expect(roundTrip(document)).toEqual(document)
  })

  /// The shape that broke the Mac's conversion, kept as a case here for the
  /// same reason.
  it('survives a trailing empty paragraph', () => {
    const document: NoteDocument = {
      version: 1,
      pieces: [prose('paragraph', 'One'), prose('paragraph', '')],
    }
    const back = roundTrip(document)
    expect(back.pieces).toHaveLength(2)
    expect(back).toEqual(document)
  })

  it('survives an empty paragraph in the middle', () => {
    const document: NoteDocument = {
      version: 1,
      pieces: [prose('paragraph', 'One'), prose('paragraph', ''), prose('paragraph', 'Two')],
    }
    expect(roundTrip(document)).toEqual(document)
  })

  it('keeps two adjacent lists of different kinds apart', () => {
    const document: NoteDocument = {
      version: 1,
      pieces: [prose('bulleted', 'a'), prose('numbered', 'b'), prose('checklist', 'c')],
    }
    expect(roundTrip(document)).toEqual(document)
  })

  /// Losing what this client cannot render is how an editor silently destroys
  /// the parts of a note written somewhere else.
  it('gives back an image it cannot edit', () => {
    const document: NoteDocument = {
      version: 1,
      pieces: [prose('paragraph', 'Text'), { type: 'object', object: { type: 'image', attachmentID: 'a1' } }],
    }
    const back = roundTrip(document)
    expect(back.pieces).toContainEqual({ type: 'object', object: { type: 'image', attachmentID: 'a1' } })
  })

  it('gives back an object kind it has never heard of', () => {
    const alien: NotePiece = { type: 'object', object: { type: 'unknown', raw: { type: 'hologram' } } }
    const document: NoteDocument = { version: 1, pieces: [prose('paragraph', 'Text'), alien] }
    expect(roundTrip(document).pieces).toContainEqual(alien)
  })

  it('never returns a document with nowhere to put the caret', () => {
    const instance = editor()
    const back = documentFromEditorState(instance.getEditorState())
    expect(back.pieces.length).toBeGreaterThan(0)
  })
})

/// A `\n` inside a run is always wrong: a paragraph is the unit of structure,
/// so a newline in the middle of one projects a line the document does not
/// contain and cannot round-trip. It arrives by paste, and by any input path
/// that inserts raw text instead of raising `insertParagraph` — which is how
/// this was found, driving the editor from a browser test.
describe('newlines inside a run', () => {
  it('splits a pasted multi-line paragraph into paragraphs', () => {
    const instance = editor()
    instance.update(() => {
      applyDocumentToEditor({
        version: 1,
        pieces: [prose('paragraph', 'One\nTwo\nThree')],
      })
    }, { discrete: true })

    const back = documentFromEditorState(instance.getEditorState())
    expect(back.pieces).toHaveLength(3)
    expect(back.pieces.map((piece) => (piece.type === 'prose' ? piece.paragraph.runs[0]?.text : null))).toEqual([
      'One',
      'Two',
      'Three',
    ])
  })

  it('keeps the paragraph kind on every piece of the split', () => {
    const instance = editor()
    instance.update(() => {
      applyDocumentToEditor({ version: 1, pieces: [prose('checklist', 'A\nB')] })
    }, { discrete: true })

    const back = documentFromEditorState(instance.getEditorState())
    expect(back.pieces.every((piece) => piece.type === 'prose' && piece.paragraph.kind === 'checklist')).toBe(true)
  })

  /// A code block is a run of lines. Splitting it would turn one block into
  /// several, which is the opposite of what a code block is for.
  it('leaves a code block’s newlines alone', () => {
    const document: NoteDocument = {
      version: 1,
      pieces: [prose('code', 'const a = 1\nconst b = 2', { language: 'ts' })],
    }
    const back = roundTrip(document)
    expect(back.pieces).toHaveLength(1)
    expect(back).toEqual(document)
  })

  it('leaves an ordinary paragraph untouched', () => {
    const document: NoteDocument = { version: 1, pieces: [prose('paragraph', 'No newlines here')] }
    expect(roundTrip(document)).toEqual(document)
  })
})
