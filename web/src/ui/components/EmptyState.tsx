import type { ReactNode } from 'react'
import { Icon } from './Icon'

/// An empty state teaches the next step: what this surface is for, and the
/// action that starts filling it.
export function EmptyState({
  icon,
  headline,
  message,
  action,
  hint,
}: {
  icon: string
  headline: string
  message: string
  action?: ReactNode
  hint?: ReactNode
}) {
  return (
    <div className="empty-state">
      <Icon name={icon} size={28} />
      <h2>{headline}</h2>
      <p>{message}</p>
      {action && <div className="empty-state-actions">{action}</div>}
      {hint && <p className="empty-state-hint">{hint}</p>}
    </div>
  )
}
