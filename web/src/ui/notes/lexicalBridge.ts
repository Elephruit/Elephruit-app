/// The only place Lexical's model and the stored format meet.
///
/// Lexical owns editing; `NoteDocument` owns storage. Keeping the conversion in
/// one file — rather than reading editor nodes wherever a save happens — is
/// what makes the round trip testable, and the round trip is the whole contract:
/// what comes out of the editor must be what goes into it.
///
/// This lives under `ui/` rather than `domain/` on purpose. It imports Lexical,
/// and the hygiene test exists precisely to keep the domain layer free of
/// libraries it does not need.

import { $createCodeNode, $isCodeNode } from '@lexical/code'
import { $createLinkNode, $isLinkNode } from '@lexical/link'
import {
  $createListItemNode,
  $createListNode,
  $isListItemNode,
  $isListNode,
  type ListItemNode,
} from '@lexical/list'
import { $createHeadingNode, $createQuoteNode, $isHeadingNode, $isQuoteNode } from '@lexical/rich-text'
import {
  $createParagraphNode,
  $createTextNode,
  $getRoot,
  $isElementNode,
  $isParagraphNode,
  $isTextNode,
  type EditorState,
  type ElementNode,
  type LexicalNode,
} from 'lexical'
import {
  NOTE_FORMAT_VERSION,
  normalizeParagraph,
  normalizeRuns,
  type NoteDocument,
  type NoteMark,
  type NoteParagraph,
  type NoteParagraphKind,
  type NotePiece,
  type NoteRun,
} from '../../domain/noteDocument'

/// Lexical stores inline formatting as a bitfield with fixed bits. Mapped
/// explicitly rather than by index, so a future Lexical release adding a format
/// cannot silently shift what "bold" means.
const FORMAT_BITS: Array<{ mark: NoteMark; bit: number }> = [
  { mark: 'bold', bit: 1 },
  { mark: 'italic', bit: 1 << 1 },
  { mark: 'strikethrough', bit: 1 << 2 },
  { mark: 'underline', bit: 1 << 3 },
  { mark: 'code', bit: 1 << 4 },
]

function marksFromFormat(format: number): NoteMark[] {
  return FORMAT_BITS.filter(({ bit }) => (format & bit) !== 0).map(({ mark }) => mark)
}

function formatFromMarks(marks: readonly NoteMark[] | undefined): number {
  if (!marks?.length) return 0
  return FORMAT_BITS.reduce((acc, { mark, bit }) => (marks.includes(mark) ? acc | bit : acc), 0)
}

// MARK: - Editor state → document

function runsOf(node: ElementNode): NoteRun[] {
  const runs: NoteRun[] = []

  const walk = (children: LexicalNode[], link: NoteRun['link']) => {
    for (const child of children) {
      if ($isLinkNode(child)) {
        const url = child.getURL()
        // `[[Target]]` typed literally is a wiki link, not a URL. Recognised
        // here so the projection keeps its brackets and reconciliation still
        // finds it — the failure the Mac's projection exists to prevent.
        const wiki = /^\[\[(.+)\]\]$/.exec(url)
        walk(child.getChildren(), wiki ? { kind: 'wiki', value: wiki[1] } : { kind: 'url', value: url })
        continue
      }
      if ($isTextNode(child)) {
        const marks = marksFromFormat(child.getFormat())
        const run: NoteRun = { text: child.getTextContent() }
        if (marks.length) run.marks = marks
        if (link) run.link = link
        runs.push(run)
        continue
      }
      if ($isElementNode(child)) walk(child.getChildren(), link)
    }
  }

  walk(node.getChildren(), undefined)
  return normalizeRuns(runs)
}

function kindOfHeading(tag: string): NoteParagraphKind {
  return tag === 'h1' ? 'heading1' : tag === 'h2' ? 'heading2' : 'heading3'
}

