/// The note page: a title and a body, and no chrome until you ask for it.
///
/// The first version put fourteen buttons above every note, permanently. They
/// were legible and they were still wrong: a page you are trying to write on
/// should not open with a control panel, and B / I / U / S / ⌗ / Text / H1 / H2
/// / H3 / • / 1. / ☑ / ❝ / </> is a menu bar pretending to be a document.
///
/// What replaces it, in the order a writer meets it:
///
/// 1. **Markdown shortcuts.** `# `, `## `, `- `, `1. `, `> `, ``` and `[] `
///    become the thing they look like as you type. Most formatting never needs
///    a control at all — which is the real fix, the other two being fallbacks.
/// 2. **A toolbar over the selection.** Marks are only meaningful with text
///    selected, so that is exactly when they appear, where the text is.
/// 3. **One Format menu**, for block kinds and for anybody who does not know
///    the shortcuts. Discoverable, and shut.

import { CodeNode } from '@lexical/code'
import { LinkNode } from '@lexical/link'
import {
  INSERT_CHECK_LIST_COMMAND,
  INSERT_ORDERED_LIST_COMMAND,
  INSERT_UNORDERED_LIST_COMMAND,
  ListItemNode,
  ListNode,
  REMOVE_LIST_COMMAND,
} from '@lexical/list'
import { TRANSFORMERS } from '@lexical/markdown'
import { CheckListPlugin } from '@lexical/react/LexicalCheckListPlugin'
import { LexicalComposer } from '@lexical/react/LexicalComposer'
import { useLexicalComposerContext } from '@lexical/react/LexicalComposerContext'
import { ContentEditable } from '@lexical/react/LexicalContentEditable'
import { LexicalErrorBoundary } from '@lexical/react/LexicalErrorBoundary'
import { HistoryPlugin } from '@lexical/react/LexicalHistoryPlugin'
import { ListPlugin } from '@lexical/react/LexicalListPlugin'
import { MarkdownShortcutPlugin } from '@lexical/react/LexicalMarkdownShortcutPlugin'
import { OnChangePlugin } from '@lexical/react/LexicalOnChangePlugin'
import { RichTextPlugin } from '@lexical/react/LexicalRichTextPlugin'
import { TabIndentationPlugin } from '@lexical/react/LexicalTabIndentationPlugin'
import { $createHeadingNode, $createQuoteNode, HeadingNode, QuoteNode } from '@lexical/rich-text'
import { $setBlocksType } from '@lexical/selection'
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
import { createPortal } from 'react-dom'
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

/// Loads a document into the editor once, and again whenever the note changes.
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
  { kind: 'heading1', label: 'Heading 1', hint: '# ' },
  { kind: 'heading2', label: 'Heading 2', hint: '## ' },
  { kind: 'heading3', label: 'Heading 3', hint: '### ' },
  { kind: 'bulleted', label: 'Bulleted list', hint: '- ' },
  { kind: 'numbered', label: 'Numbered list', hint: '1. ' },
  { kind: 'checklist', label: 'Checklist', hint: '[] ' },
  { kind: 'quote', label: 'Quote', hint: '> ' },
  { kind: 'code', label: 'Code block', hint: '```' },
]

function useBlockCommand() {
  const [editor] = useLexicalComposerContext()
  return useCallback(
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
}

/// The block menu — shut by default, and the only permanent control.
function FormatMenu() {
  const setBlock = useBlockCommand()
  const [open, setOpen] = useState(false)
  const root = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!open) return
    const onPointerDown = (event: MouseEvent) => {
      if (!root.current?.contains(event.target as Node)) setOpen(false)
    }
    const onKeyDown = (event: KeyboardEvent) => event.key === 'Escape' && setOpen(false)
    window.document.addEventListener('mousedown', onPointerDown)
    window.document.addEventListener('keydown', onKeyDown)
    return () => {
      window.document.removeEventListener('mousedown', onPointerDown)
      window.document.removeEventListener('keydown', onKeyDown)
    }
  }, [open])

  return (
    <div className="format-menu" ref={root}>
      <button
        type="button"
        className="icon-button format-menu-button"
        aria-haspopup="menu"
        aria-expanded={open}
        aria-label="Format note"
        title="Format note"
        onMouseDown={(event) => event.preventDefault()}
        onClick={() => setOpen((current) => !current)}
      >
        <Icon name="format" size={18} />
      </button>

      {open && (
        <div className="format-menu-list" role="menu">
          {BLOCKS.map((block) => (
            <button
              key={block.kind}
              type="button"
              role="menuitem"
              className="format-menu-item"
              onMouseDown={(event) => event.preventDefault()}
              onClick={() => {
                setBlock(block.kind)
                setOpen(false)
              }}
            >
              <span>{block.label}</span>
              {/* The shortcut is shown beside its name so the menu teaches
                  itself out of a job. */}
              <kbd className="format-menu-hint">{block.hint}</kbd>
            </button>
          ))}
        </div>
      )}
    </div>
  )
}

