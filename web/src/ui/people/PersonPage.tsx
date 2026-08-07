/// A person's page answers, in order: who is this, what happened with them,
/// what matters now, what to remember next. The header is the identity — for
/// an unnamed person the relationship word and distinguishing facts, never
/// just a possessive phrase. The board has one document scroll: active work
/// stays in the main column while supporting context sits alongside it.

import { useMemo, useState } from 'react'
import { useNavigate, useParams } from 'react-router-dom'
import {
  planCompleteReminder,
  planRenamePerson,
  planReopenReminder,
  planUpdatePersonContext,
} from '../../domain/capture'
import { deriveLastContact, lastContactLine } from '../../domain/contact'
import { FactAttributes, currentValues, populatedAttributes, type FactAttribute } from '../../domain/facts'
import { relationshipIdentitySummary } from '../../domain/personIdentity'
import {
  FILTER_LABELS,
  entryIsContact,
  groupByMonth,
  matchesFilter,
  provenanceLine,
  projectPersonTimeline,
  type TimelineEntry,
  type TimelineFilter,
} from '../../domain/timeline'
import { summarizePerson } from '../../domain/personSummary'
import { profileFocusOf, type ConnectionOrigin, type Person } from '../../domain/person'
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
import { fromLocalMonthValue, toLocalMonthValue } from '../dateInput'
import { PageScaffold } from '../shell/PageScaffold'
import { FactsSection } from './FactsSection'
import { CommitmentBoard } from './CommitmentBoard'
import { RelationshipsSection } from './RelationshipsSection'
import { TalkingPointsPanel } from './TalkingPointsPanel'
import { PersonInteractionComposer } from './PersonInteractionComposer'

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

const PROFESSIONAL_ATTRIBUTES: FactAttribute[] = [
  FactAttributes.employer,
  FactAttributes.role,
  FactAttributes.lookingFor,
  FactAttributes.currentProject,
  FactAttributes.professionalGoal,
  FactAttributes.painPoint,
  FactAttributes.decisionRole,
  FactAttributes.stakeholder,
  FactAttributes.promise,
  FactAttributes.significance,
]

const PERSONAL_ATTRIBUTES: FactAttribute[] = [
  FactAttributes.preferredName,
  FactAttributes.pronouns,
  FactAttributes.email,
  FactAttributes.phone,
  FactAttributes.timeZone,
  FactAttributes.language,
  FactAttributes.birthday,
  FactAttributes.anniversary,
  FactAttributes.contactCadence,
  FactAttributes.family,
  FactAttributes.observedAge,
  FactAttributes.schoolGrade,
  FactAttributes.school,
  FactAttributes.interest,
  FactAttributes.like,
  FactAttributes.dislike,
  FactAttributes.foodAndDrink,
  FactAttributes.lifeEvent,
  FactAttributes.location,
  FactAttributes.conversationTopic,
  FactAttributes.communicationPreference,
  FactAttributes.giftIdea,
  FactAttributes.quickFact,
  FactAttributes.reflection,
]

function ConnectionContextDialog({
  person,
  people,
  onClose,
  onSave,
}: {
  person: Person
  people: Person[]
  onClose: () => void
  onSave: (origin: ConnectionOrigin) => Promise<void>
}) {
  const existing = person.connectionOrigin
  const [status, setStatus] = useState<ConnectionOrigin['status']>(existing?.status ?? 'unknown')
  const [firstMetOn, setFirstMetOn] = useState(() => existing?.firstMetOn ? toLocalMonthValue(existing.firstMetOn) : '')
  const [context, setContext] = useState(existing?.context ?? '')
  const [introducedByPersonID, setIntroducedByPersonID] = useState(existing?.introducedByPersonID ?? '')
  const [saving, setSaving] = useState(false)

  return (
    <Dialog title="How you know each other" onClose={onClose}>
      <label className="field-label" htmlFor="connection-status">Connection status</label>
      <select id="connection-status" className="field" value={status} onChange={(event) => setStatus(event.target.value as ConnectionOrigin['status'])}>
        <option value="unknown">Not recorded</option>
        <option value="introductionPlanned">Introduction planned</option>
        <option value="met">Already met</option>
      </select>
      <label className="field-label" htmlFor="connection-date">{status === 'introductionPlanned' ? 'First meeting' : 'First met'}</label>
      <input id="connection-date" className="field" type="month" value={firstMetOn} onChange={(event) => setFirstMetOn(event.target.value)} />
      <label className="field-label" htmlFor="connection-introducer">Introduced by</label>
      <select id="connection-introducer" className="field" value={introducedByPersonID} onChange={(event) => setIntroducedByPersonID(event.target.value)}>
        <option value="">Nobody recorded</option>
        {people.filter((candidate) => candidate.id !== person.id).map((candidate) => <option key={candidate.id} value={candidate.id}>{candidate.displayName}</option>)}
      </select>
      <label className="field-label" htmlFor="connection-context">Context</label>
      <input id="connection-context" className="field" value={context} onChange={(event) => setContext(event.target.value)} placeholder="Conference, project, dinner, mutual friend…" />
      <div className="sheet-actions">
        <Button variant="quiet" onClick={onClose}>Cancel</Button>
        <Button variant="primary" loading={saving} onClick={() => {
          setSaving(true)
          void onSave({
            status,
            firstMetOn: firstMetOn ? fromLocalMonthValue(firstMetOn) : null,
            context: context.trim() || null,
            introducedByPersonID: introducedByPersonID || null,
          }).finally(() => setSaving(false))
        }}>Save context</Button>
      </div>
    </Dialog>
  )
}

