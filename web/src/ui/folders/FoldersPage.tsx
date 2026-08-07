/// Every folder, as a tree you can collapse.
///
/// The first version drew a flat list of every folder at every depth, always
/// expanded, with Edit and Delete buttons on each row. That reads fine with
/// three and becomes a wall with thirty — which is exactly the complaint this
/// replaces. So: branches collapse, a row carries what is in it rather than a
/// pair of buttons, and the actions moved into a menu on the row.

import { useEffect, useMemo, useRef, useState, type DragEvent } from 'react'
import { useNavigate } from 'react-router-dom'
import { applyPlan } from '../../data/applyPlan'
import { useFolders, useNotes, useReminders } from '../../data/hooks'
import {
  buildTree,
  folderTint,
  foldersInOrder,
  isArchived,
  moveRefusal,
  planCreateFolder,
  planDeleteFolder,
  planReorderFolder,
  planUnarchiveFolder,
  planUpdateFolder,
  progressOf,
  progressSentence,
  type Folder,
  type FolderColor,
  type FolderNode,
} from '../../domain/folder'
import { relativeDescription } from '../../domain/contact'
import { PALETTE_COLORS } from '../../domain/person'
import { Button, IconButton } from '../components/Button'
import { Dialog } from '../components/Dialog'
import { EmptyState } from '../components/EmptyState'
import { Icon } from '../components/Icon'
import { SegmentedControl } from '../components/SegmentedControl'
import { SkeletonRows } from '../components/Skeleton'
import { PageHeader } from '../shell/PageHeader'
import { PageScaffold } from '../shell/PageScaffold'
import { useUID } from '../UserContext'
import { FolderSheet } from './FolderSheet'

