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
import { useContainers, useNote, useNoteContent, usePeople } from '../../data/hooks'
import { buildTree, flattenTree, isArchived, pathLabel } from '../../domain/container'
import { relativeDescription } from '../../domain/contact'
import { planDeleteNote, planSaveNote, planUpdateNote, type Note } from '../../domain/note'
import type { NoteDocument } from '../../domain/noteDocument'
import { Button } from '../components/Button'
import { Dialog } from '../components/Dialog'
import { EmptyState } from '../components/EmptyState'
import { SkeletonRows } from '../components/Skeleton'
import { PageScaffold } from '../shell/PageScaffold'
import { useUID } from '../UserContext'
import { NoteEditor } from './NoteEditor'

const SAVE_DEBOUNCE_MS = 700

export function NotePage() {
  const uid = useUID()
  const navigate = useNavigate()
  const { noteID = '' } = useParams()
  const note = useNote(uid, noteID)
  const content = useNoteContent(uid, noteID)
  const containers = useContainers(uid)
  const people = usePeople(uid)

  const [title, setTitle] = useState('')
  const [status, setStatus] = useState<'idle' | 'saving' | 'saved' | 'error'>('idle')
  const [refusal, setRefusal] = useState<string | null>(null)
  const [deleting, setDeleting] = useState(false)

  /// The unsaved edit. A ref rather than state because a flush must read the
  /// latest value from inside a `visibilitychange` handler, which closes over
  /// whatever state was current when it was registered.
  const pending = useRef<{ document: NoteDocument | null; title: string }>({ document: null, title: '' })
  const timer = useRef<number | undefined>(undefined)
  const noteRef = useRef<Note | null>(null)

  useEffect(() => {
    if (note) {
      noteRef.current = note
      setTitle((current) => (current === '' && pending.current.title === '' ? note.title : current))
    }
  }, [note])

  const flush = useCallback(async () => {
    const subject = noteRef.current
    const edit = pending.current
    if (!subject || (!edit.document && edit.title === subject.title)) return

    window.clearTimeout(timer.current)
    pending.current = { document: null, title: edit.title }

    const document = edit.document
    if (!document) {
      await applyPlan(uid, planUpdateNote(subject.id, { title: edit.title }, new Date()).plan)
      setStatus('saved')
      return
    }

    const { plan, refusal: tooBig } = planSaveNote({ ...subject, title: edit.title }, document, new Date())
    if (tooBig) {
      setRefusal(tooBig)
      setStatus('error')
      return
    }

    setStatus('saving')
    try {
      await applyPlan(uid, plan)
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

  async function setContainer(containerID: string | null) {
    if (!note) return
    await applyPlan(uid, planUpdateNote(note.id, { containerID }, new Date()).plan)
  }

  async function confirmDelete() {
    if (!note) return
    await applyPlan(uid, planDeleteNote(note.id).plan)
    navigate('/notes')
  }

  if (note === undefined || content === undefined) {
    return (
      <PageScaffold width="reading">
        <SkeletonRows count={5} />
      </PageScaffold>
    )
  }

  if (note === null) {
    return (
      <PageScaffold width="reading">
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
      </PageScaffold>
    )
  }

  const container = containers?.find((entry) => entry.id === note.containerID)
  const readOnly = container ? isArchived(container) : false

  return (
    <PageScaffold width="reading">
      {/* No PageHeader here. A note already has a title — the big field the
          editor owns — and a page header carrying the same words above it reads
          as the title having been said twice. This row is the metadata and the
          actions only. */}
      <div className="note-header">
        <span className="container-meta">
          <span>Edited {relativeDescription(note.updatedAt, new Date())}</span>
          {status === 'saving' && <span>Saving…</span>}
          {status === 'saved' && <span>Saved</span>}
          {status === 'error' && <span className="field-error">Not saved</span>}
        </span>
        <span className="note-header-actions">
          {containers && containers.length > 0 && (
            <select
              className="field field-inline"
              aria-label="File this note in"
              value={note.containerID ?? ''}
              onChange={(event) => void setContainer(event.target.value || null)}
            >
              <option value="">Unfiled</option>
              {flattenTree(buildTree(containers)).map((node) => (
                <option key={node.container.id} value={node.container.id}>
                  {pathLabel(containers, node.container.id)}
                </option>
              ))}
            </select>
          )}
          <Button variant="quiet" icon="trash" onClick={() => setDeleting(true)}>
            Delete
          </Button>
        </span>
      </div>

      {readOnly && (
        <div className="archive-banner">
          <span>
            {container?.title} is archived, so this note is read-only. Unarchive it to make changes.
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
    </PageScaffold>
  )
}
