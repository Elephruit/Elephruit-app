/// Every note, newest edit first, with a filter down the side.
///
/// Notes are filed the same way reminders are — into the same containers — so
/// this list is the whole library and the container filter is a lens over it,
/// rather than notes having a second, parallel filing system of their own. That
/// was the point of making a folder and a project one shape.

import { useMemo, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { applyPlan } from '../../data/applyPlan'
import { useContainers, useNotes } from '../../data/hooks'
import { archivedContainerIDs, buildTree, flattenTree, pathLabel } from '../../domain/container'
import { relativeDescription } from '../../domain/contact'
import { displayTitle, excerptOf, planCreateNote, planUpdateNote, type Note } from '../../domain/note'
import { Button } from '../components/Button'
import { EmptyState } from '../components/EmptyState'
import { Icon } from '../components/Icon'
import { SegmentedControl } from '../components/SegmentedControl'
import { SkeletonRows } from '../components/Skeleton'
import { PageHeader } from '../shell/PageHeader'
import { PageScaffold } from '../shell/PageScaffold'
import { useUID } from '../UserContext'

export function NotesPage() {
  const uid = useUID()
  const navigate = useNavigate()
  const notes = useNotes(uid)
  const containers = useContainers(uid)

  const [scope, setScope] = useState<'live' | 'archived'>('live')
  const [filter, setFilter] = useState<string>('')
  const [now] = useState(() => new Date())

  const archivedIDs = useMemo(() => archivedContainerIDs(containers ?? []), [containers])
  const containersByID = useMemo(
    () => new Map((containers ?? []).map((container) => [container.id, container])),
    [containers],
  )

  /// A note is archived when the thing it is filed in is. It has no archived
  /// flag of its own — one place to look, one place to be wrong. Same rule the
  /// reminders follow.
  const isArchivedNote = (note: Note) => (note.containerID ? archivedIDs.has(note.containerID) : false)

  const rows = useMemo(() => {
    if (!notes || !containers) return undefined
    return notes
      .filter((note) => (scope === 'archived' ? isArchivedNote(note) : !isArchivedNote(note)))
      .filter((note) => (filter ? note.containerID === filter : true))
      .sort((a, b) => {
        // Pinned first, then most recently edited. Pinning is a statement about
        // importance, not about time, so it outranks recency rather than
        // pretending to be a very recent edit.
        const pinned = Number(!!b.pinnedAt) - Number(!!a.pinnedAt)
        if (pinned !== 0) return pinned
        return b.updatedAt.getTime() - a.updatedAt.getTime()
      })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [notes, containers, scope, filter, archivedIDs])

  const archivedCount = useMemo(
    () => (notes ?? []).filter(isArchivedNote).length,
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [notes, archivedIDs],
  )

  async function create() {
    const { plan, note } = planCreateNote({ containerID: filter || null }, new Date())
    await applyPlan(uid, plan)
    navigate(`/notes/${note.id}`)
  }

  async function togglePin(note: Note) {
    await applyPlan(uid, planUpdateNote(note.id, { pinnedAt: note.pinnedAt ? null : new Date() }, new Date()).plan)
  }

  return (
    <PageScaffold width="wide">
      <PageHeader
        title="Notes"
        subtitle="Everything written down."
        actions={
          <>
            {containers && containers.length > 0 && (
              <select
                className="field field-inline"
                aria-label="Filter by project or folder"
                value={filter}
                onChange={(event) => setFilter(event.target.value)}
              >
                <option value="">Everywhere</option>
                {flattenTree(buildTree(containers)).map((node) => (
                  <option key={node.container.id} value={node.container.id}>
                    {pathLabel(containers, node.container.id)}
                  </option>
                ))}
              </select>
            )}
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
            <Button variant="primary" icon="plus" onClick={() => void create()}>
              New note
            </Button>
          </>
        }
      />

      {rows === undefined && <SkeletonRows count={5} />}

      {rows?.length === 0 && (
        <EmptyState
          icon="note"
          headline={scope === 'archived' ? 'Nothing archived' : 'Nothing written yet'}
          message={
            scope === 'archived'
              ? 'Notes filed in an archived project are kept here, and stay searchable.'
              : 'A note can live on its own or inside a project — the flight confirmations for a trip belong with the trip.'
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

      {rows && rows.length > 0 && (
        <div className="note-list">
          {rows.map((note) => {
            const container = note.containerID ? containersByID.get(note.containerID) : undefined
            const excerpt = excerptOf(note)
            return (
              <div key={note.id} className="note-row">
                <button type="button" className="note-row-main" onClick={() => navigate(`/notes/${note.id}`)}>
                  <span className="note-row-text">
                    <span className="row-title">{displayTitle(note)}</span>
                    {excerpt && <span className="row-subtitle">{excerpt}</span>}
                  </span>
                  <span className="note-row-meta">
                    {container && (
                      <span
                        className="task-container"
                        style={{ '--tint': `var(--palette-${container.colorName})` } as React.CSSProperties}
                      >
                        <Icon name={container.kind === 'folder' ? 'folder' : 'project'} size={13} />
                        {container.title}
                      </span>
                    )}
                    <span className="row-trailing">{relativeDescription(note.updatedAt, now)}</span>
                  </span>
                </button>
                <span className="container-actions">
                  <Button
                    variant="ghost"
                    small
                    icon={note.pinnedAt ? 'check' : 'heart'}
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
    </PageScaffold>
  )
}
