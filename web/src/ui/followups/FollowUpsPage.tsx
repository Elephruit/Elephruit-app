import { useMemo, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { Avatar } from '../components/Avatar'
import { Button, IconButton } from '../components/Button'
import { SegmentedControl } from '../components/SegmentedControl'
import { SkeletonRows } from '../components/Skeleton'
import { PageHeader } from '../shell/PageHeader'
import { PageScaffold } from '../shell/PageScaffold'
import { planCompleteReminder, planQuickReschedule, planReopenReminder, planUpdateReminder } from '../../domain/capture'
import { relativeDescription } from '../../domain/contact'
import { isSameDay, startOfDay } from '../../domain/dates'
import { BUCKET_TITLES, bucketFor, completedList, sections, type Reminder } from '../../domain/reminders'
import { formatScheduleSummary } from '../../domain/temporal'
import { applyPlan } from '../../data/applyPlan'
import { categoryKey, uniqueCategoryTags } from '../../domain/categoryTags'
import { useFolders, useLiveReminders, usePeople } from '../../data/hooks'
import { folderTint } from '../../domain/folder'
import { useUID } from '../UserContext'
import { EmptyState } from '../components/EmptyState'
import { Icon } from '../components/Icon'
import { DEFAULT_FOLLOWUP_CATEGORIES, categoryTintStyle } from './categoryStyle'
import { InlineFollowUpComposer } from './InlineFollowUpComposer'
import {
  FollowUpFilterBar,
  type FollowUpDueFilter,
  type FollowUpResponsibilityFilter,
  type FollowUpStatusFilter,
} from './FollowUpFilterBar'

/// The structured schedule chip — never the title's embedded phrase. Someday
/// rows sit under their heading, so the chip is redundant there.
function dateChip(reminder: Reminder, now: Date): { text: string; tone: 'overdue' | 'today' | null } | null {
  if (reminder.isSomeday) return null
  const summary = formatScheduleSummary(reminder)
  if (!summary) return null
  const text = summary.replace(/^(Due|Starts) /, '')
  const bucket = bucketFor(reminder, now)
  if (bucket === 'overdue') return { text, tone: 'overdue' }
  if (bucket === 'today') return { text, tone: 'today' }
  return { text, tone: null }
}

/// The quick action follows the schedule mode: a deadline moves, a start-only
/// item starts, an unscheduled one gets scheduled — the copy says which.
function quickAction(reminder: Reminder): { label: string; kind: 'deadline' | 'start' } {
  if (reminder.dueAt) return { label: 'Move to tomorrow', kind: 'deadline' }
  if (reminder.startAt) return { label: 'Move to tomorrow', kind: 'start' }
  return { label: 'Schedule tomorrow', kind: 'deadline' }
}

function matchesDueFilter(reminder: Reminder, filter: FollowUpDueFilter, now: Date): boolean {
  if (filter === 'any') return true
  if (filter === 'none') return reminder.dueAt === null
  if (!reminder.dueAt) return false
  const today = startOfDay(now)
  if (filter === 'today') return isSameDay(reminder.dueAt, today)
  const tomorrow = new Date(today)
  tomorrow.setDate(tomorrow.getDate() + 1)
  if (filter === 'tomorrow') return isSameDay(reminder.dueAt, tomorrow)
  const end = new Date(today)
  end.setDate(end.getDate() + 7)
  return reminder.dueAt.getTime() >= today.getTime() && reminder.dueAt.getTime() < end.getTime()
}

export function FollowUpsPage() {
  const uid = useUID()
  const navigate = useNavigate()
  const live = useLiveReminders(uid)
  const people = usePeople(uid)
  const folders = useFolders(uid)
  const [view, setView] = useState<'open' | 'completed'>('open')
  const [ownership, setOwnership] = useState<FollowUpResponsibilityFilter>('all')
  const [editing, setEditing] = useState<Reminder | null>(null)
  const [createRequest, setCreateRequest] = useState(0)
  const [statusFilter, setStatusFilter] = useState<FollowUpStatusFilter>('all')
  const [personFilter, setPersonFilter] = useState('')
  const [dueFilter, setDueFilter] = useState<FollowUpDueFilter>('any')
  const [categoryFilter, setCategoryFilter] = useState('')
  // One clock per mount — a fresh Date each render silently drifted past the memo.
  const [now] = useState(() => new Date())

  const scopedReminders = useMemo(
    () =>
      ownership === 'all'
        ? live
        : live?.filter((reminder) => (reminder.responsibility ?? 'mine') === ownership),
    [live, ownership],
  )
  const groups = useMemo(() => (scopedReminders ? sections(scopedReminders, now) : undefined), [scopedReminders, now])
  const done = useMemo(() => (live ? completedList(live) : []), [live])
  const peopleByID = useMemo(() => new Map((people ?? []).map((p) => [p.id, p])), [people])
  const foldersByID = useMemo(() => new Map((folders ?? []).map((folder) => [folder.id, folder])), [folders])
  const tagSuggestions = useMemo(
    () =>
      uniqueCategoryTags([
        ...(live ?? []).flatMap((reminder) => reminder.categoryTags ?? []),
        ...DEFAULT_FOLLOWUP_CATEGORIES,
      ]),
    [live],
  )

  const openReminders = useMemo(() => (groups ?? []).flatMap((group) => group.reminders), [groups])
  const filterPeople = useMemo(() => {
    const usedIDs = new Set(openReminders.flatMap((reminder) => reminder.personIDs))
    return (people ?? []).filter((person) => usedIDs.has(person.id))
  }, [openReminders, people])
  const filterCategories = useMemo(
    () => uniqueCategoryTags(openReminders.flatMap((reminder) => reminder.categoryTags ?? [])),
    [openReminders],
  )
  const facetedReminders = useMemo(
    () =>
      openReminders.filter(
        (reminder) =>
          (!personFilter || reminder.personIDs.includes(personFilter)) &&
          matchesDueFilter(reminder, dueFilter, now) &&
          (!categoryFilter ||
            (reminder.categoryTags ?? []).some((tag) => categoryKey(tag) === categoryKey(categoryFilter))),
      ),
    [categoryFilter, dueFilter, now, openReminders, personFilter],
  )
  const facetedGroups = useMemo(() => sections(facetedReminders, now), [facetedReminders, now])
  const visibleGroups = useMemo(
    () =>
      statusFilter === 'all'
        ? facetedGroups
        : facetedGroups.filter((group) =>
            statusFilter === 'unscheduled'
              ? group.bucket === 'anytime' || group.bucket === 'someday'
              : group.bucket === statusFilter,
          ),
    [facetedGroups, statusFilter],
  )
  const hasFilters =
    statusFilter !== 'all' || personFilter !== '' || dueFilter !== 'any' || categoryFilter !== '' || ownership !== 'all'

  function clearFilters() {
    setStatusFilter('all')
    setPersonFilter('')
    setDueFilter('any')
    setCategoryFilter('')
    setOwnership('all')
  }

  function requestCreate() {
    setEditing(null)
    setCreateRequest((request) => request + 1)
  }

  async function complete(reminder: Reminder) {
    await applyPlan(uid, planCompleteReminder(reminder.id, new Date()).plan)
  }

  async function reopen(reminder: Reminder) {
    await applyPlan(uid, planReopenReminder(reminder.id).plan)
  }

  async function rescheduleTomorrow(reminder: Reminder) {
    const tomorrow = new Date(startOfDay(new Date()))
    tomorrow.setDate(tomorrow.getDate() + 1)
    const action = quickAction(reminder)
    if (action.kind === 'start') {
      await applyPlan(uid, planQuickReschedule(reminder.id, tomorrow).plan)
      return
    }
    // Deadline moves stay date-granular; a timed deadline pushed to tomorrow
    // becomes a date-only one rather than inventing a time.
    await applyPlan(
      uid,
      planUpdateReminder(reminder.id, {
        dueAt: tomorrow,
        isSomeday: false,
        duePrecision: 'date',
        scheduleTimeZone: null,
      }).plan,
    )
  }

  return (
    <PageScaffold width="wide">
      <PageHeader
        title="Follow-ups"
        actions={
          <>
            <SegmentedControl
              label="Open or completed"
              options={[
                { value: 'open', label: 'Open' },
                { value: 'completed', label: 'Completed' },
              ]}
              value={view}
              onChange={(next) => {
                setView(next)
                setEditing(null)
              }}
            />
            {view === 'open' && (
              <IconButton
                className="page-header-add"
                label="Add a follow-up"
                icon="plus"
                size={19}
                data-followup-create
                onClick={requestCreate}
              />
            )}
          </>
        }
      />

      <div className="task-inbox">
        {view === 'open' && groups && (
          <FollowUpFilterBar
            status={statusFilter}
            personID={personFilter}
            people={filterPeople}
            due={dueFilter}
            category={categoryFilter}
            categories={filterCategories}
            responsibility={ownership}
            onStatusChange={setStatusFilter}
            onPersonChange={setPersonFilter}
            onDueChange={setDueFilter}
            onCategoryChange={setCategoryFilter}
            onResponsibilityChange={setOwnership}
            onClear={clearFilters}
          />
        )}

        {view === 'open' && groups && people && (
          <InlineFollowUpComposer
            people={people}
            tagSuggestions={tagSuggestions}
            activationRequest={createRequest}
            hideTrigger
          />
        )}

        {groups === undefined && <SkeletonRows count={5} />}

        {view === 'open' && groups && groups.length === 0 && (
          <EmptyState
            icon="bell"
            headline={
              ownership === 'all'
                ? 'No follow-ups yet'
                : ownership === 'mine'
                  ? 'Nothing on your plate'
                  : 'Not waiting on anyone'
            }
            message={
              ownership === 'theirs'
                ? 'Delegated work and requested updates gather here until they are complete.'
                : 'Follow-ups from logged interactions gather here, bucketed by what their dates actually say.'
            }
            hint={
              ownership === 'theirs'
                ? 'Try “I asked Alex to send the forecast by Friday.”'
                : 'Try “I need to send her the list.”'
            }
          />
        )}

        {view === 'open' && groups && groups.length > 0 && visibleGroups.length === 0 && (
          <div className="followup-filter-empty">
            <Icon name="filter" size={18} />
            <span>No follow-ups match these filters.</span>
            {hasFilters && (
              <button type="button" onClick={clearFilters}>
                Clear filters
              </button>
            )}
          </div>
        )}

        {view === 'open' &&
          visibleGroups.map((group) => (
            <section key={group.bucket}>
              <h2 className="section-header" data-tone={group.bucket === 'overdue' ? 'overdue' : undefined}>
                {BUCKET_TITLES[group.bucket]}
              </h2>
              {group.reminders.map((reminder) => {
                const chip = dateChip(reminder, now)
                if (editing?.id === reminder.id && people) {
                  return (
                    <InlineFollowUpComposer
                      key={reminder.id}
                      existing={reminder}
                      people={people}
                      tagSuggestions={tagSuggestions}
                      onClose={() =>
                        setEditing((current) => (current?.id === reminder.id ? null : current))
                      }
                    />
                  )
                }
                return (
                  <div key={reminder.id} className="task-row">
                    <button
                      type="button"
                      className="complete-ring"
                      aria-label={`Complete ${reminder.title}`}
                      onClick={() => void complete(reminder)}
                    />
                    <button type="button" className="task-main" onClick={() => setEditing(reminder)}>
                      <span className="row-title">{reminder.title}</span>
                      <span className="task-meta">
                        {(() => {
                          // What it belongs to, when it belongs to something.
                          // Without this the trip's work and the day's work are
                          // indistinguishable here, and the page's whole claim
                          // is that they are the same list seen differently.
                          const folder = reminder.folderID ? foldersByID.get(reminder.folderID) : undefined
                          if (!folder) return null
                          return (
                            <span
                              role="link"
                              tabIndex={0}
                              className="task-container"
                              style={{ '--tint': folderTint(folder.colorName) } as React.CSSProperties}
                              onClick={(event) => {
                                event.stopPropagation()
                                navigate(`/folders/${folder.id}`)
                              }}
                              onKeyDown={(event) => event.key === 'Enter' && navigate(`/folders/${folder.id}`)}
                            >
                              <Icon name="folder" size={13} />
                              {folder.title}
                            </span>
                          )
                        })()}
                        {chip && (
                          <span
                            className={
                              chip.tone === 'overdue'
                                ? 'chip chip-status-overdue'
                                : chip.tone === 'today'
                                  ? 'chip chip-status-today'
                                  : 'chip'
                            }
                          >
                            {chip.text}
                          </span>
                        )}
                        {reminder.responsibility === 'theirs' && reminder.progress && reminder.progress !== 'notStarted' && (
                          <span className="chip">{reminder.progress === 'blocked' ? 'Blocked' : 'In progress'}</span>
                        )}
                        {reminder.personIDs.map((id) => {
                          const person = peopleByID.get(id)
                          if (!person) return null
                          return (
                            <span
                              key={id}
                              role="link"
                              tabIndex={0}
                              className="task-person"
                              onClick={(event) => {
                                event.stopPropagation()
                                navigate(`/people/${id}`)
                              }}
                              onKeyDown={(event) => event.key === 'Enter' && navigate(`/people/${id}`)}
                            >
                              <Avatar name={person.displayName} colorName={person.colorName} small />
                              {person.displayName}
                            </span>
                          )
                        })}
                        {uniqueCategoryTags(reminder.categoryTags ?? []).map((tag) => (
                          <span key={tag} className="task-category" style={categoryTintStyle(tag)}>
                            <span className="category-option-dot" aria-hidden="true" />
                            {tag}
                          </span>
                        ))}
                      </span>
                    </button>
                    <span className="task-actions">
                      <Button variant="ghost" small onClick={() => void rescheduleTomorrow(reminder)}>
                        {quickAction(reminder).label}
                      </Button>
                    </span>
                  </div>
                )
              })}
            </section>
          ))}

        {view === 'open' && groups && people && (
          <button
            type="button"
            className="inline-followup-trigger"
            data-followup-create
            onClick={requestCreate}
          >
            <span className="inline-followup-plus" aria-hidden="true">
              <Icon name="plus" size={17} />
            </span>
            <span>Add a follow-up</span>
          </button>
        )}

        {view === 'completed' && (
          <section>
            {done.length === 0 && <p className="row-subtitle">Nothing completed yet.</p>}
            {done.map((reminder) => (
              <div key={reminder.id} className="task-row task-row-done">
                <button
                  type="button"
                  className="button button-plain"
                  style={{ padding: 0, color: 'var(--color-completed)', height: 'auto' }}
                  aria-label={`Reopen ${reminder.title}`}
                  onClick={() => void reopen(reminder)}
                >
                  <Icon name="check-circle" size={20} />
                </button>
                <span className="row-title">{reminder.title}</span>
                {reminder.completedAt && (
                  <span className="row-trailing">{relativeDescription(reminder.completedAt, now)}</span>
                )}
              </div>
            ))}
          </section>
        )}
      </div>

    </PageScaffold>
  )
}
