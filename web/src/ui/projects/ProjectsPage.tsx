/// The tree of projects and folders, in reading order with its own indents.
///
/// Deliberately one flat list rather than nested `<ul>`s: the rows all want the
/// same hit area, the same trailing metadata column and the same keyboard
/// order, and a nested list gives none of those for free. Depth is a number the
/// row draws with, which is what `flattenTree` exists to supply.

import { useMemo, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { applyPlan } from '../../data/applyPlan'
import { useContainers, useReminders } from '../../data/hooks'
import {
  buildTree,
  flattenTree,
  planDeleteContainer,
  progressOf,
  progressSentence,
  type Container,
} from '../../domain/container'
import { Button } from '../components/Button'
import { Dialog } from '../components/Dialog'
import { EmptyState } from '../components/EmptyState'
import { Icon } from '../components/Icon'
import { SkeletonRows } from '../components/Skeleton'
import { PageHeader } from '../shell/PageHeader'
import { PageScaffold } from '../shell/PageScaffold'
import { useUID } from '../UserContext'
import { ContainerSheet } from './ContainerSheet'

export function ProjectsPage() {
  const uid = useUID()
  const navigate = useNavigate()
  const containers = useContainers(uid)
  const reminders = useReminders(uid)

  const [creating, setCreating] = useState(false)
  const [editing, setEditing] = useState<Container | null>(null)
  const [deleting, setDeleting] = useState<Container | null>(null)

  const rows = useMemo(() => (containers ? flattenTree(buildTree(containers)) : undefined), [containers])

  /// One pass over the reminders rather than a filter per row — the page draws
  /// a dozen containers and would otherwise walk the whole collection a dozen
  /// times.
  const progressByContainer = useMemo(() => {
    const grouped = new Map<string, Array<{ status: 'open' | 'completed' }>>()
    for (const reminder of reminders ?? []) {
      if (!reminder.containerID) continue
      const list = grouped.get(reminder.containerID) ?? []
      list.push({ status: reminder.status })
      grouped.set(reminder.containerID, list)
    }
    return new Map([...grouped].map(([id, list]) => [id, progressOf(list)]))
  }, [reminders])

  async function confirmDelete(subject: Container) {
    const childContainers = (containers ?? []).filter((container) => container.parentID === subject.id)
    const reminderIDs = (reminders ?? [])
      .filter((reminder) => reminder.containerID === subject.id)
      .map((reminder) => reminder.id)
    await applyPlan(uid, planDeleteContainer(subject, { childContainers, reminderIDs }, new Date()).plan)
    setDeleting(null)
  }

  return (
    <PageScaffold width="wide">
      <PageHeader
        title="Projects"
        subtitle="Things that end, and the folders they sit in."
        actions={
          <Button variant="primary" icon="plus" onClick={() => setCreating(true)}>
            New
          </Button>
        }
      />

      {rows === undefined && <SkeletonRows count={4} />}

      {rows?.length === 0 && (
        <EmptyState
          icon="project"
          headline="Nothing filed yet"
          message="A project is something that ends — a trip, a move, a launch — and can be archived when it is over. A folder is somewhere to keep them."
          action={
            <Button variant="primary" icon="plus" onClick={() => setCreating(true)}>
              New project
            </Button>
          }
          hint="Travel is a folder. Chicago, October is a project inside it."
        />
      )}

      {rows && rows.length > 0 && (
        <div className="container-tree">
          {rows.map(({ container, depth }) => {
            const progress = progressByContainer.get(container.id)
            return (
              <div
                key={container.id}
                className="container-row"
                style={{ '--depth': depth } as React.CSSProperties}
                data-kind={container.kind}
              >
                <button
                  type="button"
                  className="container-main"
                  onClick={() => navigate(`/projects/${container.id}`)}
                >
                  <span
                    className="container-glyph"
                    style={{ '--tint': `var(--palette-${container.colorName})` } as React.CSSProperties}
                  >
                    <Icon name={container.kind === 'folder' ? 'folder' : 'project'} size={17} />
                  </span>
                  <span className="container-text">
                    <span className="row-title">{container.title}</span>
                    {container.summary && <span className="row-subtitle">{container.summary}</span>}
                  </span>
                  {container.kind === 'project' && (
                    <span className="row-trailing">
                      {progressSentence(progress ?? { done: 0, total: 0 })}
                    </span>
                  )}
                </button>
                <span className="container-actions">
                  <Button variant="ghost" small icon="pencil" onClick={() => setEditing(container)}>
                    Edit
                  </Button>
                  <Button variant="ghost" small icon="trash" onClick={() => setDeleting(container)}>
                    Delete
                  </Button>
                </span>
              </div>
            )
          })}
        </div>
      )}

      {(creating || editing) && containers && (
        <ContainerSheet
          existing={editing}
          containers={containers}
          onClose={() => {
            setCreating(false)
            setEditing(null)
          }}
        />
      )}

      {deleting && (
        <Dialog title={`Delete ${deleting.title}?`} onClose={() => setDeleting(null)}>
          <p className="row-subtitle">
            Nothing inside it is deleted. Anything it holds moves up a level, and its reminders go back to
            being unfiled — you will find them in Follow-ups.
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
