/// A note's contents: the stored rich-text format.
///
/// This is ADR 0006's design in TypeScript — a versioned list of paragraphs
/// made of marked runs, with an **allow-listed** set of inline marks. The
/// allow-list is the load-bearing part: an attribute this app does not
/// understand cannot be represented, so sanitising pasted content is a property
/// of the format rather than a pass somebody has to remember to write. Foreign
/// HTML arriving with a hard-coded red foreground has nowhere to put it, which
/// is also what keeps notes readable in dark mode.
///
/// ### Its relationship to the Mac app's format
/// The *vocabulary* is deliberately identical — the same ten paragraph kinds,
/// the same five marks under the same names, the same three link kinds, the
/// same "omit defaults when writing" rule. The *envelope* is not: Swift
/// synthesises `{"prose":{"_0":…}}` for an enum with an associated value, and
/// hand-writing that shape here would be unreadable for the sake of a byte
/// equality nothing yet depends on. A future importer is therefore a mechanical
/// adapter over the envelope, not a re-derivation of the model. Said plainly
/// here so nobody discovers it by diffing two exports.
///
/// ### Unsupported pieces are preserved, not dropped
/// The web cannot create an image, a file or a web clip — this app stores no
/// file bytes (see `sources.ts`). But a document that arrives carrying one must
/// keep it. Dropping what the current client cannot render is how an editor
/// silently destroys the parts of a note written somewhere else, and it is a
/// mistake worth refusing structurally rather than remembering not to make.

export const NOTE_PARAGRAPH_KINDS = [
  'paragraph',
  'heading1',
  'heading2',
  'heading3',
  'quote',
  'code',
  'callout',
  'bulleted',
  'numbered',
  'checklist',
] as const
export type NoteParagraphKind = (typeof NOTE_PARAGRAPH_KINDS)[number]

export const PARAGRAPH_KIND_LABELS: Record<NoteParagraphKind, string> = {
  paragraph: 'Text',
  heading1: 'Heading 1',
  heading2: 'Heading 2',
  heading3: 'Heading 3',
  quote: 'Quote',
  code: 'Code',
  callout: 'Callout',
  bulleted: 'Bulleted list',
  numbered: 'Numbered list',
  checklist: 'Checklist',
}

export function isListKind(kind: NoteParagraphKind): boolean {
  return kind === 'bulleted' || kind === 'numbered' || kind === 'checklist'
}

export function headingLevel(kind: NoteParagraphKind): number | null {
  return kind === 'heading1' ? 1 : kind === 'heading2' ? 2 : kind === 'heading3' ? 3 : null
}

export const NOTE_CALLOUT_TONES = ['note', 'tip', 'important', 'warning', 'aside'] as const
export type NoteCalloutTone = (typeof NOTE_CALLOUT_TONES)[number]

/// The palette *name* a tone resolves through — never a colour. The design
/// layer owns what the name looks like, which is what keeps a callout legible
/// in both appearances.
export const CALLOUT_TONE_PALETTE: Record<NoteCalloutTone, string> = {
  note: 'blue',
  tip: 'green',
  important: 'indigo',
  warning: 'orange',
  aside: 'graphite',
}

/// The closed set of inline marks, in the order they are written.
///
/// Ordered deliberately: the encoded form has to be stable, or two documents
/// that are the same document produce different bytes and every round-trip test
/// becomes a test of array ordering. Stored as names rather than a bitfield for
/// the same reason the archive format is pretty-printed — `["bold","code"]`
/// says what it is in a diff; `5` does not.
export const NOTE_MARKS = ['bold', 'italic', 'underline', 'strikethrough', 'code'] as const
export type NoteMark = (typeof NOTE_MARKS)[number]

/// Drops names this build has never heard of and puts the rest in canonical
/// order. That loss is the allow-list doing its job, and it is the trade ADR
/// 0006 makes on purpose: a mark that cannot be rendered, exported, searched or
/// reasoned about is not worth carrying on the chance that some other build
/// could.
export function normalizeMarks(marks: readonly string[] | undefined): NoteMark[] {
  if (!marks?.length) return []
  return NOTE_MARKS.filter((mark) => marks.includes(mark))
}

export type NoteLink =
  | { kind: 'url'; value: string }
  /// A modelled relationship with a stable target — a person, a project.
  | { kind: 'item'; value: string }
  /// A link *by title* to something that may not exist yet. A first-class state
  /// here rather than a broken link.
  | { kind: 'wiki'; value: string }

