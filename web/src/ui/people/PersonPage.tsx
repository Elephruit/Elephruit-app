import { useNavigate, useParams } from 'react-router-dom'
import { lastContactLine } from '../../domain/contact'
import { usePerson } from '../../data/hooks'
import { useUID } from '../UserContext'
import { Avatar } from '../components/Avatar'
import { Icon } from '../components/Icon'

export function PersonPage() {
  const uid = useUID()
  const navigate = useNavigate()
  const { personID } = useParams()
  const person = usePerson(uid, personID!)

  if (person === undefined) return <main className="page" />
  if (person === null) {
    return (
      <main className="page">
        <p className="row-subtitle">This record no longer exists.</p>
      </main>
    )
  }

  const roleLine = [person.roleTitle, person.organizationName].filter(Boolean).join(' · ')

  return (
    <main className="page">
      <button type="button" className="button-plain button" onClick={() => navigate(-1)}>
        <Icon name="back" size={16} /> Back
      </button>

      <header
        style={{
          display: 'flex',
          alignItems: 'center',
          gap: 'var(--space-large)',
          margin: 'var(--space-large) 0 var(--space-small)',
        }}
      >
        <span style={{ transform: 'scale(1.6)', transformOrigin: 'left center' }}>
          <Avatar name={person.displayName} colorName={person.colorName} />
        </span>
        <span>
          <h1 className="page-title" style={{ marginBottom: 2 }}>
            {person.displayName}
          </h1>
          {roleLine && <p className="row-subtitle">{roleLine}</p>}
          <p className="row-subtitle">{lastContactLine(person.lastContactAt, new Date())}</p>
        </span>
      </header>

      <button
        type="button"
        className="button"
        style={{ marginTop: 'var(--space-medium)' }}
        onClick={() => navigate(`/log?person=${person.id}`)}
      >
        <Icon name="plus" size={16} /> Log an interaction
      </button>
    </main>
  )
}
