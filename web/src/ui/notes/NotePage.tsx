/// One note, open.
///
/// Autosave is the whole reliability story here, and it has three triggers, not
/// one: a debounce while typing, a flush when the component goes away, and a
/// flush when the page is hidden. The third is the one that matters — closing a
/// tab fires `visibilitychange` and `pagehide`, and it does *not* reliably give
/// a React unmount enough time to finish an async write. A note the user typed
/// and then closed must not be the one thing this app loses.

import { useCallback, useEffect, useRef, useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { applyPlan } from '../../data/applyPlan'
import { useFolders, useNote, useNoteContent, usePeople } from '../../data/hooks'
import { isArchived } from '../../domain/folder'
import { relativeDescription } from '../../domain/contact'
import {
  NOTHING_PENDING,
  planDeleteNote,
  planFlush,
  planUpdateNote,
  type Note,
  type PendingNoteEdit,
} from '../../domain/note'
import type { NoteDocument } from '../../domain/noteDocument'
import { Button, IconButton } from '../components/Button'
import { Dialog } from '../components/Dialog'
import { EmptyState } from '../components/EmptyState'
import { SkeletonRows } from '../components/Skeleton'
import { PageScaffold } from '../shell/PageScaffold'
import { useUID } from '../UserContext'
import { FolderPicker } from '../folders/FolderPicker'
import { NoteEditor } from './NoteEditor'

const SAVE_DEBOUNCE_MS = 700

export function NotePage({
  embedded = false,
  focusMode = false,
  onBack,
  onToggleFocus,
}: {
  embedded?: boolean
  focusMode?: boolean
  onBack?: () => void
  onToggleFocus?: () => void
}) {
  const uid = useUID()
  const navigate = useNavigate()
  const { noteID = '' } = useParams()
  const note = useNote(uid, noteID)
  const content = useNoteContent(uid, noteID)
  const folders = useFolders(uid)
  const people = usePeople(uid)

  const [title, setTitle] = useState('')
  const [status, setStatus] = useState<'idle' | 'saving' | 'saved' | 'error'>('idle')
  const [refusal, setRefusal] = useState<string | null>(null)
  const [deleting, setDeleting] = useState(false)
  const [formatMenuTarget, setFormatMenuTarget] = useState<HTMLElement | null>(null)

  /// The unsaved edit. A ref rather than state because a flush must read the
  /// latest value from inside a `visibilitychange` handler, which closes over
  /// whatever state was current when it was registered.
  ///
  /// `title: null` means untouched — never `''`, which is what the user typing
  /// an empty title means. See `planFlush`.
  const pending = useRef<PendingNoteEdit>({ ...NOTHING_PENDING })
  const timer = useRef<number | undefined>(undefined)
  const noteRef = useRef<Note | null>(null)

  useEffect(() => {
    if (!note) return
    noteRef.current = note
    // Only adopt the stored title while nothing is being typed, or a snapshot
    // arriving mid-edit would yank the field back to what is on the server.
    if (pending.current.title === null) setTitle(note.title)
  }, [note])

  const flush = useCallback(async () => {
    const subject = noteRef.current
    if (!subject) return

    const work = planFlush(subject, pending.current, new Date())
    if (!work) return

    window.clearTimeout(timer.current)
    pending.current = { ...NOTHING_PENDING }

    if (work.refusal) {
      setRefusal(work.refusal)
      setStatus('error')
      return
    }

    setStatus('saving')
    try {
      await applyPlan(uid, work.plan)
      setRefusal(null)
      setStatus('saved')
    } catch {
      setStatus('error')
    }
  }, [uid])

  const schedule = useCallback(() => {
    window.clearTimeout(timer.current)
    timer.current = window.setTimeout(() => void flush(), SAVE_DEBOUNCE_MS)
  }, [flush])

  // Flush on the way out, by both routes. `visibilitychange` covers closing the
  // tab and switching apps on a phone, which an unmount does not.
  useEffect(() => {
    const onHide = () => {
      if (window.document.visibilityState === 'hidden') void flush()
    }
    window.document.addEventListener('visibilitychange', onHide)
    window.addEventListener('pagehide', onHide)
    return () => {
      window.document.removeEventListener('visibilitychange', onHide)
      window.removeEventListener('pagehide', onHide)
      void flush()
    }
  }, [flush])

  const onDocumentChange = useCallback(
    (document: NoteDocument) => {
      pending.current = { ...pending.current, document }
      setStatus('saving')
      schedule()
    },
    [schedule],
  )

  const onTitleChange = useCallback(
    (next: string) => {
      setTitle(next)
      pending.current = { ...pending.current, title: next }
      setStatus('saving')
      schedule()
    },
    [schedule],
  )

  async function setFolder(folderID: string | null) {
    if (!note) return
    await applyPlan(uid, planUpdateNote(note.id, { folderID }, new Date()).plan)
  }

  async function confirmDelete() {
    if (!note) return
    await applyPlan(uid, planDeleteNote(note.id).plan)
    navigate('/notes')
  }

  if (note === undefined || content === undefined) {
    const loading = <SkeletonRows count={5} />
    return embedded ? loading : <PageScaffold width="reading">{loading}</PageScaffold>
  }

  if (note === null) {
    const missing = (
      <EmptyState
        icon="note"
        headline="Not here"
        message="This note has been deleted."
        action={
          <Button variant="primary" onClick={() => navigate('/notes')}>
            Back to Notes
          </Button>
        }
      />
    )
    return embedded ? missing : <PageScaffold width="reading">{missing}</PageScaffold>
  }

  const folder = folders?.find((entry) => entry.id === note.folderID)
  const readOnly = folder ? isArchived(folder) : false

  const editor = (
    <section className={embedded ? 'note-inline-pane' : undefined}>
      {/* No PageHeader here. A note already has a title — the big field the
          editor owns — and a page header carrying the same words above it reads
          as the title having been said twice. This row is the metadata and the
          actions only. */}
      <div className="note-header">
        {embedded && onBack && <IconButton label="Back to notes" icon="back" size={18} onClick={onBack} />}
        <span className="container-meta">
          <span>Edited {relativeDescription(note.updatedAt, new Date())}</span>
          {status === 'saving' && <span>Saving…</span>}
          {status === 'saved' && <span>Saved</span>}
          {status === 'error' && <span className="field-error">Not saved</span>}
        </span>
        <span className="note-header-actions">
          <FolderPicker
            folders={folders ?? []}
            value={note.folderID}
            onChange={(id) => void setFolder(id)}
            label="File this note in"
            disabled={readOnly}
            compact
          />
          <span className="note-format-menu-host" ref={setFormatMenuTarget} />
          <IconButton label="Delete note" icon="trash" size={18} onClick={() => setDeleting(true)} />
          {embedded && onToggleFocus && (
            <IconButton
              label={focusMode ? 'Show folders' : 'Hide folders'}
              icon={focusMode ? 'collapse' : 'expand'}
              size={18}
              onClick={onToggleFocus}
            />
          )}
        </span>
      </div>

      {readOnly && (
        <div className="archive-banner">
          <span>
            {folder?.title} is archived, so this note is read-only. Unarchive it to make changes.
          </span>
        </div>
      )}

      {refusal && (
        <p className="field-error" role="alert">
          {refusal}
        </p>
      )}

      <NoteEditor
        noteID={note.id}
        document={content}
        title={title}
        onTitleChange={onTitleChange}
        onDocumentChange={onDocumentChange}
        readOnly={readOnly}
        formatMenuTarget={formatMenuTarget}
      />

      {deleting && (
        <Dialog title="Delete this note?" onClose={() => setDeleting(false)}>
          <p className="row-subtitle">
            The note and everything written in it go for good. This cannot be undone.
          </p>
          <div className="sheet-actions">
            <Button variant="quiet" onClick={() => setDeleting(false)}>
              Cancel
            </Button>
            <Button variant="destructive" onClick={() => void confirmDelete()}>
              Delete
            </Button>
          </div>
        </Dialog>
      )}

      {people && note.personIDs.length > 0 && (
        <p className="row-subtitle">
          About {note.personIDs.map((id) => people.find((p) => p.id === id)?.displayName).filter(Boolean).join(', ')}
        </p>
      )}
    </section>
  )

  return embedded ? editor : <PageScaffold width="reading">{editor}</PageScaffold>
}
