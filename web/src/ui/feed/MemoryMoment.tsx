/// One moment on the rail: node, branch, and a content region that merges
/// with the canvas — no card, no border, no shadow. A semantic <article> with
/// explicit links and buttons; the overflow actions appear on hover and
/// focus-within, and stay visible on coarse pointers via CSS.

import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import type { MemoryMomentViewModel } from '../../data/memoryProjection'
import type { Person } from '../../domain/person'
import { Icon } from '../components/Icon'
import { MemoryBranch } from './MemoryBranch'
import { MemoryDetails } from './MemoryDetails'
import { MemoryProvenance, MemoryTopLine } from './MemoryMeta'
import { MemoryNode } from './MemoryNode'

function personTint(people: Person[], isContact: boolean): string {
  const first = people[0]
  if (first) return `var(--palette-${first.colorName})`
  return isContact ? 'var(--color-accent)' : 'var(--color-personal)'
}

export function MemoryMoment({
  moment,
  now,
  entering = false,
  last = false,
}: {
  moment: MemoryMomentViewModel
  now: Date
  /// Newly inserted after a save — plays the insertion sequence.
  entering?: boolean
  last?: boolean
}) {
  const navigate = useNavigate()
  const [menuOpen, setMenuOpen] = useState(false)
  const tint = personTint(moment.people, moment.isContact)
  const rich =
    Boolean(moment.excerpt) ||
    moment.details.length > 0 ||
    moment.relationships.length > 0 ||
    moment.followUps.length > 0
  const firstPerson = moment.people[0]

  return (
    <article
      className="memory-moment"
      data-entering={entering || undefined}
      data-last={last || undefined}
      data-rich={rich || undefined}
      aria-label={moment.title}
    >
      <div className="memory-rail-col" aria-hidden="true">
        <MemoryNode
          people={moment.people}
          kind={moment.isContact ? 'contact' : moment.kind === 'dossierImport' ? 'import' : 'profile'}
        />
        <MemoryBranch tint={tint} />
      </div>

      <div className="memory-content" style={{ '--moment-tint': tint } as React.CSSProperties}>
        <div className="memory-head-row">
          <div className="memory-head-main">
            <MemoryTopLine moment={moment} />
            <h3 className="memory-title">{moment.title}</h3>
            <MemoryProvenance moment={moment} />
          </div>
          <div className="memory-actions">
            <button
              type="button"
              className="icon-button memory-overflow"
              aria-label={`Actions for ${moment.title}`}
              aria-expanded={menuOpen}
              onClick={() => setMenuOpen((open) => !open)}
            >
              <Icon name="other" size={15} />
            </button>
            {menuOpen && (
              <div className="memory-menu" role="menu">
                {firstPerson && (
                  <button
                    type="button"
                    role="menuitem"
                    className="memory-menu-item"
                    onClick={() => navigate(`/people/${firstPerson.id}`)}
                  >
                    View person
                  </button>
                )}
                <button
                  type="button"
                  role="menuitem"
                  className="memory-menu-item"
                  onClick={() =>
                    navigate(firstPerson ? `/?capture=1&person=${firstPerson.id}` : '/?capture=1')
                  }
                >
                  Add follow-up
                </button>
              </div>
            )}
          </div>
        </div>

        <MemoryDetails moment={moment} now={now} />

        {!last && <hr className="memory-separator" />}
      </div>
    </article>
  )
}
