/// "Prepare me for my day" — the read direction of the AI street, on the feed.
/// The user picks who the brief covers (preseeded with everyone attached to an
/// overdue or today follow-up), sees plainly what will be sent, and gets back
/// talking points, open loops, and questions per person. Read-only by
/// construction: this panel builds no WritePlan.

import { useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { generateDayBrief, type DayBrief } from '../../ai/briefing'
import { AICaptureError } from '../../ai/anthropic'
import { activeCredential } from '../../ai/credentials'
import { storedModel } from '../../ai/settings'
import { useAiCredentials, useAllObservations, useAllRelationships } from '../../data/hooks'
import { briefingInputFor, defaultBriefingPersonIDs } from '../../domain/briefing'
import type { Observation } from '../../domain/facts'
import type { Interaction } from '../../domain/interaction'
import type { Person } from '../../domain/person'
import type { Reminder } from '../../domain/reminders'
import { useUID } from '../UserContext'
import { Avatar } from '../components/Avatar'
import { Button, IconButton } from '../components/Button'
import { Icon } from '../components/Icon'
import { ParticipantPicker } from '../log/ParticipantPicker'

export function DayBriefPanel({
  people,
  reminders,
  interactions,
  onClose,
}: {
  people: Person[]
  reminders: Reminder[]
  interactions: Interaction[]
  onClose: () => void
}) {
  const uid = useUID()
  const observations = useAllObservations(uid)
  const relationships = useAllRelationships(uid)
  const [selectedIDs, setSelectedIDs] = useState<Set<string>>(
    () => new Set(defaultBriefingPersonIDs(reminders, new Date())),
  )
  const [brief, setBrief] = useState<DayBrief | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const credentials = useAiCredentials(uid)
  const credential = activeCredential(credentials)
  const ready = credential !== null
  const peopleByID = useMemo(() => new Map(people.map((p) => [p.id, p])), [people])
  const peopleByName = useMemo(() => new Map(people.map((p) => [p.displayName, p])), [people])
  const loaded = observations !== undefined && relationships !== undefined
  const canGenerate = ready && loaded && selectedIDs.size > 0 && !busy

  function toggle(id: string) {
    setSelectedIDs((current) => {
      const next = new Set(current)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  async function generate() {
    if (!credential || !canGenerate) return
    setBusy(true)
    setError(null)
    try {
      const targets = people.filter((person) => selectedIDs.has(person.id))
      const byPerson = new Map<string, Observation[]>()
      for (const observation of observations ?? []) {
        if (!selectedIDs.has(observation.subjectID)) continue
        const list = byPerson.get(observation.subjectID) ?? []
        list.push(observation)
        byPerson.set(observation.subjectID, list)
      }
      const input = briefingInputFor(
        targets,
        byPerson,
        relationships ?? [],
        peopleByID,
        reminders,
        interactions,
        new Date(),
      )
      setBrief(await generateDayBrief(input, { credentialId: credential.id, model: storedModel() }))
    } catch (cause) {
      setError(cause instanceof AICaptureError ? cause.message : 'Something went wrong. Nothing was lost.')
    } finally {
      setBusy(false)
    }
  }

  return (
    <section className="brief-panel" aria-label="Day brief">
      <div className="brief-head">
        <h2>
          <Icon name="sparkle" size={16} /> Prepare my day
        </h2>
        <IconButton label="Close the brief" icon="x" onClick={onClose} />
      </div>

      {!brief && (
        <>
          <p className="brief-note">
            Who are you seeing? Started with everyone attached to an overdue or today follow-up.
          </p>
          <ParticipantPicker
            people={people}
            pendingNew={[]}
            selectedIDs={selectedIDs}
            onToggle={toggle}
            onCreate={() => {}}
            allowCreate={false}
          />
          <p className="brief-privacy">
            Sent under your key: current facts (never restricted ones), relationships, open follow-ups, and recent
            interactions for the people selected.
          </p>

          {credentials !== undefined && !ready && (
            <div className="callout">
              <Icon name="sparkle" size={18} />
              <p>
                <Link to="/settings">Link an Anthropic API key in Settings</Link> to generate briefs. Your data goes
                out under your own key, and only when you ask.
              </p>
            </div>
          )}

          {error && (
            <p className="field-error" role="alert">
              {error}
            </p>
          )}

          <div className="sheet-actions">
            {ready && (
              <Button variant="primary" icon="sparkle" loading={busy} disabled={!canGenerate} onClick={() => void generate()}>
                {busy ? 'Preparing…' : 'Prepare the brief'}
              </Button>
            )}
          </div>
        </>
      )}

      {brief && (
        <div className="brief-results">
          {brief.dayNote && <p className="brief-daynote">{brief.dayNote}</p>}
          {brief.people.map((entry) => {
            const person = peopleByName.get(entry.name)
            return (
              <article key={entry.name} className="brief-card">
                <header>
                  {person && <Avatar name={person.displayName} colorName={person.colorName} />}
                  <div>
                    <h3>{entry.name}</h3>
                    <p>{entry.headline}</p>
                  </div>
                </header>
                {entry.talkingPoints.length > 0 && (
                  <div className="brief-section">
                    <h4>Talking points</h4>
                    <ul>
                      {entry.talkingPoints.map((point) => (
                        <li key={point}>{point}</li>
                      ))}
                    </ul>
                  </div>
                )}
                {entry.openLoops.length > 0 && (
                  <div className="brief-section">
                    <h4>Open loops</h4>
                    <ul>
                      {entry.openLoops.map((loop) => (
                        <li key={loop}>{loop}</li>
                      ))}
                    </ul>
                  </div>
                )}
                {entry.suggestedQuestions.length > 0 && (
                  <div className="brief-section">
                    <h4>Worth asking</h4>
                    <ul>
                      {entry.suggestedQuestions.map((question) => (
                        <li key={question}>{question}</li>
                      ))}
                    </ul>
                  </div>
                )}
              </article>
            )
          })}
          <div className="sheet-actions">
            <Button variant="quiet" onClick={() => setBrief(null)}>
              Change who
            </Button>
            <Button variant="secondary" icon="sparkle" loading={busy} onClick={() => void generate()}>
              Refresh
            </Button>
          </div>
        </div>
      )}
    </section>
  )
}