const MARKS = [
  { format: 'bold', label: 'B', title: 'Bold  ⌘B' },
  { format: 'italic', label: 'I', title: 'Italic  ⌘I' },
  { format: 'underline', label: 'U', title: 'Underline  ⌘U' },
  { format: 'strikethrough', label: 'S', title: 'Strikethrough' },
  { format: 'code', label: '⌗', title: 'Inline code' },
] as const

/// The marks, over the selection, only while there is one.
///
/// Positioned from the selection's own rectangle rather than from the caret:
/// it should sit above what you highlighted, and follow it if the window is
/// resized under it. Clamped to the viewport so a selection near the top edge
/// does not push the toolbar off-screen.
function SelectionToolbar() {
  const [editor] = useLexicalComposerContext()
  const [position, setPosition] = useState<{ top: number; left: number } | null>(null)
  const bar = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const update = () => {
      const selection = window.getSelection()
      const editorState = editor.getEditorState()
      const hasRange = editorState.read(() => {
        const lexical = $getSelection()
        return $isRangeSelection(lexical) && !lexical.isCollapsed()
      })

      if (!hasRange || !selection || selection.rangeCount === 0) {
        setPosition(null)
        return
      }
      const rect = selection.getRangeAt(0).getBoundingClientRect()
      if (rect.width === 0 && rect.height === 0) {
        setPosition(null)
        return
      }
      const height = bar.current?.offsetHeight ?? 36
      setPosition({
        top: Math.max(8, rect.top + window.scrollY - height - 8),
        left: rect.left + window.scrollX + rect.width / 2,
      })
    }

    const unregister = editor.registerUpdateListener(() => update())
    window.document.addEventListener('selectionchange', update)
    window.addEventListener('resize', update)
    window.addEventListener('scroll', update, true)
    return () => {
      unregister()
      window.document.removeEventListener('selectionchange', update)
      window.removeEventListener('resize', update)
      window.removeEventListener('scroll', update, true)
    }
  }, [editor])

  if (!position) return null

  return (
    <div
      className="selection-toolbar"
      ref={bar}
      role="toolbar"
      aria-label="Formatting"
      style={{ top: position.top, left: position.left }}
    >
      {MARKS.map((mark) => (
        <button
          key={mark.format}
          type="button"
          className="selection-tool"
          aria-label={mark.title}
          title={mark.title}
          // Without this the mousedown clears the selection before the click
          // lands, and the button formats nothing.
          onMouseDown={(event) => event.preventDefault()}
          onClick={() => editor.dispatchCommand(FORMAT_TEXT_COMMAND, mark.format)}
        >
          {mark.label}
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
  formatMenuTarget?: HTMLElement | null
}

export function NoteEditor({
  noteID,
  document,
  title,
  onTitleChange,
  onDocumentChange,
  placeholder = 'Start writing…',
  readOnly = false,
  formatMenuTarget = null,
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
        <div className="note-surface">
          <RichTextPlugin
            contentEditable={<ContentEditable className="note-content" aria-label="Note body" />}
            placeholder={<p className="note-placeholder">{placeholder}</p>}
            ErrorBoundary={LexicalErrorBoundary}
          />
          {!readOnly && <SelectionToolbar />}
        </div>
        {!readOnly && formatMenuTarget && createPortal(<FormatMenu />, formatMenuTarget)}
        <HistoryPlugin />
        <ListPlugin />
        <CheckListPlugin />
        <TabIndentationPlugin />
        {/* Typing `# ` or `- ` becomes the thing it looks like. The reason the
            toolbar could be put away. */}
        <MarkdownShortcutPlugin transformers={TRANSFORMERS} />
        <OnChangePlugin onChange={handleChange} ignoreSelectionChange />
        {ready && <LoadPlugin noteID={noteID} document={document} />}
      </LexicalComposer>
    </div>
  )
}