/// Splits runs containing a newline into one paragraph's worth of runs each.
///
/// A paragraph is the unit of structure here, so a `\n` *inside* a run is
/// always wrong — it projects as a line that the document does not actually
/// contain, and it cannot round-trip, because reading it back produces one
/// paragraph where the text reads as two. It arrives two ways in practice:
/// pasting text with embedded newlines, and any input path that inserts raw
/// text rather than raising `insertParagraph` (which is how it was found).
///
/// Code is the exception and keeps its newlines: a code block is a run of lines
/// and splitting it would turn one block into many.
function splitOnNewlines(runs: NoteRun[]): NoteRun[][] {
  const paragraphs: NoteRun[][] = [[]]

  for (const run of runs) {
    if (!run.text.includes('\n')) {
      paragraphs[paragraphs.length - 1].push(run)
      continue
    }
    const parts = run.text.split('\n')
    parts.forEach((part, index) => {
      if (index > 0) paragraphs.push([])
      if (part) paragraphs[paragraphs.length - 1].push({ ...run, text: part })
    })
  }

  // A trailing newline leaves a trailing empty paragraph, and that is correct:
  // it is what the text said. Nothing is dropped here — an empty paragraph is a
  // real thing a document can contain, and the round-trip tests pin it.
  return paragraphs
}

/// One prose paragraph, or several when its text carried newlines.
function proseFor(kind: NoteParagraphKind, runs: NoteRun[], extra: Partial<NoteParagraph> = {}): NotePiece[] {
  return splitOnNewlines(runs).map((paragraphRuns) => ({
    type: 'prose' as const,
    paragraph: normalizeParagraph({ kind, runs: paragraphRuns, ...extra }),
  }))
}

function paragraphsFromListItem(item: LexicalNode, listKind: NoteParagraphKind, depth: number): NotePiece[] {
  if (!$isListItemNode(item)) return []

  // Lexical expresses list depth two ways and uses both. Pressing Tab sets the
  // item's own `indent`; a document built with nested `ListNode`s expresses the
  // same thing structurally, and Lexical's own normalisation moves between them.
  // Reading only the structure loses a Tab, and reading only `getIndent()` loses
  // a nested list — so take whichever is larger and the stored format is right
  // either way.
  const nested = item.getChildren().filter($isListNode)
  if (nested.length > 0) {
    return nested.flatMap((list) =>
      list.getChildren().flatMap((child) => paragraphsFromListItem(child, listKind, depth + 1)),
    )
  }

  return proseFor(listKind, runsOf(item), {
    indent: Math.max(depth, item.getIndent()),
    isTicked: listKind === 'checklist' ? item.getChecked() === true : false,
  })
}

function piecesOf(node: LexicalNode): NotePiece[] {
  if ($isHeadingNode(node)) {
    return proseFor(kindOfHeading(node.getTag()), runsOf(node))
  }

  if ($isQuoteNode(node)) {
    return proseFor('quote', runsOf(node))
  }

  if ($isCodeNode(node)) {
    return [
      {
        type: 'prose',
        paragraph: normalizeParagraph({
          kind: 'code',
          runs: [{ text: node.getTextContent() }],
          language: node.getLanguage() ?? undefined,
        }),
      },
    ]
  }

  if ($isListNode(node)) {
    const listKind: NoteParagraphKind =
      node.getListType() === 'check' ? 'checklist' : node.getListType() === 'number' ? 'numbered' : 'bulleted'
    return node.getChildren().flatMap((item) => paragraphsFromListItem(item, listKind, 0))
  }

  if ($isParagraphNode(node)) {
    return proseFor('paragraph', runsOf(node))
  }

  return []
}

