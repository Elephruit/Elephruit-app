/// A count with a name and one line of context. Tone colors the number, not the
/// tile — the canvas stays calm and the figure carries the signal.

import type { ReactNode } from 'react'

export function MetricTile({
  value,
  label,
  detail,
  tone = 'neutral',
  onClick,
}: {
  value: ReactNode
  label: string
  detail?: ReactNode
  tone?: 'neutral' | 'overdue' | 'today' | 'accent'
  onClick?: () => void
}) {
  return (
    <button type="button" className="metric-tile" data-tone={tone} onClick={onClick}>
      <b className="tabular">{value}</b>
      <span>{label}</span>
      {detail && <small>{detail}</small>}
    </button>
  )
}
