/// The inline "What happened?" composer — the first actionable node on the
/// memory rail. Collapsed it is one 56px rail-connected row; open it expands
/// in place while the accent node and its branch stay fixed, so composing
/// happens inside the feed rather than on a separate page. FeedPage owns the
/// URL (?capture=1) and passes open/close requests; this component owns focus,
/// the textarea, and the embedded review.

import { useEffect, useRef } from 'react'
import { useNavigate } from 'react-router-dom'
import { Link } from 'react-router-dom'
import { Button } from '../components/Button'
import { Icon } from '../components/Icon'
import { EditableReviewPanel } from './EditableReviewPanel'
import { CaptureError, CaptureStatus } from './CaptureStatus'
import { CaptureSuggestions } from './CaptureSuggestions'
import type { CaptureController } from './useCaptureController'

const TEXTAREA_MAX_HEIGHT = 240

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
  const collapsedRef = useRef<HTMLButtonElement>(null)
  const textareaRef = useRef<HTMLTextAreaElement>(null)
  const wasOpen = useRef(false)

  const { mode } = controller
  const open = mode !== 'collapsed'

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

  const primaryAction = controller.ready ? (
    <Button
      variant="primary"
      icon="sparkle"
      loading={mode === 'parsing'}
      disabled={!controller.canParse}
      onClick={() => void controller.parse()}
    >
      {mode === 'parsing' ? 'Reading…' : 'Review memory'}
    </Button>
  ) : (
    <Button variant="primary" disabled={!controller.canLogManually} onClick={logManually}>
      Add details
    </Button>
  )

  return (
    <section className="capture-composer" data-mode={mode}>
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
            <span className="composer-head-label">{mode === 'reviewing' ? 'Review memory' : 'New memory'}</span>
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

          {mode !== 'reviewing' && mode !== 'saved' && (
            <>
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

              {controller.text.trim().length === 0 && mode === 'composing' && (
                <CaptureSuggestions
                  onPick={(example) => {
                    controller.setText(example)
                    textareaRef.current?.focus()
                  }}
                />
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
            </>
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
