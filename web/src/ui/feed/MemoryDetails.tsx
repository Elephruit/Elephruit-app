/// The optional depth of a rich moment: the tinted note that fades into the
/// canvas, sparkle-prefixed learned details, connected relationships, and an
/// integrated follow-up row — spacing and hairlines, never mini-cards.

import type { MemoryMomentViewModel } from '../../data/memoryProjection'
import { bucketFor, type Reminder } from '../../domain/reminders'
import { formatScheduleSummary } from '../../domain/temporal'
import { Icon } from '../components/Icon'

function FollowUpRow({ reminder, now }: { reminder: Reminder; now: Date }) {
  const bucket = bucketFor(reminder, now)
  const schedule = reminder.status === 'completed' ? 'Done' : (formatScheduleSummary(reminder) ?? 'Anytime')
  return (
    <div className="memory-followup">
      <span
        className="memory-followup-ring"
        data-done={reminder.status === 'completed' || undefined}
        aria-hidden="true"
      >
        {reminder.status === 'completed' && <Icon name="check" size={10} />}
      </span>
      <span className="memory-followup-title">{reminder.title}</span>
      <span
        className="memory-followup-due tabular"
        data-tone={bucket === 'overdue' ? 'overdue' : bucket === 'today' ? 'today' : undefined}
      >
        {schedule}
      </span>
    </div>
  )
}

export function MemoryDetails({ moment, now }: { moment: MemoryMomentViewModel; now: Date }) {
  const hasAny =
    moment.excerpt || moment.details.length > 0 || moment.relationships.length > 0 || moment.followUps.length > 0
  if (!hasAny) return null

  return (
    <div className="memory-depth">
      {moment.excerpt && <p className="memory-note">{moment.excerpt}</p>}

      {(moment.details.length > 0 || moment.relationships.length > 0) && (
        <div className="memory-facts">
          {moment.details.map((detail) => (
            <p key={detail.id} className="memory-fact">
              <Icon name="sparkle" size={12} />
              <span>{detail.text}</span>
            </p>
          ))}
          {moment.relationships.map((relationship) => (
            <p key={relationship.id} className="memory-fact">
              <Icon name="people" size={12} />
              <span>{relationship.text}</span>
            </p>
          ))}
        </div>
      )}

      {moment.followUps.map((reminder) => (
        <FollowUpRow key={reminder.id} reminder={reminder} now={now} />
      ))}
    </div>
  )
}
