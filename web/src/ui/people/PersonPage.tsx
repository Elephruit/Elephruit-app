/// A person's page answers, in order: who is this, what happened with them,
/// what matters now, what to remember next. The header is the identity — for
/// an unnamed person the relationship word and distinguishing facts, never
/// just a possessive phrase — and the right rail is one Remember hierarchy:
/// Next time, Open follow-ups, Key facts, People in their life.

import { useMemo, useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import { planCompleteReminder, planRenamePerson, planReopenReminder } from '../../domain/capture'
import { deriveLastContact, lastContactLine } from '../../domain/contact'
import { FactAttributes, currentValues } from '../../domain/facts'
import { relationshipIdentitySummary } from '../../domain/personIdentity'
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
import { formatScheduleSummary } from '../../domain/temporal'
import { bucketFor } from '../../domain/reminders'
import { applyPlan } from '../../data/applyPlan'
import {
  useAllRelationships,
  useObservationsFor,
  usePeople,
  usePerson,
  usePersonInteractions,
  useRelationshipsFor,
  useRemindersFor,
} from '../../data/hooks'
import { useUID } from '../UserContext'
import { Avatar } from '../components/Avatar'
import { Button } from '../components/Button'
import { Dialog } from '../components/Dialog'
import { Icon } from '../components/Icon'
import { SegmentedControl } from '../components/SegmentedControl'
import { SkeletonRows } from '../components/Skeleton'
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

/// The at-a-glance chips: role, location, family, good-to-know — never
/// restricted values, at most three.
const CHIP_ATTRIBUTES = [FactAttributes.role, FactAttributes.location, FactAttributes.family, FactAttributes.quickFact]

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
  const allRelationships = useAllRelationships(uid)
  const [filter, setFilter] = useState<TimelineFilter>('everything')
  const [renaming, setRenaming] = useState(false)
  const [newName, setNewName] = useState('')
  const [savingName, setSavingName] = useState(false)
  const [menuOpen, setMenuOpen] = useState(false)
  const [addFactSignal, setAddFactSignal] = useState(0)
  const [addRelationshipSignal, setAddRelationshipSignal] = useState(0)
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

  // For an unnamed person: how they relate back to whoever recorded them —
  // the reciprocal row carries the other side's word ("son").
  const reverseIdentity = useMemo(() => {
    if (!person || person.hasStatedName || !allRelationships || !people) return null
    const inbound = allRelationships.find((r) => r.otherID === person.id)
    if (!inbound) return null
    const subject = people.find((p) => p.id === inbound.subjectID)
    if (!subject) return null
    return {
      subject,
      summary: relationshipIdentitySummary({
        subject,
        other: person,
        relationship: inbound,
        observations: observations ?? [],
      }),
    }
  }, [person, allRelationships, people, observations])

  const openFollowUps = reminders?.filter((r) => r.status === 'open') ?? []

  if (person === undefined) {
    return (
      <PageScaffold width="wide">
        <SkeletonRows avatar count={7} />
      </PageScaffold>
    )
  }
  if (person === null) {
    return (
      <PageScaffold width="wide">
        <p className="row-subtitle">This record no longer exists.</p>
      </PageScaffold>
    )
  }

  const derivedLastContact = interactions ? deriveLastContact(interactions, person.id) : person.lastContactAt
  const hasProfileData =
    (observations?.length ?? 0) > 0 || (relationships?.length ?? 0) > 0 || (reminders?.length ?? 0) > 0
  const roleLine = [person.roleTitle, person.organizationName].filter(Boolean).join(' · ')

  const chips = CHIP_ATTRIBUTES.flatMap((attribute) =>
    currentValues(observations ?? [], attribute)
      .filter((o) => o.sensitivity !== 'restricted')
      .slice(0, 1)
      .map((o) => ({ attribute, value: o.value })),
  ).slice(0, 3)

  async function toggleReminder(id: string, isOpen: boolean) {
    const { plan } = isOpen ? planCompleteReminder(id, new Date()) : planReopenReminder(id)
    await applyPlan(uid, plan)
  }

  const identityTitle = person.hasStatedName ? person.displayName : (reverseIdentity?.summary.primaryLabel ?? person.displayName)
  const identitySubtitle = person.hasStatedName
    ? roleLine
    : reverseIdentity
      ? [`Related to ${reverseIdentity.subject.displayName}`, ...reverseIdentity.summary.details.map((d) => d.value)].join(
          ' · ',
        )
      : roleLine

  return (
    <PageScaffold width="wide">
      <button type="button" className="backlink" onClick={() => navigate(-1)}>
        <Icon name="back" size={14} /> Back
      </button>

      <header className="profile-header">
        <Avatar name={person.displayName} colorName={person.colorName} size="lg" unnamed={!person.hasStatedName} />
        <div className="profile-id">
          <h1>
            {identityTitle}
            {!person.hasStatedName && <span className="profile-badge">Name unknown</span>}
          </h1>
          {identitySubtitle && <p>{identitySubtitle}</p>}
          <p className="profile-last">{lastContactLine(derivedLastContact, now, hasProfileData)}</p>
          {chips.length > 0 && (
            <div className="profile-chips">
              {chips.map((chip) => (
                <span key={chip.attribute} className="chip" style={{ cursor: 'default' }}>
                  {chip.value}
                </span>
              ))}
            </div>
          )}
        </div>
        <div className="profile-actions">
          <Button variant="primary" icon="plus" onClick={() => navigate(`/?capture=1&person=${person.id}`)}>
            Record a memory
          </Button>
          <span className="memory-actions">
            <button
              type="button"
              className="icon-button"
              aria-label={`More actions for ${person.displayName}`}
              aria-expanded={menuOpen}
              onClick={() => setMenuOpen((open) => !open)}
            >
              <Icon name="other" size={16} />
            </button>
            {menuOpen && (
              <div className="memory-menu" role="menu">
                <button
                  type="button"
                  role="menuitem"
                  className="memory-menu-item"
                  onClick={() => {
                    setMenuOpen(false)
                    setNewName(person.hasStatedName ? person.displayName : '')
                    setRenaming(true)
                  }}
                >
                  {person.hasStatedName ? 'Edit name' : 'Add their name'}
                </button>
                <button
                  type="button"
                  role="menuitem"
                  className="memory-menu-item"
                  onClick={() => {
                    setMenuOpen(false)
                    setAddFactSignal((n) => n + 1)
                  }}
                >
                  Add fact
                </button>
                <button
                  type="button"
                  role="menuitem"
                  className="memory-menu-item"
                  onClick={() => {
                    setMenuOpen(false)
                    setAddRelationshipSignal((n) => n + 1)
                  }}
                >
                  Add relationship
                </button>
              </div>
            )}
          </span>
        </div>
      </header>

      <div className="person-cols">
        <div className="person-history">
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

        <aside className="person-context remember-rail" aria-label="Remember">
          <h2 className="remember-eyebrow">Remember</h2>

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

          {openFollowUps.length > 0 && (
            <section className="rail-section remember-followups">
              <h4 className="rail-section-title">Open follow-ups</h4>
              {openFollowUps.map((reminder) => {
                const bucket = bucketFor(reminder, now)
                const schedule = formatScheduleSummary(reminder) ?? 'Anytime'
                return (
                  <div key={reminder.id} className="rail-row" data-static>
                    <button
                      type="button"
                      className="complete-ring"
                      aria-label={`Complete ${reminder.title}`}
                      onClick={() => void toggleReminder(reminder.id, true)}
                    />
                    <span className="rail-row-text">
                      <b>{reminder.title}</b>
                    </span>
                    <span
                      className="rail-row-when tabular"
                      data-tone={bucket === 'overdue' ? 'overdue' : bucket === 'today' ? 'today' : undefined}
                    >
                      {schedule}
                    </span>
                  </div>
                )
              })}
            </section>
          )}

          {observations && <FactsSection person={person} observations={observations} addSignal={addFactSignal} />}
          {relationships && people && (
            <RelationshipsSection
              person={person}
              relationships={relationships}
              people={people}
              addSignal={addRelationshipSignal}
            />
          )}
        </aside>
      </div>

      {renaming && (
        <Dialog title={person.hasStatedName ? 'Edit name' : 'Add their name'} onClose={() => setRenaming(false)}>
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