export interface NoteRun {
  text: string
  marks?: NoteMark[]
  link?: NoteLink | null
}

function sameFormatting(a: NoteRun, b: NoteRun): boolean {
  const marksA = (a.marks ?? []).join(',')
  const marksB = (b.marks ?? []).join(',')
  if (marksA !== marksB) return false
  const linkA = a.link ? `${a.link.kind}:${a.link.value}` : ''
  const linkB = b.link ? `${b.link.kind}:${b.link.value}` : ''
  return linkA === linkB
}

/// Empty runs removed, adjacent identically-formatted runs merged, marks put in
/// canonical order.
///
/// Applied on the way in as well as on the way out, so a document written by
/// hand, by an importer, or by an older build cannot put the editor into a
/// state its own operations would never produce — and so that two equal
/// documents encode identically, which is what makes the round-trip test mean
/// something.
export function normalizeRuns(runs: readonly NoteRun[] | undefined): NoteRun[] {
  const out: NoteRun[] = []
  for (const raw of runs ?? []) {
    if (!raw?.text) continue
    const marks = normalizeMarks(raw.marks)
    const run: NoteRun = { text: raw.text }
    if (marks.length) run.marks = marks
    if (raw.link) run.link = raw.link

    const last = out[out.length - 1]
    if (last && sameFormatting(last, run)) last.text += run.text
    else out.push(run)
  }
  return out
}

export interface NoteParagraph {
  kind: NoteParagraphKind
  runs: NoteRun[]
  /// How deeply a list item is nested. Zero for everything else.
  indent?: number
  /// Whether a checklist item is ticked. Meaningless on every other kind.
  isTicked?: boolean
  language?: string
  tone?: NoteCalloutTone
}

export const MAX_INDENT = 5

/// Drops the fields this kind cannot use and brings the indent into range.
///
/// The paragraph does this to itself rather than trusting its callers, because
/// a heading carrying a tick and an indent of nine is a paragraph that two
/// pieces of code will disagree about: one asks the kind what to draw and
/// ignores them, the other reads the stored fields and honours them. Turning a
/// checklist item into a heading should lose the tick — it is not a checklist
/// item any more — and it should lose it here, once.
export function normalizeParagraph(input: Partial<NoteParagraph> | undefined): NoteParagraph {
  const kind: NoteParagraphKind = NOTE_PARAGRAPH_KINDS.includes(input?.kind as NoteParagraphKind)
    ? (input!.kind as NoteParagraphKind)
    : 'paragraph'

  const paragraph: NoteParagraph = { kind, runs: normalizeRuns(input?.runs) }

  if (isListKind(kind)) {
    const indent = Math.max(0, Math.min(Math.trunc(input?.indent ?? 0), MAX_INDENT))
    if (indent > 0) paragraph.indent = indent
  }
  if (kind === 'checklist' && input?.isTicked) paragraph.isTicked = true
  if (kind === 'code' && input?.language) paragraph.language = input.language
  if (kind === 'callout') {
    paragraph.tone = NOTE_CALLOUT_TONES.includes(input?.tone as NoteCalloutTone)
      ? (input!.tone as NoteCalloutTone)
      : 'note'
  }
  return paragraph
}

export interface NoteTable {
  rows: NoteRun[][][]
  hasHeaderRow: boolean
}

/// The pieces a note can hold that are not prose.
///
/// `image`, `file` and `webClip` cannot be created on the web — there is
/// nowhere to put the bytes — but they are declared so a document carrying one
/// survives a save here untouched.
export type NoteObject =
  | { type: 'divider' }
  | { type: 'table'; table: NoteTable }
  | { type: 'reference'; itemID: string }
  | { type: 'page'; noteID: string }
  | { type: 'image'; attachmentID: string; caption?: NoteRun[] }
  | { type: 'file'; attachmentID: string }
  | { type: 'webClip'; attachmentID: string }
  /// Anything a newer build wrote that this one has never heard of. Carried
  /// through a save verbatim rather than discarded.
  | { type: 'unknown'; raw: unknown }

const KNOWN_OBJECT_TYPES = ['divider', 'table', 'reference', 'page', 'image', 'file', 'webClip']

export type NotePiece = { type: 'prose'; paragraph: NoteParagraph } | { type: 'object'; object: NoteObject }

export const NOTE_FORMAT_VERSION = 1

export interface NoteDocument {
  version: number
  pieces: NotePiece[]
}

