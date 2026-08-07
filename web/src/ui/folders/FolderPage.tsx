/// One folder: what it holds, and nothing it does not.
///
/// The reminders are drawn with the same five buckets Follow-ups uses, from the
/// same `sections()` — a trip's work is not a different kind of work, and a
/// second bucketing rule would be a second place for the deadline-versus-start
/// distinction to go wrong.

import { useMemo, useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { applyPlan } from '../../data/applyPlan'
import { useFolder, useFolders, useNotes, usePeople, useRemindersIn } from '../../data/hooks'
import {
  planCompleteReminder,
  planQuickReschedule,
  planReopenReminder,
  planUpdateReminder,
} from '../../domain/capture'
import {
  descendantIDs,
  isArchived,
  leftOpen,
  pathTo,
  planArchiveFolder,
  planCreateFolder,
  planUnarchiveFolder,
  progressOf,
  progressSentence,
  folderTint,
  type Folder,
} from '../../domain/folder'
import { relativeDescription } from '../../domain/contact'
import { startOfDay } from '../../domain/dates'
import { displayTitle, excerptOf, planCreateNote } from '../../domain/note'
import { BUCKET_TITLES, completedList, sections, type Reminder } from '../../domain/reminders'
import { uniqueCategoryTags } from '../../domain/categoryTags'
import { Button } from '../components/Button'
import { Dialog } from '../components/Dialog'
import { EmptyState } from '../components/EmptyState'
import { Icon } from '../components/Icon'
import { SkeletonRows } from '../components/Skeleton'
import { DEFAULT_FOLLOWUP_CATEGORIES } from '../followups/categoryStyle'
import { FollowUpRow } from '../followups/FollowUpRow'
import { InlineFollowUpComposer } from '../followups/InlineFollowUpComposer'
import { PageHeader } from '../shell/PageHeader'
import { PageScaffold } from '../shell/PageScaffold'
import { useUID } from '../UserContext'
import { FolderSheet } from './FolderSheet'

/// The one date line a folder shows. Descriptive, never a verdict — a trip that
/// has started is not late, and one that has ended is not a failure.
function dateLine(folder: Folder, now: Date): string | null {
  const format = (date: Date) =>
    date.toLocaleDateString(undefined, { month: 'long', day: 'numeric', year: 'numeric' })

  if (folder.startAt && folder.dueAt) return `${format(folder.startAt)} – ${format(folder.dueAt)}`
  if (folder.dueAt) return `Ends ${format(folder.dueAt)} · ${relativeDescription(folder.dueAt, now)}`
  if (folder.startAt) return `Starts ${format(folder.startAt)}`
  return null
}

export function FolderPage() {
  const uid = useUID()
  const navigate = useNavigate()
  const { folderID = '' } = useParams()
  const folder = useFolder(uid, folderID)
  const folders = useFolders(uid)
  const reminders = useRemindersIn(uid, folderID)
  const allNotes = useNotes(uid)
  const people = usePeople(uid)

  const [editing, setEditing] = useState(false)
  const [archiving, setArchiving] = useState(false)
  const [createRequest, setCreateRequest] = useState(0)
  const [editingReminder, setEditingReminder] = useState<Reminder | null>(null)
  const [now] = useState(() => new Date())

  const groups = useMemo(() => (reminders ? sections(reminders, now) : undefined), [reminders, now])
  const done = useMemo(() => (reminders ? completedList(reminders) : []), [reminders])
  const progress = useMemo(() => progressOf(reminders ?? []), [reminders])
  const peopleByID = useMemo(() => new Map((people ?? []).map((person) => [person.id, person])), [people])
  const foldersByID = useMemo(() => new Map((folders ?? []).map((entry) => [entry.id, entry])), [folders])
  const tagSuggestions = useMemo(
    () =>
      uniqueCategoryTags([
        ...(reminders ?? []).flatMap((reminder) => reminder.categoryTags ?? []),
        ...DEFAULT_FOLLOWUP_CATEGORIES,
      ]),
    [reminders],
  )

  const notes = useMemo(
    () =>
      (allNotes ?? [])
        .filter((note) => note.folderID === folderID)
        .sort((a, b) => b.updatedAt.getTime() - a.updatedAt.getTime()),
    [allNotes, folderID],
  )

  const trail = useMemo(
    () => (folders && folder ? pathTo(folders, folder.id).slice(0, -1) : []),
    [folders, folder],
  )
  const children = useMemo(
    () => (folders && folder ? folders.filter((entry) => entry.parentID === folder.id) : []),
    [folders, folder],
  )

  if (folder === undefined) {
    return (
      <PageScaffold width="wide">
        <SkeletonRows count={4} />
      </PageScaffold>
    )
  }

  if (folder === null) {
    return (
      <PageScaffold width="wide">
        <EmptyState
          icon="folder"
          headline="Not here"
          message="This folder has been deleted."
          action={
            <Button variant="primary" onClick={() => navigate('/folders')}>
              Back to Folders
            </Button>
          }
        />
      </PageScaffold>
    )
  }

  const subject = folder
  const line = dateLine(subject, now)
  const archived = isArchived(subject)
  const descendantCount = folders ? descendantIDs(folders, subject.id).size : 0

  async function setArchived(next: boolean) {
    const tree = folders ?? [subject]
    const plan = next
      ? planArchiveFolder(tree, subject, new Date()).plan
      : planUnarchiveFolder(tree, subject, new Date()).plan
    await applyPlan(uid, plan)
    setArchiving(false)
  }

  async function addNote() {
    const { plan, note } = planCreateNote({ folderID: subject.id }, new Date())
    await applyPlan(uid, plan)
    navigate(`/notes/${note.id}`)
  }

  async function addFolder() {
    const { plan, folder: made } = planCreateFolder({ title: 'New folder', parentID: subject.id }, new Date())
    await applyPlan(uid, plan)
    navigate(`/folders/${made.id}`)
  }

  function requestCreateReminder() {
    setEditingReminder(null)
    setCreateRequest((request) => request + 1)
  }

  async function complete(reminder: Reminder) {
    await applyPlan(uid, planCompleteReminder(reminder.id, new Date()).plan)
  }

  async function rescheduleTomorrow(reminder: Reminder) {
    const tomorrow = new Date(startOfDay(new Date()))
    tomorrow.setDate(tomorrow.getDate() + 1)
    if (!reminder.dueAt && reminder.startAt) {
      await applyPlan(uid, planQuickReschedule(reminder.id, tomorrow).plan)
      return
    }
    await applyPlan(
      uid,
      planUpdateReminder(reminder.id, {
        dueAt: tomorrow,
        isSomeday: false,
        duePrecision: 'date',
        scheduleTimeZone: null,
      }).plan,
    )
  }

  return (
    <PageScaffold width="wide">
      <PageHeader
        title={
          <span className="container-title-row">
            <span
              className="folder-picker-glyph folder-glyph-large"
              style={{ '--tint': folderTint(subject.colorName) } as React.CSSProperties}
            >
              <Icon name="folder" size={18} />
            </span>
            {subject.title}
          </span>
        }
        subtitle={
          <span className="container-meta">
            {trail.map((ancestor) => (
              <button
                key={ancestor.id}
                type="button"
                className="link-button"
                onClick={() => navigate(`/folders/${ancestor.id}`)}
              >
                {ancestor.title}
              </button>
            ))}
            {subject.summary && <span>{subject.summary}</span>}
            {line && <span>{line}</span>}
            {progress.total > 0 && <span>{progressSentence(progress)}</span>}
          </span>
        }
        actions={
          archived ? (
            <Button variant="primary" icon="archive" onClick={() => void setArchived(false)}>
              Unarchive
            </Button>
          ) : (
            <>
              <Button variant="quiet" icon="archive" onClick={() => setArchiving(true)}>
                Archive
              </Button>
              <Button variant="quiet" icon="pencil" onClick={() => setEditing(true)}>
                Rename
              </Button>
              <Button variant="quiet" icon="note" onClick={() => void addNote()}>
                New note
              </Button>
              <Button variant="primary" icon="plus" onClick={requestCreateReminder}>
                New follow-up
              </Button>
            </>
          )
        }
      />

      {archived && (
        <div className="archive-banner">
          <Icon name="archive" size={16} />
          <span>
            Archived{subject.archivedAt ? ` ${relativeDescription(subject.archivedAt, now)}` : ''}. Its reminders
            no longer appear in Follow-ups, and nothing here was marked done on its behalf.
          </span>
        </div>
      )}

      {children.length > 0 && (
        <section>
          <h2 className="section-header">Folders</h2>
          <div className="folder-list">
            {children.map((child) => (
              <div key={child.id} className="folder-row">
                <span className="folder-tree-twisty" aria-hidden="true" />
                <button type="button" className="folder-row-main" onClick={() => navigate(`/folders/${child.id}`)}>
                  <span
                    className="folder-picker-glyph"
                    style={{ '--tint': folderTint(child.colorName) } as React.CSSProperties}
                  >
                    <Icon name="folder" size={15} />
                  </span>
                  <span className="folder-row-text">
                    <span className="row-title">{child.title}</span>
                    {child.summary && <span className="row-subtitle">{child.summary}</span>}
                  </span>
                </button>
              </div>
            ))}
          </div>
        </section>
      )}

      {notes.length > 0 && (
        <section>
          <h2 className="section-header">Notes</h2>
          <div className="note-list">
            {notes.map((note) => {
              const excerpt = excerptOf(note)
              return (
                <div key={note.id} className="note-row">
                  <button type="button" className="note-row-main" onClick={() => navigate(`/notes/${note.id}`)}>
                    <span className="note-row-text">
                      <span className="row-title">{displayTitle(note)}</span>
                      {excerpt && <span className="row-subtitle">{excerpt}</span>}
                    </span>
                    <span className="note-row-meta">
                      <span className="row-trailing">{relativeDescription(note.updatedAt, now)}</span>
                    </span>
                  </button>
                </div>
              )
            })}
          </div>
        </section>
      )}

      {groups === undefined && <SkeletonRows count={3} />}

      {!archived && groups?.length === 0 && done.length === 0 && notes.length === 0 && children.length === 0 && (
        <EmptyState
          icon="folder"
          headline="Nothing in here yet"
          message="Reminders filed here show up in Follow-ups too, and notes filed here archive with the folder — this is the same work, seen from the trip rather than from the day."
          action={
            <>
              <Button variant="primary" icon="plus" onClick={requestCreateReminder}>
                New follow-up
              </Button>
              <Button variant="secondary" icon="note" onClick={() => void addNote()}>
                New note
              </Button>
              <Button variant="secondary" icon="folder" onClick={() => void addFolder()}>
                New folder
              </Button>
            </>
          }
        />
      )}

      {archived && leftOpen(reminders ?? []).length > 0 && (
        <section>
          <h2 className="section-header">Left open</h2>
          {leftOpen(reminders ?? []).map((reminder) => (
            <div key={reminder.id} className="task-row">
              <span className="complete-ring complete-ring-static" aria-hidden="true" />
              <span className="task-main">
                <span className="row-title">{reminder.title}</span>
              </span>
            </div>
          ))}
        </section>
      )}

      {!archived && groups && people && (
        <InlineFollowUpComposer
          key={`folder-create-${subject.id}`}
          people={people}
          folders={folders ?? []}
          tagSuggestions={tagSuggestions}
          activationRequest={createRequest}
          defaultFolderID={subject.id}
          hideTrigger
        />
      )}

      {!archived &&
        groups?.map((group) => (
          <section key={group.bucket}>
            <h2 className="section-header" data-tone={group.bucket === 'overdue' ? 'overdue' : undefined}>
              {BUCKET_TITLES[group.bucket]}
            </h2>
            {group.reminders.map((reminder) => {
              if (editingReminder?.id === reminder.id && people) {
                return (
                  <InlineFollowUpComposer
                    key={reminder.id}
                    existing={reminder}
                    people={people}
                    folders={folders ?? []}
                    tagSuggestions={tagSuggestions}
                    onClose={() =>
                      setEditingReminder((current) => (current?.id === reminder.id ? null : current))
                    }
                  />
                )
              }
              return (
                <FollowUpRow
                  key={reminder.id}
                  reminder={reminder}
                  now={now}
                  peopleByID={peopleByID}
                  foldersByID={foldersByID}
                  onComplete={() => void complete(reminder)}
                  onEdit={() => setEditingReminder(reminder)}
                  onReschedule={() => void rescheduleTomorrow(reminder)}
                />
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

      {archiving && (
        <Dialog title={`Archive ${subject.title}?`} onClose={() => setArchiving(false)}>
          <p className="row-subtitle">
            {descendantCount > 0
              ? `${subject.title} and the ${descendantCount} folder${descendantCount === 1 ? '' : 's'} inside it move to the archive. `
              : ''}
            Its reminders leave Follow-ups and its notes become read-only. Nothing is completed and nothing is
            deleted — anything still open stays open, and you can search for all of it or bring it back.
          </p>
          <div className="sheet-actions">
            <Button variant="quiet" onClick={() => setArchiving(false)}>
              Cancel
            </Button>
            <Button variant="primary" onClick={() => void setArchived(true)}>
              Archive
            </Button>
          </div>
        </Dialog>
      )}

      {editing && folders && (
        <FolderSheet existing={subject} folders={folders} onClose={() => setEditing(false)} />
      )}

    </PageScaffold>
  )
}
