import { Icon } from './Icon'

export function EmptyState({
  icon,
  headline,
  message,
}: {
  icon: string
  headline: string
  message: string
}) {
  return (
    <div className="empty-state">
      <Icon name={icon} size={32} />
      <h2>{headline}</h2>
      <p>{message}</p>
    </div>
  )
}
