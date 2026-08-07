/// Up to two faces for a multi-person moment, overlapped, with the overflow
/// carried in accessible text rather than a third circle.

import type { Person } from '../../domain/person'
import { Avatar } from './Avatar'

export function AvatarStack({ people, size = 'sm' }: { people: Person[]; size?: 'sm' | 'md' }) {
  const visible = people.slice(0, 2)
  const overflow = people.length - visible.length

  return (
    <span className="avatar-stack" role="img" aria-label={people.map((p) => p.displayName).join(', ')}>
      {visible.map((person) => (
        <Avatar key={person.id} name={person.displayName} colorName={person.colorName} size={size} />
      ))}
      {overflow > 0 && <span className="visually-hidden">and {overflow} more</span>}
    </span>
  )
}
