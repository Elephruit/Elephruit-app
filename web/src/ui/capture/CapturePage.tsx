import { useRef, useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { AICaptureError, parseCapture } from '../../ai/anthropic'
import { aiCaptureReady, storedAPIKey, storedModel } from '../../ai/settings'
import { resolveProposal, type ResolvedCapture } from '../../domain/assist'
import { usePeople } from '../../data/hooks'
import { useUID } from '../UserContext'
import { Button } from '../components/Button'
import { Icon } from '../components/Icon'
import { PageScaffold } from '../shell/PageScaffold'
import { ReviewSheet } from './ReviewSheet'

const EXAMPLES = [
  'Coffee with Ana. Her son starts at South High this fall. Need to send her the neighborhood list.',
  'Called Marisol about the co-op vote — she is leaning yes. Follow up Friday.',
  "Met Jonas's partner Elke at the gallery. She teaches printmaking in Oakland.",
]

export function CapturePage() {
  const uid = useUID()
  const navigate = useNavigate()
  const people = usePeople(uid)
  const textareaRef = useRef<HTMLTextAreaElement>(null)
  const [text, setText] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [review, setReview] = useState<ResolvedCapture | null>(null)

  const ready = aiCaptureReady()
  const canParse = ready && text.trim().length > 0 && !busy && people !== undefined
  const canLogManually = text.trim().length > 0

  async function parse() {
    const apiKey = storedAPIKey()
    if (!apiKey || !canParse) return
    setBusy(true)
    setError(null)
    try {
      const proposal = await parseCapture(text, {
        apiKey,
        model: storedModel(),
        context: {
          today: new Date(),
          peopleNames: (people ?? []).filter((p) => p.hasStatedName).map((p) => p.displayName),
        },
      })
      setReview(resolveProposal(proposal, people ?? [], new Date()))
    } catch (cause) {
      setError(cause instanceof AICaptureError ? cause.message : 'Something went wrong. Your text is kept.')
    } finally {
      setBusy(false)
    }
  }

  function logManually() {
    if (canLogManually) navigate(`/log?text=${encodeURIComponent(text)}`)
  }

  return (
    <PageScaffold width="narrow">
      <div className="capture-workspace">
        <header className="capture-header">
          <h1 className="page-title">What happened?</h1>
          <p>One box for the whole thought — who it was, what you learned, what you owe.</p>
        </header>

        <textarea
          ref={textareaRef}
          className="field field-hero"
          value={text}
          onChange={(event) => setText(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) {
              event.preventDefault()
              if (canParse) void parse()
              else logManually()
            }
          }}
          placeholder="Speak or type — everything on your mind about the conversation."
          autoFocus
        />
        <p className="capture-hint mobile-only">On a phone, the keyboard's mic button dictates straight into this box.</p>

        {text.trim().length === 0 && (
          <div className="capture-examples">
            <span>Try</span>
            {EXAMPLES.map((example) => (
              <button
                key={example}
                type="button"
                className="chip"
                onClick={() => {
                  setText(example)
                  textareaRef.current?.focus()
                }}
              >
                {example.split('.')[0]}…
              </button>
            ))}
          </div>
        )}

        {!ready && (
          <div className="callout">
            <Icon name="sparkle" size={18} />
            <p>
              <Link to="/settings">Link an Anthropic API key in Settings</Link> and this box parses itself into
              interactions, facts, relationships, and follow-ups — always shown for review before anything is saved.
            </p>
          </div>
        )}

        {error && (
          <p className="field-error" role="alert">
            {error}
          </p>
        )}

        <div className="capture-actions">
          <Button variant="quiet" disabled={!canLogManually} onClick={logManually}>
            Log manually
          </Button>
          {ready && (
            <Button variant="primary" icon="sparkle" loading={busy} disabled={!canParse} onClick={() => void parse()}>
              {busy ? 'Reading…' : 'Parse with AI'}
            </Button>
          )}
        </div>
      </div>

      {review && (
        <ReviewSheet
          items={review.items}
          warnings={review.warnings}
          onClose={() => setReview(null)}
          onSaved={() => navigate('/')}
        />
      )}
    </PageScaffold>
  )
}
