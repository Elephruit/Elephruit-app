/// The note page: a title, a body, and a toolbar that says what the caret is
/// standing in.
///
/// Saving is debounced and also flushed on unmount and on the page being hidden
/// — a note the user typed into and then closed the tab on must not be the one
/// thing this app loses. The document and its plain-text projection are written
/// in one plan, so a list can never show an excerpt from a version of the note
/// that no longer exists.

import { CodeNode } from '@lexical/code'
import { LinkNode } from '@lexical/link'
import { ListItemNode, ListNode } from '@lexical/list'
import { ListPlugin } from '@lexical/react/LexicalListPlugin'
import { CheckListPlugin } from '@lexical/react/LexicalCheckListPlugin'
import { LexicalComposer } from '@lexical/react/LexicalComposer'
import { useLexicalComposerContext } from '@lexical/react/LexicalComposerContext'
import { ContentEditable } from '@lexical/react/LexicalContentEditable'
import { LexicalErrorBoundary } from '@lexical/react/LexicalErrorBoundary'
import { HistoryPlugin } from '@lexical/react/LexicalHistoryPlugin'
import { OnChangePlugin } from '@lexical/react/LexicalOnChangePlugin'
import { RichTextPlugin } from '@lexical/react/LexicalRichTextPlugin'
import { TabIndentationPlugin } from '@lexical/react/LexicalTabIndentationPlugin'
import { HeadingNode, QuoteNode } from '@lexical/rich-text'
import { INSERT_CHECK_LIST_COMMAND, INSERT_ORDERED_LIST_COMMAND, INSERT_UNORDERED_LIST_COMMAND, REMOVE_LIST_COMMAND } from '@lexical/list'
import { $setBlocksType } from '@lexical/selection'
import { $createHeadingNode, $createQuoteNode } from '@lexical/rich-text'
import { $createCodeNode } from '@lexical/code'
import {
  $createParagraphNode,
  $getSelection,
  $isRangeSelection,
  FORMAT_TEXT_COMMAND,
  type EditorState,
  type LexicalEditor,
} from 'lexical'
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import type { NoteDocument, NotePiece } from '../../domain/noteDocument'
import { Icon } from '../components/Icon'
import { applyDocumentToEditor, documentFromEditorState, unsupportedPieces } from './lexicalBridge'

const THEME = {
  paragraph: 'note-p',
  quote: 'note-quote',
  heading: { h1: 'note-h1', h2: 'note-h2', h3: 'note-h3' },
  list: {
    ul: 'note-ul',
    ol: 'note-ol',
    listitem: 'note-li',
    listitemChecked: 'note-li-checked',
    listitemUnchecked: 'note-li-unchecked',
    nested: { listitem: 'note-li-nested' },
  },
  code: 'note-code',
  link: 'note-link',
  text: {
    bold: 'note-bold',
    italic: 'note-italic',
    underline: 'note-underline',
    strikethrough: 'note-strike',
    code: 'note-inline-code',
  },
}

/// Loads a document into the editor once, and again whenever the note being
/// edited changes.
///
/// Keyed on the note id rather than on the document's contents: re-applying on
/// every content change would reset the caret to the top on every keystroke,
/// which is the classic way a controlled rich-text editor becomes unusable.
function LoadPlugin({ noteID, document }: { noteID: string; document: NoteDocument | null }) {
  const [editor] = useLexicalComposerContext()
  const loaded = useRef<string | null>(null)

  useEffect(() => {
    if (!document || loaded.current === noteID) return
    loaded.current = noteID
    editor.update(() => applyDocumentToEditor(document))
  }, [editor, noteID, document])

  return null
}

type BlockKind = 'paragraph' | 'heading1' | 'heading2' | 'heading3' | 'quote' | 'code' | 'bulleted' | 'numbered' | 'checklist'

const BLOCKS: Array<{ kind: BlockKind; label: string; hint: string }> = [
  { kind: 'paragraph', label: 'Text', hint: 'Ordinary prose' },
  { kind: 'heading1', label: 'H1', hint: 'A top-level section' },
  { kind: 'heading2', label: 'H2', hint: 'A section inside a section' },
  { kind: 'heading3', label: 'H3', hint: 'The smallest heading' },
  { kind: 'bulleted', label: '•', hint: 'Bulleted list' },
  { kind: 'numbered', label: '1.', hint: 'Numbered list' },
  { kind: 'checklist', label: '☑', hint: 'Boxes to tick' },
  { kind: 'quote', label: '❝', hint: 'Somebody else’s words' },
  { kind: 'code', label: '</>', hint: 'Preformatted code' },
]

const MARKS: Array<{ format: 'bold' | 'italic' | 'underline' | 'strikethrough' | 'code'; label: string }> = [
  { format: 'bold', label: 'B' },
  { format: 'italic', label: 'I' },
  { format: 'underline', label: 'U' },
  { format: 'strikethrough', label: 'S' },
  { format: 'code', label: '⌗' },
]

