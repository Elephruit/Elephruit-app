/// A moment's top line — linked person names before anything else, the time
/// on the right as a real <time> — and its quiet provenance line beneath the
/// title.

import { Link } from 'react-router-dom'
import { Icon } from '../components/Icon'
import type { MemoryMomentViewModel } from '../../data/memoryProjection'

function timeLabel(date: Date): string {
  return date.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' })
}

export function MemoryTopLine({ moment }: { moment: MemoryMomentViewModel }) {
  const named = moment.people.filter((p) => p.hasStatedName)
  const unnamed = moment.people.filter((p) => !p.hasStatedName)

  return (
    <div className="memory-top-line">
      <span className="memory-people">
        {named.map((person, index) => (
          <span key={person.id}>
            {index > 0 && ', '}
            <Link className="memory-person-link" to={`/people/${person.id}`}>
              {person.displayName}
            </Link>
          </span>
        ))}
        {named.length === 0 && unnamed.length > 0 && (
          <Link className="memory-person-link" to={`/people/${unnamed[0].id}`}>
            {unnamed[0].displayName}
          </Link>
        )}
        {moment.people.length === 0 && <span className="memory-person-link">Update</span>}
      </span>
      <time className="memory-time tabular" dateTime={moment.occurredAt.toISOString()}>
        {timeLabel(moment.occurredAt)}
      </time>
    </div>
  )
}

export function MemoryProvenance({ moment }: { moment: MemoryMomentViewModel }) {
  return (
    <p className="memory-provenance">
      {moment.interactionKind && <Icon name={moment.interactionKind} size={13} />}
      <span>{moment.provenanceLabel}</span>
      {moment.sourceLine && <span> · {moment.sourceLine}</span>}
    </p>
  )
}
