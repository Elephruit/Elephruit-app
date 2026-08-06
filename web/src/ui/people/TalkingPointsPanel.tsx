/// The person-sized slice of the day brief: one click, one person, the same
/// read-only pipeline. Restricted facts stay out of the payload by the same
/// domain rule; nothing here writes.

import { useState } from 'react'
import { Link } from 'react-router-dom'
import { AICaptureError } from '../../ai/anthropic'
import { generateDayBrief, type DayBrief } from '../../ai/briefing'
import { aiCaptureReady, storedAPIKey, storedModel } from '../../ai/settings'
import { briefingInputFor } from '../../domain/briefing'
import type { Observation } from '../../domain/facts'
import type { Interaction } from '../../domain/interaction'
import type { Person } from '../../domain/person'
import type { Relationship } from '../../domain/relationships'
import type { Reminder } from '../../domain/reminders'
import { Button } from '../components/Button'

export function TalkingPointsPanel({
  person,
  people,
  observations,
  relationships,
  reminders,
  interactions,
}: {
  person: Person
  people: Person[]
  observations: Observation[]
  relationships: Relationship[]
  reminders: Reminder[]
  interactions: Interaction[]
}) {
  const [brief, setBrief] = useState<DayBrief | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const ready = aiCaptureReady()

  async function generate() {
    const apiKey = storedAPIKey()
    if (!apiKey || busy) return
    setBusy(true)
    setError(null)
    try {
      const input = briefingInputFor(
        [person],
        new Map([[person.id, observations]]),
        relationships,
        new Map(people.map((p) => [p.id, p])),
        reminders,
        interactions,
        new Date(),
      )
      setBrief(await generateDayBrief(input, { apiKey, model: storedModel() }))
    } catch (cause) {
      setError(cause instanceof AICaptureError ? cause.message : 'Something went wrong.')
    } finally {
      setBusy(false)
    }
  }

  const entry = brief?.people.find((p) => p.name === person.displayName) ?? brief?.people[0]

  return (
    <div className="aside-panel">
      <div className="aside-panel-head">
        <h2 className="aside-title">Talking points</h2>
        {ready && (
          <Button variant="ghost" small icon="sparkle" loading={busy} onClick={() => void generate()}>
            {entry ? 'Refresh' : 'Prepare'}
          </Button>
        )}
      </div>

      {!ready && (
        <p className="row-subtitle">
          <Link to="/settings" className="inline-link">
            Link an API key
          </Link>{' '}
          to get talking points before you see {person.displayName.split(' ')[0]}.
        </p>
      )}

      {ready && !entry && !error && (
        <p className="row-subtitle">
          Facts, open loops, and recent conversations, turned into what's worth raising. Restricted facts never
          leave this device.
        </p>
      )}

      {error && (
        <p className="field-error" role="alert">
          {error}
        </p>
      )}

      {entry && (
        <div className="brief-inline">
          <p className="brief-inline-headline">{entry.headline}</p>
          {entry.talkingPoints.length > 0 && (
            <ul>
              {entry.talkingPoints.map((point) => (
                <li key={point}>{point}</li>
              ))}
            </ul>
          )}
          {entry.suggestedQuestions.length > 0 && (
            <>
              <p className="brief-inline-label">Worth asking</p>
              <ul>
                {entry.suggestedQuestions.map((question) => (
                  <li key={question}>{question}</li>
                ))}
              </ul>
            </>
          )}
        </div>
      )}
    </div>
  )
}