/// A document with a single empty paragraph.
///
/// Never genuinely empty: an editor with no paragraphs has nowhere to put the
/// caret, so a new note would open as a page that cannot be typed into.
export function emptyDocument(): NoteDocument {
  return { version: NOTE_FORMAT_VERSION, pieces: [{ type: 'prose', paragraph: normalizeParagraph({}) }] }
}

/// Reads anything and returns a document this app's own operations could have
/// produced. Never throws: a note that cannot be parsed opens empty rather than
/// refusing to open, because the alternative is a page the user cannot reach.
export function parseDocument(raw: unknown): NoteDocument {
  const source = raw as { version?: unknown; pieces?: unknown } | null | undefined
  const pieces = Array.isArray(source?.pieces) ? source.pieces : []

  const parsed: NotePiece[] = []
  for (const piece of pieces) {
    const entry = piece as { type?: string; paragraph?: unknown; object?: unknown }
    if (entry?.type === 'object') {
      const object = entry.object as { type?: string }
      parsed.push({
        type: 'object',
        object: KNOWN_OBJECT_TYPES.includes(object?.type ?? '')
          ? (entry.object as NoteObject)
          : { type: 'unknown', raw: entry.object },
      })
    } else {
      parsed.push({ type: 'prose', paragraph: normalizeParagraph(entry?.paragraph as NoteParagraph) })
    }
  }

  if (parsed.length === 0) return emptyDocument()
  return {
    version: typeof source?.version === 'number' ? source.version : NOTE_FORMAT_VERSION,
    pieces: parsed,
  }
}

// MARK: - Reading

export function paragraphText(paragraph: NoteParagraph): string {
  return paragraph.runs.map((run) => run.text).join('')
}

export function isDocumentEmpty(document: NoteDocument): boolean {
  return document.pieces.every(
    (piece) => piece.type === 'prose' && paragraphText(piece.paragraph).trim() === '',
  )
}

/// The headings, for an outline.
export function outlineOf(document: NoteDocument): Array<{ position: number; level: number; title: string }> {
  const out: Array<{ position: number; level: number; title: string }> = []
  document.pieces.forEach((piece, position) => {
    if (piece.type !== 'prose') return
    const level = headingLevel(piece.paragraph.kind)
    if (level === null) return
    const title = paragraphText(piece.paragraph).trim()
    if (title) out.push({ position, level, title })
  })
  return out
}

/// The plain-text projection — what the note document is stored *beside*, and
/// what lists, excerpts and search actually read.
///
/// Markdown rather than bare text, for the same reason the Mac's is: a wiki
/// link lives as an attribute on a run, so a projection emitting only visible
/// text would drop the brackets and quietly unmake every link in the note on
/// the next save.
export function projectToText(document: NoteDocument): string {
  const lines: string[] = []
  let numberedCounter = 0

  for (const piece of document.pieces) {
    if (piece.type === 'object') {
      if (piece.object.type === 'divider') lines.push('---')
      if (piece.object.type === 'table') {
        for (const row of piece.object.table.rows) {
          lines.push(`| ${row.map((cell) => normalizeRuns(cell).map((r) => r.text).join('')).join(' | ')} |`)
        }
      }
      numberedCounter = 0
      continue
    }

    const paragraph = piece.paragraph
    const body = paragraph.runs
      .map((run) => {
        if (!run.link) return run.text
        if (run.link.kind === 'wiki') return `[[${run.link.value}]]`
        if (run.link.kind === 'url') return `[${run.text}](${run.link.value})`
        return run.text
      })
      .join('')

    if (paragraph.kind !== 'numbered') numberedCounter = 0
    const pad = '  '.repeat(paragraph.indent ?? 0)

    switch (paragraph.kind) {
      case 'heading1':
        lines.push(`# ${body}`)
        break
      case 'heading2':
        lines.push(`## ${body}`)
        break
      case 'heading3':
        lines.push(`### ${body}`)
        break
      case 'quote':
        lines.push(`> ${body}`)
        break
      case 'code':
        lines.push('```' + (paragraph.language ?? ''), body, '```')
        break
      case 'callout':
        lines.push(`> [!${paragraph.tone ?? 'note'}] ${body}`)
        break
      case 'bulleted':
        lines.push(`${pad}- ${body}`)
        break
      case 'numbered':
        numberedCounter += 1
        lines.push(`${pad}${numberedCounter}. ${body}`)
        break
      case 'checklist':
        lines.push(`${pad}- [${paragraph.isTicked ? 'x' : ' '}] ${body}`)
        break
      default:
        lines.push(body)
    }
  }

  return lines.join('\n')
}
