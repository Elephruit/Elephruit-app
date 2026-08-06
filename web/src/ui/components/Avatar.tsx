import { initials, type PaletteColor } from '../../domain/person'

/// One monogram algorithm, one circle — same rule as the Mac app's Avatar.
export function Avatar({
  name,
  colorName,
  small = false,
  size,
}: {
  name: string
  colorName: PaletteColor
  /// Legacy shorthand for size="sm".
  small?: boolean
  size?: 'sm' | 'md' | 'lg'
}) {
  const resolved = size ?? (small ? 'sm' : 'md')
  const className = resolved === 'sm' ? 'avatar avatar-small' : resolved === 'lg' ? 'avatar avatar-large' : 'avatar'
  return (
    <span
      className={className}
      style={{ '--tint': `var(--palette-${colorName})` } as React.CSSProperties}
      aria-hidden="true"
    >
      {initials(name) || '?'}
    </span>
  )
}
