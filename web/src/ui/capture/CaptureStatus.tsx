/// The composer's status voice: one polite live region that reads parsing
/// progress and the saved confirmation to assistive tech, and an alert row for
/// errors. Kept as one component so every status change goes through the same
/// live region instead of scattered aria attributes.

import { Icon } from '../components/Icon'
import type { CaptureMode } from './useCaptureController'

export function CaptureStatus({ mode }: { mode: CaptureMode }) {
  return (
    <p className="composer-status" aria-live="polite">
      {mode === 'parsing' && 'Finding people, facts, and follow-ups…'}
      {mode === 'saved' && (
        <span className="composer-saved">
          <Icon name="check-circle" size={16} />
          Added to your timeline
        </span>
      )}
    </p>
  )
}

export function CaptureError({
  message,
  onRetry,
  onManual,
  canRetry,
}: {
  message: string
  onRetry: () => void
  onManual: () => void
  canRetry: boolean
}) {
  return (
    <div className="composer-error" role="alert">
      <p>{message}</p>
      <span className="composer-error-actions">
        {canRetry && (
          <button type="button" className="button button-quiet button-small" onClick={onRetry}>
            Try again
          </button>
        )}
        <button type="button" className="button button-quiet button-small" onClick={onManual}>
          Add manually
        </button>
      </span>
    </div>
  )
}