export function FoldersPage() {
  const uid = useUID()
  const navigate = useNavigate()
  const folders = useFolders(uid)
  const reminders = useReminders(uid)
  const notes = useNotes(uid)

  const [view, setView] = useState<'live' | 'archived'>('live')
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set())
  const [editing, setEditing] = useState<Folder | null>(null)
  const [deleting, setDeleting] = useState<Folder | null>(null)
  const [coloring, setColoring] = useState<Folder | null>(null)
  const colorControlRef = useRef<HTMLDivElement>(null)
  const [draggingID, setDraggingID] = useState<string | null>(null)
  const [dragOver, setDragOver] = useState<{ id: string; position: 'before' | 'inside' | 'after' } | null>(null)

  /// The tree is built from live folders only. Building it whole and hiding the
  /// archived rows would leave a live folder indented under a parent that is
  /// not drawn, and the indent would point at nothing.
  const tree = useMemo(
    () => (folders ? buildTree(folders.filter((folder) => !isArchived(folder))) : undefined),
    [folders],
  )

  const archivedRows = useMemo(
    () =>
      folders
        ? folders.filter(isArchived).sort((a, b) => (b.archivedAt?.getTime() ?? 0) - (a.archivedAt?.getTime() ?? 0))
        : undefined,
    [folders],
  )

  /// One pass rather than a filter per row: the page draws every folder and
  /// would otherwise walk both collections once each per row.
  const contents = useMemo(() => {
    const byFolder = new Map<string, { reminders: Array<{ status: 'open' | 'completed' }>; notes: number }>()
    const entry = (id: string) => {
      const found = byFolder.get(id) ?? { reminders: [], notes: 0 }
      byFolder.set(id, found)
      return found
    }
    for (const reminder of reminders ?? []) {
      if (reminder.folderID) entry(reminder.folderID).reminders.push({ status: reminder.status })
    }
    for (const note of notes ?? []) {
      if (note.folderID) entry(note.folderID).notes += 1
    }
    return byFolder
  }, [reminders, notes])

  function toggle(id: string) {
    setCollapsed((current) => {
      const next = new Set(current)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  async function confirmDelete(subject: Folder) {
    await applyPlan(
      uid,
      planDeleteFolder(
        subject,
        {
          childFolders: (folders ?? []).filter((folder) => folder.parentID === subject.id),
          reminderIDs: (reminders ?? []).filter((r) => r.folderID === subject.id).map((r) => r.id),
          noteIDs: (notes ?? []).filter((n) => n.folderID === subject.id).map((n) => n.id),
        },
        new Date(),
      ).plan,
    )
    setDeleting(null)
  }

  async function createFolder(parentID: string | null) {
    const siblings = (folders ?? []).filter((folder) => folder.parentID === parentID)
    const usedTitles = new Set(siblings.map((folder) => folder.title))
    let title = 'New folder'
    let suffix = 2
    while (usedTitles.has(title)) {
      title = `New folder ${suffix}`
      suffix += 1
    }

    const { plan } = planCreateFolder({ title, parentID }, new Date())
    await applyPlan(uid, plan)
  }

  useEffect(() => {
    if (!coloring) return
    const dismiss = (event: PointerEvent) => {
      if (!colorControlRef.current?.contains(event.target as Node)) setColoring(null)
    }
    document.addEventListener('pointerdown', dismiss)
    return () => document.removeEventListener('pointerdown', dismiss)
  }, [coloring])

  async function changeColor(colorName: FolderColor) {
    if (!coloring) return
    await applyPlan(uid, planUpdateFolder(coloring.id, { colorName }, new Date()).plan)
    setColoring(null)
  }

  function positionFor(event: DragEvent<HTMLDivElement>): 'before' | 'inside' | 'after' {
    const bounds = event.currentTarget.getBoundingClientRect()
    const ratio = (event.clientY - bounds.top) / bounds.height
    if (ratio < 0.28) return 'before'
    if (ratio > 0.72) return 'after'
    return 'inside'
  }

  function canDrop(subject: Folder, target: Folder, position: 'before' | 'inside' | 'after'): boolean {
    const newParentID = position === 'inside' ? target.id : target.parentID
    if (subject.id === target.id) return false
    return moveRefusal(folders ?? [], subject, newParentID) === null
  }

  async function dropOn(target: Folder, position: 'before' | 'inside' | 'after') {
    const subject = (folders ?? []).find((folder) => folder.id === draggingID)
    if (!subject || !canDrop(subject, target, position)) return

    const newParentID = position === 'inside' ? target.id : target.parentID
    let beforeID: string | null = null
    if (position === 'before') {
      beforeID = target.id
    } else if (position === 'after') {
      const siblings = foldersInOrder(folders ?? [], newParentID).filter((folder) => folder.id !== subject.id)
      const targetIndex = siblings.findIndex((folder) => folder.id === target.id)
      beforeID = siblings[targetIndex + 1]?.id ?? null
    }

    await applyPlan(uid, planReorderFolder(folders ?? [], subject, newParentID, beforeID, new Date()).plan)
    setDraggingID(null)
    setDragOver(null)
  }

  async function dropAtRoot() {
    const subject = (folders ?? []).find((folder) => folder.id === draggingID)
    if (!subject) return
    await applyPlan(uid, planReorderFolder(folders ?? [], subject, null, null, new Date()).plan)
    setDraggingID(null)
    setDragOver(null)
  }

  /// What a folder holds, in words. A trip says how far along it is; a plain
  /// folder says what is in it; an empty one says nothing at all rather than
  /// "0 notes, 0 reminders" on every row.
  function summaryOf(folder: Folder): string | null {
    const held = contents.get(folder.id)
    if (!held) return null
    if (held.reminders.length > 0) {
      const progress = progressSentence(progressOf(held.reminders))
      return held.notes > 0 ? `${progress} · ${held.notes} note${held.notes === 1 ? '' : 's'}` : progress
    }
    if (held.notes > 0) return `${held.notes} note${held.notes === 1 ? '' : 's'}`
    return null
  }

  const renderNode = (node: FolderNode): React.ReactNode => {
    const isCollapsed = collapsed.has(node.folder.id)
    const summary = summaryOf(node.folder)
    return (
      <div key={node.folder.id}>
        <div
          className="folder-row"
          style={{ '--depth': node.depth } as React.CSSProperties}
          data-reorderable
          draggable
          aria-describedby="folder-drag-help"
          data-drop-position={dragOver?.id === node.folder.id ? dragOver.position : undefined}
          data-drag-source={draggingID === node.folder.id || undefined}
          onDragStart={(event) => {
            event.dataTransfer.effectAllowed = 'move'
            event.dataTransfer.setData('text/plain', node.folder.id)
            setDraggingID(node.folder.id)
          }}
          onDragEnd={() => {
            setDraggingID(null)
            setDragOver(null)
          }}
          onDragOver={(event) => {
            const subject = (folders ?? []).find((folder) => folder.id === draggingID)
            if (!subject) return
            const position = positionFor(event)
            if (!canDrop(subject, node.folder, position)) return
            event.preventDefault()
            event.stopPropagation()
            event.dataTransfer.dropEffect = 'move'
            setDragOver({ id: node.folder.id, position })
          }}
          onDragLeave={(event) => {
            if (!event.currentTarget.contains(event.relatedTarget as Node | null)) setDragOver(null)
          }}
          onDrop={(event) => {
            event.preventDefault()
            event.stopPropagation()
            const position = positionFor(event)
            void dropOn(node.folder, position)
          }}
        >
          <button
            type="button"
            className="folder-drag-handle"
            aria-label={`Move ${node.folder.title}`}
          >
            <span aria-hidden="true">⠿</span>
          </button>
          {node.children.length > 0 ? (
            <button
              type="button"
              className="folder-tree-twisty"
              aria-label={isCollapsed ? `Expand ${node.folder.title}` : `Collapse ${node.folder.title}`}
              aria-expanded={!isCollapsed}
              onClick={() => toggle(node.folder.id)}
            >
              <Icon name={isCollapsed ? 'chevron-right' : 'chevron-down'} size={12} />
            </button>
          ) : (
            <span className="folder-tree-twisty" aria-hidden="true" />
          )}

          <div
            className="folder-color-control"
            ref={coloring?.id === node.folder.id ? colorControlRef : undefined}
            onKeyDown={(event) => {
              if (event.key !== 'Escape' || coloring?.id !== node.folder.id) return
              event.stopPropagation()
              setColoring(null)
            }}
          >
            <button
              type="button"
              className="folder-picker-glyph folder-color-button"
              style={{ '--tint': folderTint(node.folder.colorName) } as React.CSSProperties}
              aria-label={`Change color for ${node.folder.title}`}
              aria-haspopup="dialog"
              aria-expanded={coloring?.id === node.folder.id}
              onClick={() => setColoring((current) => current?.id === node.folder.id ? null : node.folder)}
            >
              <Icon name="folder" size={15} />
            </button>
            {coloring?.id === node.folder.id && (
              <div className="folder-color-popover" role="dialog" aria-label={`Color for ${node.folder.title}`}>
                <div className="color-choices folder-color-choices">
                  {PALETTE_COLORS.map((color) => (
                    <button
                      key={color}
                      type="button"
                      className="color-choice"
                      style={{ '--tint': folderTint(color) } as React.CSSProperties}
                      data-selected={color === coloring.colorName || undefined}
                      aria-label={`Set ${color} color`}
                      aria-pressed={color === coloring.colorName}
                      onClick={() => void changeColor(color)}
                    />
                  ))}
                  <label
                    className="color-choice color-choice-custom"
                    data-selected={coloring.colorName.startsWith('#') || undefined}
                    title="Custom color"
                  >
                    <input
                      type="color"
                      aria-label="Choose custom folder color"
                      value={coloring.colorName.startsWith('#') ? coloring.colorName : '#4168c6'}
                      onChange={(event) => void changeColor(event.target.value as FolderColor)}
                    />
                  </label>
                </div>
              </div>
            )}
          </div>

          <button type="button" className="folder-row-main" onClick={() => navigate(`/folders/${node.folder.id}`)}>
            <span className="folder-row-text">
              <span className="row-title">{node.folder.title}</span>
              {node.folder.summary && <span className="row-subtitle">{node.folder.summary}</span>}
            </span>
            {summary && <span className="row-trailing">{summary}</span>}
          </button>

          <span className="folder-row-actions">
            <Button
              variant="ghost"
              small
              icon="plus"
              aria-label={`New folder inside ${node.folder.title}`}
              onClick={() => void createFolder(node.folder.id)}
            >
              Inside
            </Button>
            <Button variant="ghost" small icon="pencil" onClick={() => setEditing(node.folder)}>
              Rename
            </Button>
            <Button variant="ghost" small icon="trash" onClick={() => setDeleting(node.folder)}>
              Delete
            </Button>
          </span>
        </div>
        {!isCollapsed && node.children.map(renderNode)}
      </div>
    )
  }

  return (
    <PageScaffold width="wide">
      <PageHeader
        title="Folders"
        subtitle="Everything you keep, and the trips that end."
        actions={
          <>
            {(archivedRows?.length ?? 0) > 0 && (
              <SegmentedControl
                label="Live or archived"
                options={[
                  { value: 'live', label: 'Active' },
                  { value: 'archived', label: `Archived (${archivedRows?.length ?? 0})` },
                ]}
                value={view}
                onChange={setView}
              />
            )}
            {(view === 'archived' || (tree?.length ?? 0) > 0) && (
              <IconButton
                className="page-header-add"
                label="New folder"
                icon="plus"
                size={19}
                onClick={() => void createFolder(null)}
              />
            )}
          </>
        }
      />

      {tree === undefined && <SkeletonRows count={4} />}

      {view === 'live' && tree?.length === 0 && (
        <EmptyState
          icon="folder"
          headline="Nothing filed yet"
          message="A folder holds notes and reminders, and folders hold folders. Give one dates and it becomes a trip you can archive when it is over."
          action={
            <Button variant="primary" icon="plus" onClick={() => void createFolder(null)}>
              New folder
            </Button>
          }
        />
      )}

      {view === 'live' && tree && tree.length > 0 && (
        <>
          <p id="folder-drag-help" className="visually-hidden">
            Drag above or below another folder to sort it. Drop on the middle to put it inside that folder.
          </p>
          <div
            className="folder-list"
            data-dragging={draggingID || undefined}
            onDragOver={(event) => {
              if (!draggingID || event.target !== event.currentTarget) return
              event.preventDefault()
              event.dataTransfer.dropEffect = 'move'
            }}
            onDrop={(event) => {
              if (event.target !== event.currentTarget) return
              event.preventDefault()
              void dropAtRoot()
            }}
          >
            {tree.map(renderNode)}
            {draggingID && (
              <div
                className="folder-root-drop"
                onDragOver={(event) => {
                  event.preventDefault()
                  event.dataTransfer.dropEffect = 'move'
                }}
                onDrop={(event) => {
                  event.preventDefault()
                  event.stopPropagation()
                  void dropAtRoot()
                }}
              >
                Move to top level
              </div>
            )}
          </div>
        </>
      )}

      {view === 'archived' && archivedRows && (
        <div className="folder-list">
          {archivedRows.map((folder) => (
            <div key={folder.id} className="folder-row">
              <span className="folder-tree-twisty" aria-hidden="true" />
              <button type="button" className="folder-row-main" onClick={() => navigate(`/folders/${folder.id}`)}>
                <span
                  className="folder-picker-glyph"
                  style={{ '--tint': folderTint(folder.colorName) } as React.CSSProperties}
                >
                  <Icon name="folder" size={15} />
                </span>
                <span className="folder-row-text">
                  <span className="row-title">{folder.title}</span>
                  {summaryOf(folder) && <span className="row-subtitle">{summaryOf(folder)}</span>}
                </span>
                {folder.archivedAt && (
                  <span className="row-trailing">Archived {relativeDescription(folder.archivedAt, new Date())}</span>
                )}
              </button>
              <span className="folder-row-actions">
                <Button
                  variant="ghost"
                  small
                  icon="archive"
                  onClick={() =>
                    void applyPlan(uid, planUnarchiveFolder(folders ?? [], folder, new Date()).plan)
                  }
                >
                  Unarchive
                </Button>
              </span>
            </div>
          ))}
        </div>
      )}

      {editing && folders && (
        <FolderSheet
          existing={editing}
          folders={folders}
          onClose={() => {
            setEditing(null)
          }}
        />
      )}

      {deleting && (
        <Dialog title={`Delete ${deleting.title}?`} onClose={() => setDeleting(null)}>
          <p className="row-subtitle">
            Nothing inside it is deleted. Folders it holds move up a level, and its notes and reminders go back
            to being unfiled — you will find them in Notes and Follow-ups.
          </p>
          <div className="sheet-actions">
            <Button variant="quiet" onClick={() => setDeleting(null)}>
              Cancel
            </Button>
            <Button variant="destructive" onClick={() => void confirmDelete(deleting)}>
              Delete
            </Button>
          </div>
        </Dialog>
      )}
    </PageScaffold>
  )
}