function WorkDetailsDialog({
  person,
  role,
  organization,
  onClose,
  onSave,
}: {
  person: Person
  role: string
  organization: string
  onClose: () => void
  onSave: (details: { roleTitle: string | null; organizationName: string | null }) => Promise<void>
}) {
  const [nextRole, setNextRole] = useState(role)
  const [nextOrganization, setNextOrganization] = useState(organization)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)

  return (
    <Dialog title={`Role and company for ${person.displayName}`} onClose={onClose}>
      <label className="field-label" htmlFor="person-role-title">Role</label>
      <input
        id="person-role-title"
        className="field"
        value={nextRole}
        onChange={(event) => setNextRole(event.target.value)}
        placeholder="Managing director"
        autoFocus
      />
      <label className="field-label" htmlFor="person-organization-name">Company</label>
      <input
        id="person-organization-name"
        className="field"
        value={nextOrganization}
        onChange={(event) => setNextOrganization(event.target.value)}
        placeholder="BCG"
      />
      {error && <p className="field-error" role="alert">{error}</p>}
      <div className="sheet-actions">
        <Button variant="quiet" onClick={onClose}>Cancel</Button>
        <Button
          variant="primary"
          loading={saving}
          onClick={() => {
            setSaving(true)
            setError(null)
            void onSave({
              roleTitle: nextRole.trim() || null,
              organizationName: nextOrganization.trim() || null,
            }).catch((cause) => {
              setError(cause instanceof Error ? cause.message : 'Could not save work details.')
              setSaving(false)
            })
          }}
        >
          Save work details
        </Button>
      </div>
    </Dialog>
  )
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
  const allRelationships = useAllRelationships(uid)
  const [filter, setFilter] = useState<TimelineFilter>('everything')
  const [renaming, setRenaming] = useState(false)
  const [newName, setNewName] = useState('')
  const [savingName, setSavingName] = useState(false)
  const [menuOpen, setMenuOpen] = useState(false)
  const [addFactSignal, setAddFactSignal] = useState(0)
  const [addRelationshipSignal, setAddRelationshipSignal] = useState(0)
  const [loggingInteraction, setLoggingInteraction] = useState(false)
  const [editingConnection, setEditingConnection] = useState(false)
  const [editingWork, setEditingWork] = useState(false)
  const [now] = useState(() => new Date())

  const entries = useMemo(() => {
    if (!interactions || !observations || !reminders || !people) return undefined
    const byID = new Map(people.map((p) => [p.id, p]))
    return projectPersonTimeline({
      interactions,
      observations,
      reminders,
      peopleByID: byID,
      viewpointPersonID: personID!,
    })
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

  const summary = useMemo(() => {
    if (!person || !people || !observations || !relationships || !interactions || !reminders) return null
    return summarizePerson({ person, people, observations, relationships, interactions, reminders, now })
  }, [person, people, observations, relationships, interactions, reminders, now])

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
  const roleLine = [summary?.role, summary?.organization].filter(Boolean).join(' at ')

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

  const focus = summary?.focus ?? profileFocusOf(person)
  const populated = populatedAttributes(observations ?? [])
  const detailAttributes = populated.filter(
    (attribute) => attribute !== FactAttributes.employer && attribute !== FactAttributes.role,
  )
  const preferredPrimary = focus === 'professional' ? PROFESSIONAL_ATTRIBUTES : PERSONAL_ATTRIBUTES
  const explicitContext = (attribute: FactAttribute) =>
    currentValues(observations ?? [], attribute).find((observation) => observation.context)?.context
  const isPrimaryAttribute = (attribute: FactAttribute) => {
    const context = explicitContext(attribute)
    if (context === 'identity') return true
    if (context) return context === focus
    return preferredPrimary.includes(attribute)
  }
  const primaryAttributes = detailAttributes.filter(isPrimaryAttribute)
  const secondaryAttributes = detailAttributes.filter((attribute) => !isPrimaryAttribute(attribute))
  const originParts = [
    `${focus === 'professional' ? 'Professional' : 'Personal'} connection`,
    summary?.introducedBy ? `Introduced by ${summary.introducedBy.displayName}` : null,
  ].filter(Boolean)

  const firstMetLine = summary?.firstMetOn
    ? `${summary.firstMeetingPlanned ? 'First meeting' : 'First met'} ${summary.firstMetOn.toLocaleDateString(undefined, { month: 'short', year: 'numeric' })}${summary.firstMetContext ? ` · ${summary.firstMetContext}` : ''}`
    : summary?.firstMetContext
      ? `How you met · ${summary.firstMetContext}`
      : null

  return (
    <PageScaffold width="wide" className="person-page">
      <button type="button" className="backlink" onClick={() => navigate(-1)}>
        <Icon name="back" size={14} /> Back
      </button>

      <div className="person-cols">
        <div className="person-history">
        <header className="profile-header">
          <Avatar name={person.displayName} colorName={person.colorName} size="lg" unnamed={!person.hasStatedName} />
          <div className="profile-id">
            <h1>
              {identityTitle}
              {!person.hasStatedName && <span className="profile-badge">Name unknown</span>}
            </h1>
            {person.hasStatedName ? (
              <p className="profile-connection-line">
                {roleLine || 'No role or company recorded'}
                <button type="button" className="profile-context-edit" onClick={() => setEditingWork(true)}>
                  {roleLine ? 'Edit role and company' : 'Add role and company'}
                </button>
              </p>
            ) : identitySubtitle ? <p>{identitySubtitle}</p> : null}
            <p className="profile-connection-line">
              {originParts.join(' · ')}
              <button type="button" className="profile-context-edit" onClick={() => setEditingConnection(true)}>
                {originParts.length > 1 || firstMetLine ? 'Edit' : 'Add how you met'}
              </button>
            </p>
            <div className="profile-contact-meta">
              {firstMetLine && <p className="profile-first-met">{firstMetLine}</p>}
              <p className="profile-last">{lastContactLine(derivedLastContact, now, hasProfileData)}</p>
            </div>
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
            <Button variant="primary" icon="plus" onClick={() => setLoggingInteraction((open) => !open)}>
              Log interaction
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
                    setEditingWork(true)
                  }}
                >
                  Edit role and company
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
                <button
                  type="button"
                  role="menuitem"
                  className="memory-menu-item"
                  onClick={() => {
                    setMenuOpen(false)
                    setEditingConnection(true)
                  }}
                >
                  Edit how you met
                </button>
                <button
                  type="button"
                  role="menuitem"
                  className="memory-menu-item"
                  onClick={() => {
                    setMenuOpen(false)
                    void applyPlan(uid, planUpdatePersonContext(person, {
                      profileFocus: focus === 'professional' ? 'personal' : 'professional',
                    }).plan)
                  }}
                >
                  Use {focus === 'professional' ? 'personal' : 'professional'} layout
                </button>
              </div>
            )}
            </span>
          </div>
        </header>

        {loggingInteraction && <PersonInteractionComposer person={person} onClose={() => setLoggingInteraction(false)} />}

          <div className="person-primary-context">
            <FactsSection
              person={person}
              observations={observations ?? []}
              title={focus === 'professional' ? 'Work context' : 'Personal context'}
              includeAttributes={primaryAttributes}
              addSignal={addFactSignal}
              emphasis="primary"
              hideWhenEmpty
            />

            {openFollowUps.length > 0 && (
              <CommitmentBoard
                person={person}
                reminders={reminders ?? []}
                now={now}
                onComplete={(reminderID) => void toggleReminder(reminderID, true)}
              />
            )}
          </div>

          <div className="history-head">
            <div>
              <h2>Interaction log</h2>
              <p>Conversations, notes, and follow-ups in one working history.</p>
            </div>
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

        <aside className="person-context remember-rail" aria-label="Person context">
          <div className="profile-next" aria-label="Next time">
            <h2 className="remember-eyebrow">Next up</h2>
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
          </div>
          {observations && secondaryAttributes.length > 0 && (
            <FactsSection
              person={person}
              observations={observations}
              title={focus === 'professional' ? 'Personal context' : 'Professional context'}
              includeAttributes={secondaryAttributes}
            />
          )}
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
      {editingConnection && people && (
        <ConnectionContextDialog
          person={person}
          people={people}
          onClose={() => setEditingConnection(false)}
          onSave={async (origin) => {
            await applyPlan(uid, planUpdatePersonContext(person, { connectionOrigin: origin }).plan)
            setEditingConnection(false)
          }}
        />
      )}
      {editingWork && (
        <WorkDetailsDialog
          person={person}
          role={summary?.role ?? ''}
          organization={summary?.organization ?? ''}
          onClose={() => setEditingWork(false)}
          onSave={async (details) => {
            await applyPlan(
              uid,
              planUpdatePersonContext(person, {
                ...details,
                ...(details.roleTitle || details.organizationName ? { profileFocus: 'professional' as const } : {}),
              }).plan,
            )
            setEditingWork(false)
          }}
        />
      )}
    </PageScaffold>
  )
}