/// Reads the editor and returns the document to store.
///
/// `preserved` carries back the pieces the editor never had — images, files,
/// web clips, anything a newer build wrote. They are appended rather than
/// dropped, because losing what this client cannot render is how an editor
/// silently destroys a note written somewhere else.
export function documentFromEditorState(state: EditorState, preserved: NotePiece[] = []): NoteDocument {
  const pieces = state.read(() => $getRoot().getChildren().flatMap(piecesOf))
  return {
    version: NOTE_FORMAT_VERSION,
    // Never empty: a document with no paragraphs has nowhere to put the caret.
    pieces: pieces.length > 0 || preserved.length > 0 ? [...pieces, ...preserved] : [{ type: 'prose', paragraph: normalizeParagraph({}) }],
  }
}

/// The pieces the editor cannot represent, so a save can put them back.
export function unsupportedPieces(document: NoteDocument): NotePiece[] {
  return document.pieces.filter(
    (piece) => piece.type === 'object' && piece.object.type !== 'divider',
  )
}

// MARK: - Document → editor

function textNodesFor(runs: NoteRun[]): LexicalNode[] {
  return runs.map((run) => {
    const text = $createTextNode(run.text)
    const format = formatFromMarks(run.marks)
    if (format) text.setFormat(format)
    if (!run.link) return text as LexicalNode
    const url = run.link.kind === 'wiki' ? `[[${run.link.value}]]` : run.link.value
    const link = $createLinkNode(url)
    link.append(text)
    return link as LexicalNode
  })
}

function elementFor(paragraph: NoteParagraph): ElementNode {
  switch (paragraph.kind) {
    case 'heading1':
      return $createHeadingNode('h1')
    case 'heading2':
      return $createHeadingNode('h2')
    case 'heading3':
      return $createHeadingNode('h3')
    case 'quote':
      return $createQuoteNode()
    case 'code': {
      const code = $createCodeNode(paragraph.language ?? undefined)
      return code
    }
    default:
      return $createParagraphNode()
  }
}

/// Rebuilds the editor's contents from a stored document.
///
/// Runs consecutive list paragraphs of the same kind back into one list node,
/// because that is the shape Lexical's own commands produce — build them as one
/// list per item and pressing Return merges them anyway, so the document would
/// change shape on a keystroke that changed nothing.
export function applyDocumentToEditor(document: NoteDocument): void {
  const root = $getRoot()
  root.clear()

  const proseParagraphs = document.pieces
    .filter((piece): piece is Extract<NotePiece, { type: 'prose' }> => piece.type === 'prose')
    .map((piece) => piece.paragraph)

  let index = 0
  while (index < proseParagraphs.length) {
    const paragraph = proseParagraphs[index]

    const isList = paragraph.kind === 'bulleted' || paragraph.kind === 'numbered' || paragraph.kind === 'checklist'
    if (!isList) {
      const element = elementFor(paragraph)
      if (paragraph.kind === 'code') {
        element.append($createTextNode(paragraph.runs.map((run) => run.text).join('')))
      } else {
        for (const node of textNodesFor(paragraph.runs)) element.append(node)
      }
      root.append(element)
      index += 1
      continue
    }

    const kind = paragraph.kind
    const listType = kind === 'checklist' ? 'check' : kind === 'numbered' ? 'number' : 'bullet'
    const list = $createListNode(listType)
    const pendingIndents: Array<{ item: ListItemNode; indent: number }> = []

    while (index < proseParagraphs.length && proseParagraphs[index].kind === kind) {
      const item = $createListItemNode(kind === 'checklist' ? proseParagraphs[index].isTicked === true : undefined)
      for (const node of textNodesFor(proseParagraphs[index].runs)) item.append(node)
      const indent = proseParagraphs[index].indent ?? 0
      if (indent > 0) pendingIndents.push({ item, indent })
      list.append(item)
      index += 1
    }

    root.append(list)
    // `setIndent` only takes on an *attached* item: it works by wrapping the
    // item in a nested list, which needs a parent to do. Called before the list
    // reaches the root it silently does nothing, and the indent is lost on the
    // next read — which is exactly how this was found.
    for (const { item, indent } of pendingIndents) item.setIndent(indent)
  }

  if (root.getChildrenSize() === 0) root.append($createParagraphNode())
}
