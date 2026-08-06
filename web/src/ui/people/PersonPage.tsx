import { useMemo, useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { planCompleteReminder, planRenamePerson, planReopenReminder } from '../../domain/capture'
import { deriveLastContact, lastContactLine } from '../../domain/contact'
import { startOfDay, wholeDaysBetween } from '../../domain/dates'
import { bucketFor } from '../../domain/reminders'
import {
  FILTER_LABELS,
  entryFromInteraction,
  entryFromObservation,
  entryFromReminder,
  entryIsContact,
  groupByMonth,
  matchesFilter,
  provenanceLine,
  type TimelineEntry,
  type TimelineFilter,
} from '../../domain/timeline'
import { applyPlan } from '../../data/applyPlan'
import {
  useObservationsFor,
  usePeople,
  usePerson,
  usePersonInteractions,
  useRelationshipsFor,
  useRemindersFor,
} from '../../data/hooks'
import { useUID } from '../UserContext'
import { Avatar } from '../components/Avatar'
import { Button, IconButton } from '../components/Button'
import { Dialog } from '../components/Dialog'
import { Icon } from '../components/Icon'
import { SegmentedControl } from '../components/SegmentedControl'
import { TimelineRow } from '../components/TimelineRow'
import { PageScaffold } from '../shell/PageScaffold'
import { FactsSection } from './FactsSection'
import { RelationshipsSection } from './RelationshipsSection'
import { TalkingPointsPanel } from './TalkingPointsPanel'

const VISIBLE_FILTERS: TimelineFilter[] = ['everything', 'conversations', 'notes', 'commitments']

function monthLabel(month: Date): string {
  return month.toLocaleDateString(undefined, { month: 'long', year: 'numeric' })
}

function entryBadge(entry: TimelineEntry): { icon: string; tint: string } {
  if (entry.kind === 'interaction') {
    return { icon: entry.interactionKind ?? 'other', tint: 'var(--color-accent)' }
  }
  if (entry.kind === 'reminder') {
    return entry.isOpen
      ? { icon: 'circle', tint: 'var(--color-due-today)' }
      : { icon: 'check', tint: 'var(--color-completed)' }
  }
  return { icon: 'sparkle', tint: 'var(--color-capture)' }
}

export function PersonPage() {
  const uid = useUID()
  const navigate = useNavigate()
  const { personID } = useParams()
  const person = usePerson(uid, personID!)
  const people = usePeople(uid)
  const interactions = usePersonInteractions(uid, personID!)
  const observations = useObservationsFor(uid, personID!)
  const reminders = useRemindersFor(uid, personID!)
  const relationships = useRelationshipsFor(uid, personID!)
  const [filter, setFilter] = useState<TimelineFilter>('everything')
  const [renaming, setRenaming] = useState(false)
  const [newName, setNewName] = useState('')
  const [savingName, setSavingName] = useState(false)
  const now = new Date()

  const entries = useMemo(() => {
    if (!interactions || !observations || !reminders || !people) return undefined
    const byID = new Map(people.map((p) => [p.id, p]))
    return [
      ...interactions.map((i) => entryFromInteraction(i, byID, personID!)),
      ...observations.map(entryFromObservation),
      ...reminders.map(entryFromReminder),
    ]
  }, [interactions, observations, reminders, people, personID])

  const months = useMemo(
    () => (entries ? groupByMonth(entries.filter((e) => matchesFilter(filter, e))) : undefined),
    [entries, filter],
  )

  const openFollowUps = reminders?.filter((r) => r.status === 'open') ?? []

  if (person === undefined) return <PageScaffold width="wide">{null}</PageScaffold>
  if (person === null) {
    return (
      <PageScaffold width="wide">
        <p className="row-subtitle">This record no longer exists.</p>
      </PageScaffold>
    )
  }

  // The page shows the truth, derived live; the list may lean on the cache.
  const derivedLastContact = interactions ? deriveLastContact(interactions, person.id) : person.lastContactAt
  const roleLine = [person.roleTitle, person.organizationName].filter(Boolean).join(' · ')

  async function toggleReminder(id: string, isOpen: boolean) {
    const { plan } = isOpen ? planCompleteReminder(id, new Date()) : planReopenReminder(id)
    await applyPlan(uid, plan)
  }

  return (
    <PageScaffold width="wide">
      <button type="button" className="backlink" onClick={() => navigate(-1)}>
        <Icon name="back" size={14} /> Back
      </button>

      <header className="profile-header">
        <Avatar name={person.displayName} colorName={person.colorName} size="lg" />
        <div className="profile-id">
          <h1>
            {person.displayName}
            <IconButton
              label="Rename"
              icon="pencil"
              onClick={() => {
                setNewName(person.hasStatedName ? person.displayName : '')
                setRenaming(true)
              }}
            />
          </h1>
          {roleLine && <p>{roleLine}</p>}
          <p className="profile-last">{lastContactLine(derivedLastContact, now)}</p>
        </div>
        <div className="profile-actions">
          <Button variant="primary" icon="plus" onClick={() => navigate(`/log?person=${person.id}`)}>
            Log an interaction
          </Button>
        </div>
      </header>

      <div className="person-cols">
        <div className="person-history">
          {openFollowUps.length > 0 && (
            <div className="aside-panel pinned-panel">
              <h4 className="aside-title">Open follow-ups</h4>
              {openFollowUps.map((reminder) => {
                const bucket = bucketFor(reminder, now)
                return (
                  <div key={reminder.id} className="aside-row" data-static>
                    <button
                      type="button"
                      className="complete-ring"
                      aria-label={`Complete ${reminder.title}`}
                      onClick={() => void toggleReminder(reminder.id, true)}
                    />
                    <span className="aside-row-text">
                      <b>{reminder.title}</b>
                    </span>
                    {bucket === 'overdue' && reminder.dueAt && (
                      <span className="chip chip-status-overdue">
                        due {wholeDaysBetween(startOfDay(reminder.dueAt), startOfDay(now))} days ago
                      </span>
                    )}
                    {bucket === 'today' && <span className="chip chip-status-today">due today</span>}
                  </div>
                )
              })}
            </div>
          )}

          <div className="history-head">
            <h2>History</h2>
            <SegmentedControl
              label="Filter history"
              options={VISIBLE_FILTERS.map((f) => ({ value: f, label: FILTER_LABELS[f] }))}
              value={filter}
              onChange={setFilter}
            />
          </div>

          {months && months.length === 0 && (
            <p className="row-subtitle" style={{ padding: 'var(--space-large) 0' }}>
              Nothing here yet.
            </p>
          )}

          {months?.map((group, groupIndex) => (
            <section key={group.month.getTime()}>
              <div className="timeline-day-header">
                <div className="timeline-rail" />
                <h3 className="timeline-month-title">{monthLabel(group.month)}</h3>
              </div>
              {group.entries.map((entry, index) => {
                const badge = entryBadge(entry)
                const isLastRow = groupIndex === months.length - 1 && index === group.entries.length - 1
                return (
                  <TimelineRow
                    key={`${entry.kind}-${entry.id}`}
                    rail={isLastRow ? 'tail' : 'line'}
                    tint={entry.kind === 'interaction' && !entryIsContact(entry) ? 'var(--color-personal)' : badge.tint}
                    badge={<Icon name={badge.icon} size={13} />}
                    badgeLabel={
                      entry.kind === 'reminder'
                        ? entry.isOpen
                          ? `Complete ${entry.title}`
                          : `Reopen ${entry.title}`
                        : undefined
                    }
                    onBadgeClick={
                      entry.kind === 'reminder' ? () => void toggleReminder(entry.id, entry.isOpen) : undefined
                    }
                  >
                    <div className="timeline-title-line">
                      <span className="timeline-title">{entry.title}</span>
                      <span className="timeline-time">
                        {entry.date.toLocaleDateString(undefined, { month: 'short', day: 'numeric' })}
                      </span>
                    </div>
                    <p className="timeline-subtitle">{provenanceLine(entry)}</p>
                    {entry.excerpt && <p className="timeline-excerpt">{entry.excerpt}</p>}
                  </TimelineRow>
                )
              })}
            </section>
          ))}
        </div>

        <aside className="person-context">
          {observations && relationships && reminders && interactions && people && (
            <TalkingPointsPanel
              person={person}
              people={people}
              observations={observations}
              relationships={relationships}
              reminders={reminders}
              interactions={interactions}
            />
          )}
          {observations && <FactsSection person={person} observations={observations} />}
          {relationships && people && (
            <RelationshipsSection person={person} relationships={relationships} people={people} />
          )}
        </aside>
      </div>

      {renaming && (
        <Dialog title="Rename" onClose={() => setRenaming(false)}>
          <p className="row-subtitle">
            Unnamed relatives titled after this person — “{person.displayName}'s son” — are re-phrased in the same
            save.
          </p>
          <input
            className="field"
            style={{ marginTop: 'var(--space-medium)' }}
            value={newName}
            onChange={(event) => setNewName(event.target.value)}
            autoFocus
          />
          <div className="sheet-actions">
            <Button variant="quiet" onClick={() => setRenaming(false)}>
              Cancel
            </Button>
            <Button
              variant="primary"
              loading={savingName}
              disabled={!newName.trim()}
              onClick={() => {
                if (!relationships || !people) return
                setSavingName(true)
                const peopleByID = new Map(people.map((p) => [p.id, p]))
                const { plan } = planRenamePerson(person, newName, relationships, peopleByID, new Date())
                void applyPlan(uid, plan).then(() => {
                  setSavingName(false)
                  setRenaming(false)
                })
              }}
            >
              Save
            </Button>
          </div>
        </Dialog>
      )}
    </PageScaffold>
  )
}