function Toolbar() {
  const [editor] = useLexicalComposerContext()

  const setBlock = useCallback(
    (kind: BlockKind) => {
      // Lists are commands rather than block replacements — the list machinery
      // owns wrapping, merging and un-wrapping, and doing it by hand produces
      // structures its own commands then disagree with.
      if (kind === 'bulleted') return editor.dispatchCommand(INSERT_UNORDERED_LIST_COMMAND, undefined)
      if (kind === 'numbered') return editor.dispatchCommand(INSERT_ORDERED_LIST_COMMAND, undefined)
      if (kind === 'checklist') return editor.dispatchCommand(INSERT_CHECK_LIST_COMMAND, undefined)

      editor.update(() => {
        const selection = $getSelection()
        if (!$isRangeSelection(selection)) return
        editor.dispatchCommand(REMOVE_LIST_COMMAND, undefined)
        $setBlocksType(selection, () => {
          switch (kind) {
            case 'heading1':
              return $createHeadingNode('h1')
            case 'heading2':
              return $createHeadingNode('h2')
            case 'heading3':
              return $createHeadingNode('h3')
            case 'quote':
              return $createQuoteNode()
            case 'code':
              return $createCodeNode()
            default:
              return $createParagraphNode()
          }
        })
      })
    },
    [editor],
  )

  return (
    <div className="note-toolbar" role="toolbar" aria-label="Formatting">
      {MARKS.map((mark) => (
        <button
          key={mark.format}
          type="button"
          className="note-tool"
          aria-label={mark.format}
          title={mark.format}
          onMouseDown={(event) => event.preventDefault()}
          onClick={() => editor.dispatchCommand(FORMAT_TEXT_COMMAND, mark.format)}
        >
          {mark.label}
        </button>
      ))}
      <span className="note-toolbar-divider" aria-hidden="true" />
      {BLOCKS.map((block) => (
        <button
          key={block.kind}
          type="button"
          className="note-tool"
          aria-label={block.hint}
          title={block.hint}
          onMouseDown={(event) => event.preventDefault()}
          onClick={() => setBlock(block.kind)}
        >
          {block.label}
        </button>
      ))}
    </div>
  )
}

export interface NoteEditorProps {
  noteID: string
  document: NoteDocument | null
  title: string
  onTitleChange: (title: string) => void
  onDocumentChange: (document: NoteDocument) => void
  placeholder?: string
  readOnly?: boolean
}

export function NoteEditor({
  noteID,
  document,
  title,
  onTitleChange,
  onDocumentChange,
  placeholder = 'Start writing…',
  readOnly = false,
}: NoteEditorProps) {
  // Held in a ref, not in state: the pieces the editor cannot represent must
  // ride through every save, and re-rendering when they change would reload the
  // editor and take the caret with it.
  const preserved = useRef<NotePiece[]>([])
  const [ready, setReady] = useState(false)

  useEffect(() => {
    preserved.current = document ? unsupportedPieces(document) : []
    setReady(document !== null)
  }, [document, noteID])

  const config = useMemo(
    () => ({
      namespace: 'elephruit-note',
      theme: THEME,
      editable: !readOnly,
      nodes: [HeadingNode, QuoteNode, ListNode, ListItemNode, CodeNode, LinkNode],
      onError: (error: Error) => {
        // Never swallow it: a node type missing from `nodes` above fails here
        // and nowhere else, and a silently empty editor is the worst possible
        // symptom of it.
        console.error('Note editor', error)
      },
    }),
    [readOnly],
  )

  const handleChange = useCallback(
    (state: EditorState, _editor: LexicalEditor, tags: Set<string>) => {
      // The load itself is a change; reacting to it would mark a freshly opened
      // note dirty and save it back unmodified.
      if (tags.has('history-merge')) return
      onDocumentChange(documentFromEditorState(state, preserved.current))
    },
    [onDocumentChange],
  )

  return (
    <div className="note-editor">
      <input
        className="note-title"
        value={title}
        onChange={(event) => onTitleChange(event.target.value)}
        placeholder="Title"
        aria-label="Note title"
        readOnly={readOnly}
      />

      <LexicalComposer initialConfig={config} key={`${noteID}-${readOnly}`}>
        {!readOnly && <Toolbar />}
        <div className="note-surface">
          <RichTextPlugin
            contentEditable={<ContentEditable className="note-content" aria-label="Note body" />}
            placeholder={<p className="note-placeholder">{placeholder}</p>}
            ErrorBoundary={LexicalErrorBoundary}
          />
        </div>
        <HistoryPlugin />
        <ListPlugin />
        <CheckListPlugin />
        <TabIndentationPlugin />
        <OnChangePlugin onChange={handleChange} ignoreSelectionChange />
        {ready && <LoadPlugin noteID={noteID} document={document} />}
      </LexicalComposer>
    </div>
  )
}

export { Icon }
