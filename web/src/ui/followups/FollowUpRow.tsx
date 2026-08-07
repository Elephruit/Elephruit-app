import { useNavigate } from 'react-router-dom'
import { bucketFor, type Reminder } from '../../domain/reminders'
import type { Person } from '../../domain/person'
import { folderTint, type Folder } from '../../domain/folder'
import { formatScheduleSummary } from '../../domain/temporal'
import { uniqueCategoryTags } from '../../domain/categoryTags'
import { Avatar } from '../components/Avatar'
import { Button } from '../components/Button'
import { Icon } from '../components/Icon'
import { categoryTintStyle } from './categoryStyle'

function dateChip(reminder: Reminder, now: Date): { text: string; tone: 'overdue' | 'today' | null } | null {
  if (reminder.isSomeday) return null
  const summary = formatScheduleSummary(reminder)
  if (!summary) return null
  const text = summary.replace(/^(Due|Starts) /, '')
  const bucket = bucketFor(reminder, now)
  if (bucket === 'overdue') return { text, tone: 'overdue' }
  if (bucket === 'today') return { text, tone: 'today' }
  return { text, tone: null }
}

function quickActionLabel(reminder: Reminder): string {
  return reminder.dueAt || reminder.startAt ? 'Move to tomorrow' : 'Schedule tomorrow'
}

export function FollowUpRow({
  reminder,
  now,
  peopleByID,
  foldersByID,
  onComplete,
  onEdit,
  onReschedule,
}: {
  reminder: Reminder
  now: Date
  peopleByID: Map<string, Person>
  foldersByID: Map<string, Folder>
  onComplete: () => void
  onEdit: () => void
  onReschedule: () => void
}) {
  const navigate = useNavigate()
  const chip = dateChip(reminder, now)
  const folder = reminder.folderID ? foldersByID.get(reminder.folderID) : undefined

  return (
    <div className="task-row">
      <button
        type="button"
        className="complete-ring"
        aria-label={`Complete ${reminder.title}`}
        onClick={onComplete}
      />
      <button type="button" className="task-main" onClick={onEdit}>
        <span className="row-title">{reminder.title}</span>
        <span className="task-meta">
          {folder && (
            <span
              role="link"
              tabIndex={0}
              className="task-container"
              style={{ '--tint': folderTint(folder.colorName) } as React.CSSProperties}
              onClick={(event) => {
                event.stopPropagation()
                navigate(`/folders/${folder.id}`)
              }}
              onKeyDown={(event) => event.key === 'Enter' && navigate(`/folders/${folder.id}`)}
            >
              <Icon name="folder" size={13} />
              {folder.title}
            </span>
          )}
          {chip && (
            <span
              className={
                chip.tone === 'overdue'
                  ? 'chip chip-status-overdue'
                  : chip.tone === 'today'
                    ? 'chip chip-status-today'
                    : 'chip'
              }
            >
              {chip.text}
            </span>
          )}
          {reminder.responsibility === 'theirs' && reminder.progress && reminder.progress !== 'notStarted' && (
            <span className="chip">{reminder.progress === 'blocked' ? 'Blocked' : 'In progress'}</span>
          )}
          {reminder.personIDs.map((id) => {
            const person = peopleByID.get(id)
            if (!person) return null
            return (
              <span
                key={id}
                role="link"
                tabIndex={0}
                className="task-person"
                onClick={(event) => {
                  event.stopPropagation()
                  navigate(`/people/${id}`)
                }}
                onKeyDown={(event) => event.key === 'Enter' && navigate(`/people/${id}`)}
              >
                <Avatar name={person.displayName} colorName={person.colorName} small />
                {person.displayName}
              </span>
            )
          })}
          {uniqueCategoryTags(reminder.categoryTags ?? []).map((tag) => (
            <span key={tag} className="task-category" style={categoryTintStyle(tag)}>
              <span className="category-option-dot" aria-hidden="true" />
              {tag}
            </span>
          ))}
        </span>
      </button>
      <span className="task-actions">
        <Button variant="ghost" small onClick={onReschedule}>
          {quickActionLabel(reminder)}
        </Button>
      </span>
    </div>
  )
}
