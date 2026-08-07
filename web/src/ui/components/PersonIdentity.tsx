/// A person shown as a person — avatar beside name, optionally with one line
/// of context — instead of a bare string. The polish plan's rule is "show
/// people before metadata": reminder rows, review items, and rail sections all
/// render this rather than reinventing avatar-plus-name locally.

import { Link } from 'react-router-dom'
import type { PaletteColor } from '../../domain/person'
import { Avatar } from './Avatar'

export interface PersonIdentityRef {
  id: string
  displayName: string
  colorName: PaletteColor
  hasStatedName?: boolean
}

export function PersonIdentity({
  person,
  detail,
  link = false,
  size = 'sm',
}: {
  person: PersonIdentityRef
  /// One quiet line beneath or beside the name — a role, a distinguishing fact.
  detail?: React.ReactNode
  /// Render the name as a link to the person's page.
  link?: boolean
  size?: 'sm' | 'md'
}) {
  const name = link ? (
    <Link className="person-identity-name" to={`/people/${person.id}`}>
      {person.displayName}
    </Link>
  ) : (
    <span className="person-identity-name">{person.displayName}</span>
  )

  return (
    <span className="person-identity" data-size={size}>
      <Avatar name={person.displayName} colorName={person.colorName} size={size === 'md' ? 'md' : 'sm'} />
      <span className="person-identity-text">
        {name}
        {detail && <span className="person-identity-detail">{detail}</span>}
      </span>
    </span>
  )
}
