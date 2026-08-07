/// One project or folder: what it holds, and nothing it does not.
///
/// The reminders are drawn with the same five buckets Follow-ups uses, from the
/// same `sections()` — a trip's work is not a different kind of work, and a
/// second bucketing rule would be a second place for the deadline-versus-start
/// distinction to go wrong.

import { useMemo, useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { applyPlan } from '../../data/applyPlan'
import { useContainer, useContainers, usePeople, useRemindersIn } from '../../data/hooks'
import { planCompleteReminder, planReopenReminder } from '../../domain/capture'
import { buildTree, pathTo, progressOf, progressSentence, type Container } from '../../domain/container'
import { relativeDescription } from '../../domain/contact'
import { BUCKET_TITLES, bucketFor, completedList, sections, type Reminder } from '../../domain/reminders'
import { formatScheduleSummary } from '../../domain/temporal'
import { Avatar } from '../components/Avatar'
import { Button } from '../components/Button'
import { EmptyState } from '../components/EmptyState'
import { Icon } from '../components/Icon'
import { SkeletonRows } from '../components/Skeleton'
import { FollowUpSheet } from '../followups/FollowUpSheet'
import { PageHeader } from '../shell/PageHeader'
import { PageScaffold } from '../shell/PageScaffold'
import { useUID } from '../UserContext'
import { ContainerSheet } from './ContainerSheet'

/// The one date line a project shows. Descriptive, never a verdict — a trip
/// that has started is not late, and a trip that has ended is not a failure.
function dateLine(container: Container, now: Date): string | null {
  const format = (date: Date) =>
    date.toLocaleDateString(undefined, { month: 'long', day: 'numeric', year: 'numeric' })

  if (container.startAt && container.dueAt) return `${format(container.startAt)} – ${format(container.dueAt)}`
  if (container.dueAt) return `Ends ${format(container.dueAt)} · ${relativeDescription(container.dueAt, now)}`
  if (container.startAt) return `Starts ${format(container.startAt)}`
  return null
}

export function ContainerPage() {
  const uid = useUID()
  const navigate = useNavigate()
  const { containerID = '' } = useParams()
  const container = useContainer(uid, containerID)
  const containers = useContainers(uid)
  const reminders = useRemindersIn(uid, containerID)
  const people = usePeople(uid)

  const [editing, setEditing] = useState(false)
  const [creatingReminder, setCreatingReminder] = useState(false)
  const [editingReminder, setEditingReminder] = useState<Reminder | null>(null)
  const [now] = useState(() => new Date())

  const groups = useMemo(() => (reminders ? sections(reminders, now) : undefined), [reminders, now])
  const done = useMemo(() => (reminders ? completedList(reminders) : []), [reminders])
  const progress = useMemo(() => progressOf(reminders ?? []), [reminders])
  const peopleByID = useMemo(() => new Map((people ?? []).map((person) => [person.id, person])), [people])

  const trail = useMemo(
    () => (containers && container ? pathTo(containers, container.id).slice(0, -1) : []),
    [containers, container],
  )
  const children = useMemo(
    () =>
      containers && container
        ? buildTree(containers).flatMap(function find(node): Container[] {
            if (node.container.id === container.id) return node.children.map((child) => child.container)
            return node.children.flatMap(find)
          })
        : [],
    [containers, container],
  )

  if (container === undefined) {
    return (
      <PageScaffold width="wide">
        <SkeletonRows count={4} />
      </PageScaffold>
    )
  }

  if (container === null) {
    return (
      <PageScaffold width="wide">
        <EmptyState
          icon="folder"
          headline="Not here"
          message="This project or folder has been deleted."
          action={
            <Button variant="primary" onClick={() => navigate('/projects')}>
              Back to Projects
            </Button>
          }
        />
      </PageScaffold>
    )
  }

  const line = dateLine(container, now)

  return (
    <PageScaffold width="wide">
      <PageHeader
        title={
          <span className="container-title-row">
            <span
              className="container-glyph"
              style={{ '--tint': `var(--palette-${container.colorName})` } as React.CSSProperties}
            >
              <Icon name={container.kind === 'folder' ? 'folder' : 'project'} size={19} />
            </span>
            {container.title}
          </span>
        }
        subtitle={
          <span className="container-meta">
            {trail.map((ancestor) => (
              <button
                key={ancestor.id}
                type="button"
                className="link-button"
                onClick={() => navigate(`/projects/${ancestor.id}`)}
              >
                {ancestor.title}
              </button>
            ))}
            {container.summary && <span>{container.summary}</span>}
            {line && <span>{line}</span>}
            {container.kind === 'project' && <span>{progressSentence(progress)}</span>}
          </span>
        }
        actions={
          <>
            <Button variant="quiet" icon="pencil" onClick={() => setEditing(true)}>
              Edit
            </Button>
            <Button variant="primary" icon="plus" onClick={() => setCreatingReminder(true)}>
              New reminder
            </Button>
          </>
        }
      />

      {children.length > 0 && (
        <section>
          <h2 className="section-header">Inside</h2>
          <div className="container-tree">
            {children.map((child) => (
              <div key={child.id} className="container-row" data-kind={child.kind}>
                <button
                  type="button"
                  className="container-main"
                  onClick={() => navigate(`/projects/${child.id}`)}
                >
                  <span
                    className="container-glyph"
                    style={{ '--tint': `var(--palette-${child.colorName})` } as React.CSSProperties}
                  >
                    <Icon name={child.kind === 'folder' ? 'folder' : 'project'} size={17} />
                  </span>
                  <span className="container-text">
                    <span className="row-title">{child.title}</span>
                    {child.summary && <span className="row-subtitle">{child.summary}</span>}
                  </span>
                </button>
              </div>
            ))}
          </div>
        </section>
      )}

      {groups === undefined && <SkeletonRows count={3} />}

      {groups?.length === 0 && done.length === 0 && (
        <EmptyState
          icon="bell"
          headline="Nothing to do yet"
          message="Reminders filed here show up in Follow-ups too — this is the same work, seen from the trip rather than from the day."
          action={
            <Button variant="primary" icon="plus" onClick={() => setCreatingReminder(true)}>
              New reminder
            </Button>
          }
        />
      )}

      {groups?.map((group) => (
        <section key={group.bucket}>
          <h2 className="section-header" data-tone={group.bucket === 'overdue' ? 'overdue' : undefined}>
            {BUCKET_TITLES[group.bucket]}
          </h2>
          {group.reminders.map((reminder) => {
            const schedule = reminder.isSomeday ? null : formatScheduleSummary(reminder)
            const bucket = bucketFor(reminder, now)
            return (
              <div key={reminder.id} className="task-row">
                <button
                  type="button"
                  className="complete-ring"
                  aria-label={`Complete ${reminder.title}`}
                  onClick={() => void applyPlan(uid, planCompleteReminder(reminder.id, new Date()).plan)}
                />
                <button type="button" className="task-main" onClick={() => setEditingReminder(reminder)}>
                  <span className="row-title">{reminder.title}</span>
                  <span className="task-meta">
                    {schedule && (
                      <span
                        className={
                          bucket === 'overdue'
                            ? 'chip chip-status-overdue'
                            : bucket === 'today'
                              ? 'chip chip-status-today'
                              : 'chip'
                        }
                      >
                        {schedule}
                      </span>
                    )}
                    {reminder.personIDs.map((id) => {
                      const person = peopleByID.get(id)
                      if (!person) return null
                      return (
                        <span key={id} className="task-person">
                          <Avatar name={person.displayName} colorName={person.colorName} small />
                          {person.displayName}
                        </span>
                      )
                    })}
                  </span>
                </button>
              </div>
            )
          })}
        </section>
      ))}

      {done.length > 0 && (
        <section>
          <h2 className="section-header">Done</h2>
          {done.map((reminder) => (
            <div key={reminder.id} className="task-row task-row-done">
              <button
                type="button"
                className="button button-plain"
                style={{ padding: 0, color: 'var(--color-completed)', height: 'auto' }}
                aria-label={`Reopen ${reminder.title}`}
                onClick={() => void applyPlan(uid, planReopenReminder(reminder.id).plan)}
              >
                <Icon name="check-circle" size={20} />
              </button>
              <span className="row-title">{reminder.title}</span>
              {reminder.completedAt && (
                <span className="row-trailing">{relativeDescription(reminder.completedAt, now)}</span>
              )}
            </div>
          ))}
        </section>
      )}

      {editing && containers && (
        <ContainerSheet existing={container} containers={containers} onClose={() => setEditing(false)} />
      )}

      {(creatingReminder || editingReminder) && people && (
        <FollowUpSheet
          existing={editingReminder}
          people={people}
          containers={containers ?? []}
          defaultContainerID={container.id}
          onClose={() => {
            setCreatingReminder(false)
            setEditingReminder(null)
          }}
        />
      )}
    </PageScaffold>
  )
}
