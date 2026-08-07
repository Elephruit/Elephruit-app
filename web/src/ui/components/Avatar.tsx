import { initials, type PaletteColor } from '../../domain/person'
import { Icon } from './Icon'

/// One monogram algorithm, one circle — same rule as the Mac app's Avatar.
/// Unnamed people never show initials: a phrase like "Dave Okafor's son"
/// would render a parent-derived "DO", which reads as the wrong person. They
/// get a neutral figure in their own palette color instead.
export function Avatar({
  name,
  colorName,
  small = false,
  size,
  unnamed = false,
}: {
  name: string
  colorName: PaletteColor
  /// Legacy shorthand for size="sm".
  small?: boolean
  size?: 'sm' | 'md' | 'lg'
  unnamed?: boolean
}) {
  const resolved = size ?? (small ? 'sm' : 'md')
  const className = resolved === 'sm' ? 'avatar avatar-small' : resolved === 'lg' ? 'avatar avatar-large' : 'avatar'
  return (
    <span
      className={className}
      style={{ '--tint': `var(--palette-${colorName})` } as React.CSSProperties}
      aria-hidden="true"
    >
      {unnamed ? <Icon name="in-person" size={resolved === 'sm' ? 14 : resolved === 'lg' ? 26 : 18} /> : initials(name) || '?'}
    </span>
  )
}
