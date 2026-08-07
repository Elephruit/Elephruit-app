/// Every folder, as a tree you can collapse.
///
/// The first version drew a flat list of every folder at every depth, always
/// expanded, with Edit and Delete buttons on each row. That reads fine with
/// three and becomes a wall with thirty — which is exactly the complaint this
/// replaces. So: branches collapse, a row carries what is in it rather than a
/// pair of buttons, and the actions moved into a menu on the row.

import { useMemo, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { applyPlan } from '../../data/applyPlan'
import { useFolders, useNotes, useReminders } from '../../data/hooks'
import {
  buildTree,
  isArchived,
  planCreateFolder,
  planDeleteFolder,
  planUnarchiveFolder,
  progressOf,
  progressSentence,
  type Folder,
  type FolderNode,
} from '../../domain/folder'
import { relativeDescription } from '../../domain/contact'
import { Button } from '../components/Button'
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
        <div className="folder-row" style={{ '--depth': node.depth } as React.CSSProperties}>
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

          <button type="button" className="folder-row-main" onClick={() => navigate(`/folders/${node.folder.id}`)}>
            <span
              className="folder-picker-glyph"
              style={{ '--tint': `var(--palette-${node.folder.colorName})` } as React.CSSProperties}
            >
              <Icon name="folder" size={15} />
            </span>
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
              <Button variant="primary" icon="plus" onClick={() => void createFolder(null)}>
                New folder
              </Button>
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

      {view === 'live' && tree && tree.length > 0 && <div className="folder-list">{tree.map(renderNode)}</div>}

      {view === 'archived' && archivedRows && (
        <div className="folder-list">
          {archivedRows.map((folder) => (
            <div key={folder.id} className="folder-row">
              <span className="folder-tree-twisty" aria-hidden="true" />
              <button type="button" className="folder-row-main" onClick={() => navigate(`/folders/${folder.id}`)}>
                <span
                  className="folder-picker-glyph"
                  style={{ '--tint': `var(--palette-${folder.colorName})` } as React.CSSProperties}
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
