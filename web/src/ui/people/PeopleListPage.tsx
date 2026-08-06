import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { relativeDescription } from '../../domain/contact'
import type { Person } from '../../domain/person'
import { usePeople } from '../../data/hooks'
import { useUID } from '../UserContext'
import { Avatar } from '../components/Avatar'
import { EmptyState } from '../components/EmptyState'
import { CreatePersonSheet } from './CreatePersonSheet'

function subtitle(person: Person): string | null {
  if (person.roleTitle && person.organizationName) return `${person.roleTitle} · ${person.organizationName}`
  return person.roleTitle ?? person.organizationName
}

export function PeopleListPage() {
  const uid = useUID()
  const navigate = useNavigate()
  const people = usePeople(uid)
  const [creating, setCreating] = useState(false)

  // Placeholders stay off the list — they surface on the pages of the people
  // they belong to, and in the to-fill-in queue, same as the Mac app.
  const listed = people?.filter((person) => !person.isPlaceholder)

  return (
    <main className="page">
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <h1 className="page-title" style={{ marginBottom: 0 }}>
          People
        </h1>
        <button type="button" className="button button-plain" onClick={() => setCreating(true)}>
          New person
        </button>
      </div>

      {listed && listed.length === 0 && (
        <EmptyState
          icon="people"
          headline="Nobody recorded yet"
          message="Add the people you talk to; everything else hangs off them."
        />
      )}

      <div style={{ marginTop: 'var(--space-medium)' }}>
        {listed?.map((person) => (
          <button
            key={person.id}
            type="button"
            className="row"
            onClick={() => navigate(`/people/${person.id}`)}
          >
            <Avatar name={person.displayName} colorName={person.colorName} />
            <span>
              <span className="row-title" style={{ display: 'block' }}>
                {person.displayName}
              </span>
              {subtitle(person) && <span className="row-subtitle">{subtitle(person)}</span>}
            </span>
            <span className="row-trailing">
              {person.lastContactAt ? relativeDescription(person.lastContactAt, new Date()) : ''}
            </span>
          </button>
        ))}
      </div>

      {creating && (
        <CreatePersonSheet
          onClose={() => setCreating(false)}
          onCreated={(person) => {
            setCreating(false)
            navigate(`/people/${person.id}`)
          }}
        />
      )}
    </main>
  )
}
