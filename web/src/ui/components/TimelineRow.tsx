/// The universal feed item: a rail, a badge on the line, content beside it.
/// Kind differences are expressed by which fields exist, never by a different
/// anatomy. Ported from the Mac app's Timeline framework — one continuous
/// thread, no cards.

export type RailStyle = 'line' | 'head' | 'tail' | 'none'

export function TimelineRow({
  rail = 'line',
  tint,
  badge,
  badgeLabel,
  onBadgeClick,
  children,
}: {
  rail?: RailStyle
  /// A CSS colour expression; defaults to the accent.
  tint?: string
  badge: React.ReactNode
  badgeLabel?: string
  /// When set, the badge is a control — a reminder's badge is its checkbox.
  onBadgeClick?: () => void
  children: React.ReactNode
}) {
  const style = tint ? ({ '--tint': tint } as React.CSSProperties) : undefined

  return (
    <div className="timeline-row" data-rail={rail}>
      <div className="timeline-rail" style={style}>
        {onBadgeClick ? (
          <button type="button" className="timeline-badge" aria-label={badgeLabel} onClick={onBadgeClick}>
            {badge}
          </button>
        ) : (
          <span className="timeline-badge" aria-hidden="true">
            {badge}
          </span>
        )}
      </div>
      <div className="timeline-content">{children}</div>
    </div>
  )
}

