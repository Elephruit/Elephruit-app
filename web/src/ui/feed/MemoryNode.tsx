/// The node a moment hangs from: a named person's avatar, a two-face stack,
/// a neutral silhouette for unnamed people, a sparkle for pure profile
/// updates — always with the canvas halo that lets the rail pass behind it.

import type { Person } from '../../domain/person'
import { Avatar } from '../components/Avatar'
import { AvatarStack } from '../components/AvatarStack'
import { Icon } from '../components/Icon'

export function MemoryNode({
  people,
  kind,
}: {
  people: Person[]
  kind: 'contact' | 'profile' | 'import'
}) {
  const named = people.filter((p) => p.hasStatedName)

  let content: React.ReactNode
  if (kind !== 'contact' && people.length === 0) {
    content = (
      <span className="memory-node-glyph tinted" style={{ '--tint': 'var(--color-personal)' } as React.CSSProperties}>
        <Icon name="sparkle" size={15} />
      </span>
    )
  } else if (named.length === 0 && people.length > 0) {
    // Unnamed people never show phrase-derived initials — a neutral figure in
    // the placeholder's palette color.
    content = (
      <span
        className="memory-node-glyph tinted"
        style={{ '--tint': `var(--palette-${people[0].colorName})` } as React.CSSProperties}
      >
        <Icon name="in-person" size={16} />
      </span>
    )
  } else if (named.length === 1) {
    content = <Avatar name={named[0].displayName} colorName={named[0].colorName} size="md" />
  } else if (named.length > 1) {
    content = <AvatarStack people={named} />
  } else {
    content = (
      <span className="memory-node-glyph tinted" style={{ '--tint': 'var(--color-personal)' } as React.CSSProperties}>
        <Icon name="sparkle" size={15} />
      </span>
    )
  }

  return <span className="memory-node">{content}</span>
}
