/// The files under the textarea — open rows between hairlines, never cards or
/// chips. Progress reads through one polite live region; errors are alerts
/// tied to their rows; every remove button names its file.

import {
  attachmentStatusLine,
  formatBytes,
  type CaptureAttachment,
} from '../../domain/attachments'
import { Icon } from '../components/Icon'

const KIND_ICONS: Record<CaptureAttachment['kind'], string> = {
  pdf: 'email',
  docx: 'email',
  text: 'email',
  table: 'filter',
  image: 'video',
}

export function AttachmentList({
  attachments,
  onRemove,
  onRetry,
}: {
  attachments: CaptureAttachment[]
  onRemove: (id: string) => void
  onRetry: (id: string) => void
}) {
  if (attachments.length === 0) return null

  const reading = attachments.filter((a) => a.status === 'extracting' || a.status === 'queued').length

  return (
    <div className="attachment-list">
      <p className="visually-hidden" aria-live="polite">
        {reading > 0
          ? `Reading ${reading} file${reading === 1 ? '' : 's'}…`
          : 'All files are ready.'}
      </p>
      {attachments.map((attachment) => (
        <div key={attachment.id} className="attachment-row" data-status={attachment.status}>
          <span className="attachment-icon" aria-hidden="true">
            <Icon name={KIND_ICONS[attachment.kind]} size={15} />
          </span>
          <span className="attachment-main">
            <span className="attachment-name">{attachment.name}</span>
            <span
              className="attachment-status"
              {...(attachment.status === 'error' ? { role: 'alert' } : {})}
            >
              {formatBytes(attachment.byteSize)} · {attachmentStatusLine(attachment)}
            </span>
          </span>
          <span className="attachment-actions">
            {attachment.status === 'error' && attachment.errorCode === 'extraction-failed' && (
              <button type="button" className="button button-plain" onClick={() => onRetry(attachment.id)}>
                Retry
              </button>
            )}
            <button
              type="button"
              className="icon-button"
              aria-label={`Remove ${attachment.name}`}
              onClick={() => onRemove(attachment.id)}
            >
              <Icon name="x" size={14} />
            </button>
          </span>
        </div>
      ))}
    </div>
  )
}
