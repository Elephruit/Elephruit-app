import { initials, type PaletteColor } from '../../domain/person'

/// One monogram algorithm, one circle — same rule as the Mac app's Avatar.
export function Avatar({
  name,
  colorName,
  small = false,
}: {
  name: string
  colorName: PaletteColor
  small?: boolean
}) {
  return (
    <span
      className={small ? 'avatar avatar-small' : 'avatar'}
      style={{ '--tint': `var(--palette-${colorName})` } as React.CSSProperties}
      aria-hidden="true"
    >
      {initials(name) || '?'}
    </span>
  )
}
