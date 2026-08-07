/// Every note, with the folder tree beside it.
///
/// The filter used to be a `<select>` of full paths above the list. A tree in a
/// column is the thing that actually scales: branches collapse, so a hundred
/// folders is still six rows if they are nested and shut, and the selected
/// folder stays visible while you read what is in it rather than collapsing
/// back into a closed control.
///
/// Notes are filed into the same folders reminders are, so this list is the
/// whole library and the tree is a lens over it — rather than notes having a
/// second, parallel filing system of their own.

import { useMemo, useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { applyPlan } from '../../data/applyPlan'
import { useFolders, useNotes } from '../../data/hooks'
import { archivedFolderIDs, descendantIDs, pathLabel } from '../../domain/folder'
import { folderTint } from '../../domain/folder'
import { relativeDescription } from '../../domain/contact'
import { displayTitle, excerptOf, planCreateNote, planUpdateNote, type Note } from '../../domain/note'
import { Button, IconButton } from '../components/Button'
import { EmptyState } from '../components/EmptyState'
import { Icon } from '../components/Icon'
import { SegmentedControl } from '../components/SegmentedControl'
import { SkeletonRows } from '../components/Skeleton'
import { PageHeader } from '../shell/PageHeader'
import { PageScaffold } from '../shell/PageScaffold'
import { useUID } from '../UserContext'
import { FolderTree } from '../folders/FolderTree'
import { NotePage } from './NotePage'

export function NotesPage() {
  const uid = useUID()
  const navigate = useNavigate()
  const { noteID } = useParams()
  const notes = useNotes(uid)
  const folders = useFolders(uid)

  const [scope, setScope] = useState<'live' | 'archived'>('live')
  const [selectedFolder, setSelectedFolder] = useState<string | null>(null)
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set())
  const [now] = useState(() => new Date())
  const [cleanScreen, setCleanScreen] = useState(false)

  const archivedIDs = useMemo(() => archivedFolderIDs(folders ?? []), [folders])
  const foldersByID = useMemo(
    () => new Map((folders ?? []).map((folder) => [folder.id, folder])),
    [folders],
  )

  /// A note is archived when the folder it is filed in is. It has no archived
  /// flag of its own — one place to look, one place to be wrong.
  const isArchivedNote = useMemo(
    () => (note: Note) => (note.folderID ? archivedIDs.has(note.folderID) : false),
    [archivedIDs],
  )

  /// Selecting a folder includes what is inside it. A folder that hid its
  /// descendants' notes would make the tree a worse answer than the flat list
  /// it replaced — you would have to visit every child to find anything.
  const inScope = useMemo(() => {
    if (!selectedFolder || !folders) return null
    return new Set([selectedFolder, ...descendantIDs(folders, selectedFolder)])
  }, [selectedFolder, folders])

  const visible = useMemo(() => {
    if (!notes || !folders) return undefined
    return notes
      .filter((note) => (scope === 'archived' ? isArchivedNote(note) : !isArchivedNote(note)))
      .filter((note) => (inScope ? (note.folderID ? inScope.has(note.folderID) : false) : true))
      .sort((a, b) => {
        // Pinned first, then most recently edited. Pinning is a statement about
        // importance, not about time, so it outranks recency rather than
        // pretending to be a very recent edit.
        const pinned = Number(!!b.pinnedAt) - Number(!!a.pinnedAt)
        if (pinned !== 0) return pinned
        return b.updatedAt.getTime() - a.updatedAt.getTime()
      })
  }, [notes, folders, scope, inScope, isArchivedNote])

  /// Counts for the tree, over whichever scope is showing, so the numbers agree
  /// with the list beside them.
  const counts = useMemo(() => {
    const byFolder = new Map<string, number>()
    for (const note of notes ?? []) {
      if (!note.folderID) continue
      if ((scope === 'archived') !== isArchivedNote(note)) continue
      byFolder.set(note.folderID, (byFolder.get(note.folderID) ?? 0) + 1)
    }
    return byFolder
  }, [notes, scope, isArchivedNote])

  const archivedCount = useMemo(() => (notes ?? []).filter(isArchivedNote).length, [notes, isArchivedNote])
  const everythingCount = useMemo(
    () => (notes ?? []).filter((note) => (scope === 'archived') === isArchivedNote(note)).length,
    [notes, scope, isArchivedNote],
  )

  function toggleCollapsed(id: string) {
    setCollapsed((current) => {
      const next = new Set(current)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  async function create() {
    const { plan, note } = planCreateNote({ folderID: selectedFolder }, new Date())
    await applyPlan(uid, plan)
    navigate(`/notes/${note.id}`)
  }

  async function togglePin(note: Note) {
    await applyPlan(uid, planUpdateNote(note.id, { pinnedAt: note.pinnedAt ? null : new Date() }, new Date()).plan)
  }

  const selectedTitle = selectedFolder ? foldersByID.get(selectedFolder)?.title : null

  return (
    <PageScaffold width="wide">
      <PageHeader
        title="Notes"
        subtitle={
          selectedFolder && folders ? pathLabel(folders, selectedFolder) : 'Everything written down.'
        }
        actions={
          <>
            {archivedCount > 0 && (
              <SegmentedControl
                label="Live or archived"
                options={[
                  { value: 'live', label: 'Active' },
                  { value: 'archived', label: `Archived (${archivedCount})` },
                ]}
                value={scope}
                onChange={setScope}
              />
            )}
            {!noteID && scope === 'live' && (visible?.length ?? 0) > 0 && (
              <IconButton
                className="page-header-add"
                label="New note"
                icon="plus"
                size={19}
                onClick={() => void create()}
              />
            )}
          </>
        }
      />

      <div
        className="notes-layout"
        data-has-sidebar={!cleanScreen && folders && folders.length > 0 || undefined}
        data-clean-screen={cleanScreen || undefined}
      >
        {!cleanScreen && folders && folders.length > 0 && (
          <aside className="notes-sidebar">
            <FolderTree
              folders={folders.filter((folder) => (scope === 'archived') === archivedIDs.has(folder.id))}
              selected={selectedFolder}
              onSelect={setSelectedFolder}
              counts={counts}
              collapsed={collapsed}
              onToggleCollapsed={toggleCollapsed}
              everythingLabel={scope === 'archived' ? 'All archived' : 'All notes'}
              everythingCount={everythingCount}
            />
          </aside>
        )}

        <div className="notes-main">
          {noteID ? (
            <>
              <NotePage
                embedded
                focusMode={cleanScreen}
                onBack={() => {
                  setCleanScreen(false)
                  navigate('/notes')
                }}
                onToggleFocus={() => setCleanScreen((current) => !current)}
              />
            </>
          ) : (
            <>
          {visible === undefined && <SkeletonRows count={5} />}

          {visible?.length === 0 && (
            <EmptyState
              icon="note"
              headline={
                selectedTitle
                  ? `Nothing in ${selectedTitle}`
                  : scope === 'archived'
                    ? 'Nothing archived'
                    : 'Nothing written yet'
              }
              message={
                scope === 'archived'
                  ? 'Notes filed in an archived folder are kept here, and stay searchable.'
                  : 'A note can live on its own or inside a folder — the flight confirmations for a trip belong with the trip.'
              }
              action={
                scope === 'live' ? (
                  <Button variant="primary" icon="plus" onClick={() => void create()}>
                    New note
                  </Button>
                ) : undefined
              }
            />
          )}

          {visible && visible.length > 0 && (
            <div className="note-list">
              {visible.map((note) => {
                const folder = note.folderID ? foldersByID.get(note.folderID) : undefined
                const excerpt = excerptOf(note)
                return (
                  <div key={note.id} className="note-row">
                    <button type="button" className="note-row-main" onClick={() => navigate(`/notes/${note.id}`)}>
                      <span className="note-row-text">
                        <span className="row-title">
                          {note.pinnedAt && <Icon name="pin" size={12} />}
                          {displayTitle(note)}
                        </span>
                        {excerpt && <span className="row-subtitle">{excerpt}</span>}
                      </span>
                      <span className="note-row-meta">
                        {/* Only when it adds something: inside a selected
                            folder every row would carry the same chip. */}
                        {folder && !selectedFolder && (
                          <span
                            className="task-container"
                            style={{ '--tint': folderTint(folder.colorName) } as React.CSSProperties}
                          >
                            <Icon name="folder" size={13} />
                            {folder.title}
                          </span>
                        )}
                        <span className="row-trailing">{relativeDescription(note.updatedAt, now)}</span>
                      </span>
                    </button>
                    <span className="folder-row-actions">
                      <Button
                        variant="ghost"
                        small
                        icon="pin"
                        onClick={() => void togglePin(note)}
                      >
                        {note.pinnedAt ? 'Unpin' : 'Pin'}
                      </Button>
                    </span>
                  </div>
                )
              })}
            </div>
          )}
            </>
          )}
        </div>
      </div>
    </PageScaffold>
  )
}
