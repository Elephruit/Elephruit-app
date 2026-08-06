import { useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { AICaptureError, parseCapture } from '../../ai/anthropic'
import { aiCaptureReady, storedAPIKey, storedModel } from '../../ai/settings'
import { resolveProposal, type ResolvedCapture } from '../../domain/assist'
import { usePeople } from '../../data/hooks'
import { useUID } from '../UserContext'
import { Icon } from '../components/Icon'
import { ReviewSheet } from './ReviewSheet'

export function CapturePage() {
  const uid = useUID()
  const navigate = useNavigate()
  const people = usePeople(uid)
  const [text, setText] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [review, setReview] = useState<ResolvedCapture | null>(null)

  const ready = aiCaptureReady()
  const canParse = ready && text.trim().length > 0 && !busy && people !== undefined

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

  return (
    <main className="page">
      <h1 className="page-title">What happened?</h1>

      <textarea
        className="field"
        style={{ minHeight: 140 }}
        value={text}
        onChange={(event) => setText(event.target.value)}
        placeholder="Speak or type — “Coffee with Ana. Her son starts at South High this fall. Need to send her the neighborhood list.”"
        autoFocus
      />
      <p className="row-subtitle" style={{ marginTop: 'var(--space-tight)' }}>
        On a phone, the keyboard's mic button dictates straight into this box.
      </p>

      {!ready && (
        <p className="row-subtitle" style={{ marginTop: 'var(--space-small)' }}>
          <Link to="/settings" style={{ color: 'var(--color-accent)' }}>
            Link an Anthropic API key in Settings
          </Link>{' '}
          and this box parses itself into interactions, facts, and follow-ups.
        </p>
      )}

      {error && (
        <p role="alert" style={{ color: 'var(--color-destructive)', marginTop: 'var(--space-small)' }}>
          {error}
        </p>
      )}

      <div className="sheet-actions">
        <button
          type="button"
          className="button button-quiet"
          disabled={text.trim().length === 0}
          onClick={() => navigate(`/log?text=${encodeURIComponent(text)}`)}
        >
          Log manually
        </button>
        {ready && (
          <button type="button" className="button" disabled={!canParse} onClick={() => void parse()}>
            <Icon name="sparkle" size={16} />
            {busy ? 'Reading…' : 'Parse with AI'}
          </button>
        )}
      </div>

      {review && (
        <ReviewSheet
          items={review.items}
          warnings={review.warnings}
          onClose={() => setReview(null)}
          onSaved={() => navigate('/')}
        />
      )}
    </main>
  )
}
