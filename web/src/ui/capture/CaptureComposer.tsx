/// The inline "What happened?" composer — the first actionable node on the
/// memory rail. Collapsed it is one 56px rail-connected row; open it expands
/// in place while the accent node and its branch stay fixed, so composing
/// happens inside the feed rather than on a separate page. FeedPage owns the
/// URL (?capture=1) and passes open/close requests; this component owns focus,
/// the textarea, and the embedded review.

import { useEffect, useRef, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { Link } from 'react-router-dom'
import { usePeople } from '../../data/hooks'
import { acceptList } from '../../domain/attachments'
import { useUID } from '../UserContext'
import { Button } from '../components/Button'
import { Icon } from '../components/Icon'
import { AttachmentDropZone } from './AttachmentDropZone'
import { AttachmentList } from './AttachmentList'
import { DossierReview } from './DossierReview'
import { DossierTargetPicker } from './DossierTargetPicker'
import { EditableReviewPanel } from './EditableReviewPanel'
import { CaptureError, CaptureStatus } from './CaptureStatus'
import { CaptureSuggestions } from './CaptureSuggestions'
import type { CaptureController } from './useCaptureController'

const TEXTAREA_MAX_HEIGHT = 240
const DRAG_OPEN_DELAY_MS = 250

export function CaptureComposer({
  controller,
  onRequestOpen,
  onRequestClose,
}: {
  controller: CaptureController
  onRequestOpen: () => void
  onRequestClose: () => void
}) {
  const navigate = useNavigate()
  const uid = useUID()
  const people = usePeople(uid) ?? []
  const collapsedRef = useRef<HTMLButtonElement>(null)
  const textareaRef = useRef<HTMLTextAreaElement>(null)
  const fileInputRef = useRef<HTMLInputElement>(null)
  const wasOpen = useRef(false)
  const dragOpenTimer = useRef<number | null>(null)
  const [dragging, setDragging] = useState(false)

  const { mode } = controller
  const open = mode !== 'collapsed'
  const hasAttachments = controller.attachments.length > 0
  const targetPerson = controller.initialPersonID
    ? people.find((p) => p.id === controller.initialPersonID)
    : undefined

  // Focus follows state: expansion focuses the textarea, collapse returns
  // focus to the trigger — but only when the composer was actually open, so
  // mounting the feed does not steal focus.
  useEffect(() => {
    if (mode === 'composing') {
      textareaRef.current?.focus()
      autogrow(textareaRef.current)
    }
    if (mode === 'collapsed' && wasOpen.current) {
      collapsedRef.current?.focus()
    }
    wasOpen.current = open
  }, [mode, open])

  function autogrow(textarea: HTMLTextAreaElement | null) {
    if (!textarea) return
    textarea.style.height = 'auto'
    textarea.style.height = `${Math.min(textarea.scrollHeight, TEXTAREA_MAX_HEIGHT)}px`
  }

  function logManually() {
    if (controller.canLogManually) navigate(`/log?text=${encodeURIComponent(controller.text)}`)
    else navigate('/log')
  }

  const readyAttachmentCount = controller.attachments.filter((a) => a.status === 'ready').length
  const primaryLabel =
    mode === 'parsing'
      ? 'Reading…'
      : readyAttachmentCount > 0
        ? controller.text.trim().length > 0
          ? 'Review memory and sources'
          : 'Review sources'
        : 'Review memory'

  const primaryAction = controller.ready ? (
    <Button
      variant="primary"
      icon="sparkle"
      loading={mode === 'parsing'}
      disabled={!controller.canParse}
      onClick={() => void controller.parse()}
    >
      {primaryLabel}
    </Button>
  ) : (
    <Button variant="primary" disabled={!controller.canLogManually} onClick={logManually}>
      Add details
    </Button>
  )

  return (
    <section className="capture-composer" data-mode={mode} data-drag={dragging || undefined}>
      <div className="memory-rail-col" aria-hidden="true">
        <span className="composer-node">
          <Icon name="plus" size={15} />
        </span>
        <span className="memory-branch" />
      </div>

      {!open && (
        <button
          ref={collapsedRef}
          type="button"
          className="composer-collapsed"
          onClick={onRequestOpen}
          onDragEnter={(event) => {
            // A file dragged across the collapsed row opens the composer after
            // a beat; a quick pass never does.
            if (![...event.dataTransfer.types].includes('Files')) return
            if (dragOpenTimer.current === null) {
              dragOpenTimer.current = window.setTimeout(onRequestOpen, DRAG_OPEN_DELAY_MS)
            }
          }}
          onDragLeave={() => {
            if (dragOpenTimer.current !== null) {
              window.clearTimeout(dragOpenTimer.current)
              dragOpenTimer.current = null
            }
          }}
          aria-label="What happened? Record a memory"
        >
          <span className="composer-collapsed-prompt">What happened?</span>
          <span className="composer-collapsed-hint">Click to remember</span>
        </button>
      )}

      {open && (
        <div
          className="composer-panel"
          onKeyDown={(event) => {
            if (event.key === 'Escape') {
              event.stopPropagation()
              onRequestClose()
            }
          }}
        >
          <header className="composer-head">
            <span className="composer-head-label">
              {mode === 'reviewing' || mode === 'reviewing-dossier' ? 'Review memory' : 'New memory'}
            </span>
            <span className="composer-head-actions">
              {controller.hasDraft && mode === 'composing' && (
                <button
                  type="button"
                  className="composer-discard"
                  onClick={() => controller.discardDraft()}
                >
                  Discard draft
                </button>
              )}
              <button type="button" className="icon-button" aria-label="Collapse composer" onClick={onRequestClose}>
                <Icon name="x" size={16} />
              </button>
            </span>
          </header>

          {mode !== 'reviewing' && mode !== 'reviewing-dossier' && mode !== 'saved' && (
            <AttachmentDropZone
              onDropFiles={(files) => void controller.addAttachments(files)}
              onDragChange={setDragging}
            >
              {targetPerson && hasAttachments && (
                <p className="composer-target-line">Building details for {targetPerson.displayName}</p>
              )}

              <textarea
                ref={textareaRef}
                className="composer-textarea"
                value={controller.text}
                readOnly={mode === 'parsing'}
                onChange={(event) => {
                  controller.setText(event.target.value)
                  autogrow(event.target)
                }}
                onKeyDown={(event) => {
                  if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) {
                    event.preventDefault()
                    if (controller.canParse) void controller.parse()
                    else if (controller.canLogManually) logManually()
                  }
                }}
                placeholder="Who did you see, and what happened?"
              />

              {controller.text.trim().length === 0 && mode === 'composing' && !hasAttachments && (
                <CaptureSuggestions
                  onPick={(example) => {
                    controller.setText(example)
                    textareaRef.current?.focus()
                  }}
                />
              )}

              {controller.lostAttachments.length > 0 && !hasAttachments && (
                <p className="composer-reattach" role="status">
                  Files are not kept across refreshes — reattach{' '}
                  {controller.lostAttachments.map((f) => f.name).join(', ')} to include them.
                </p>
              )}

              <AttachmentList
                attachments={controller.attachments}
                onRemove={controller.removeAttachment}
                onRetry={(id) => void controller.retryAttachment(id)}
              />
              {controller.notice && (
                <p className="composer-status" role="status">
                  {controller.notice}
                </p>
              )}
              {hasAttachments && controller.ready && (
                <p className="composer-privacy">
                  Files are sent to your selected AI provider when you choose Review. Elephruit does not keep the
                  original files after processing.
                </p>
              )}
              {hasAttachments && !controller.ready && (
                <p className="composer-privacy">
                  <Link to="/settings">Connect an AI provider in Settings to read attachments.</Link>
                </p>
              )}

              {mode === 'error' && controller.error && (
                <CaptureError
                  message={controller.error}
                  canRetry={controller.ready}
                  onRetry={() => void controller.parse()}
                  onManual={logManually}
                />
              )}

              <CaptureStatus mode={mode} />

              <footer className="composer-foot">
                <span className="composer-foot-left">
                  <button
                    type="button"
                    className="icon-button"
                    aria-label="Add files"
                    onClick={() => fileInputRef.current?.click()}
                  >
                    <Icon name="plus" size={16} />
                  </button>
                  <input
                    ref={fileInputRef}
                    type="file"
                    multiple
                    accept={acceptList()}
                    className="visually-hidden"
                    aria-label="Add files"
                    onChange={(event) => {
                      if (event.target.files) void controller.addAttachments(event.target.files)
                      event.target.value = ''
                    }}
                  />
                  <kbd className="composer-kbd">⌘ Enter to review</kbd>
                </span>
                <span className="composer-foot-actions">
                  <Button variant="quiet" disabled={!controller.canLogManually} onClick={logManually}>
                    Add manually
                  </Button>
                  {primaryAction}
                </span>
              </footer>

              {!controller.ready && (
                <p className="composer-connect">
                  {controller.credentialNeedsAttention ? (
                    <Link to="/settings">Your AI key needs attention in Settings.</Link>
                  ) : (
                    <Link to="/settings">Connect AI in Settings to organize this automatically.</Link>
                  )}
                </p>
              )}
            </AttachmentDropZone>
          )}

          {mode === 'reviewing-dossier' && controller.dossier?.phase === 'target' && (
            <DossierTargetPicker
              options={controller.dossier.options}
              people={people}
              onChoose={controller.chooseDossierTarget}
            />
          )}

          {mode === 'reviewing-dossier' && controller.dossier?.phase === 'review' && (
            <DossierReview
              proposal={controller.dossier.proposal}
              target={controller.dossier.target}
              attachments={controller.attachments}
              onChangeTarget={controller.changeDossierTarget}
              onClose={() => controller.editText()}
              onSaved={() => controller.handleSaved()}
            />
          )}

          {mode === 'reviewing' && controller.review && (
            <div className="composer-review">
              <div className="composer-source">
                <p className="composer-source-text">{controller.text}</p>
                <button type="button" className="composer-source-edit" onClick={() => controller.editText()}>
                  Edit
                </button>
              </div>
              <hr className="hairline" />
              <EditableReviewPanel
                resolved={controller.review}
                onClose={() => controller.editText()}
                onSaved={() => controller.handleSaved()}
              />
            </div>
          )}

          {mode === 'saved' && <CaptureStatus mode={mode} />}
        </div>
      )}
    </section>
  )
}
