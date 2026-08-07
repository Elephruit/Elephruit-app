import { useMemo, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { IconButton } from '../components/Button'
import { SegmentedControl } from '../components/SegmentedControl'
import { SkeletonRows } from '../components/Skeleton'
import { PageHeader } from '../shell/PageHeader'
import { PageScaffold } from '../shell/PageScaffold'
import { planCompleteReminder, planQuickReschedule, planReopenReminder, planUpdateReminder } from '../../domain/capture'
import { relativeDescription } from '../../domain/contact'
import { isSameDay, startOfDay } from '../../domain/dates'
import { BUCKET_TITLES, completedList, sections, type Reminder } from '../../domain/reminders'
import { applyPlan } from '../../data/applyPlan'
import { categoryKey, uniqueCategoryTags } from '../../domain/categoryTags'
import { useFolders, useLiveReminders, usePeople } from '../../data/hooks'
import { descendantIDs, isArchived } from '../../domain/folder'
import { useUID } from '../UserContext'
import { EmptyState } from '../components/EmptyState'
import { Icon } from '../components/Icon'
import { DEFAULT_FOLLOWUP_CATEGORIES } from './categoryStyle'
import { InlineFollowUpComposer } from './InlineFollowUpComposer'
import { FollowUpRow } from './FollowUpRow'
import {
  FollowUpFilterBar,
  type FollowUpDueFilter,
  type FollowUpResponsibilityFilter,
  type FollowUpStatusFilter,
} from './FollowUpFilterBar'

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

const FOLLOW_UP_STATUS_FILTERS: FollowUpStatusFilter[] = ['all', 'overdue', 'today', 'upcoming', 'unscheduled']

function statusFilterFromSearch(value: string | null): FollowUpStatusFilter {
  return FOLLOW_UP_STATUS_FILTERS.includes(value as FollowUpStatusFilter)
    ? (value as FollowUpStatusFilter)
    : 'all'
}

export function FollowUpsPage() {
  const uid = useUID()
  const [searchParams, setSearchParams] = useSearchParams()
  const live = useLiveReminders(uid)
  const people = usePeople(uid)
  const folders = useFolders(uid)
  const [view, setView] = useState<'open' | 'completed'>('open')
  const [ownership, setOwnership] = useState<FollowUpResponsibilityFilter>('all')
  const [editing, setEditing] = useState<Reminder | null>(null)
  const [createRequest, setCreateRequest] = useState(0)
  const statusFilter = statusFilterFromSearch(searchParams.get('status'))
  const [personFilter, setPersonFilter] = useState('')
  const [dueFilter, setDueFilter] = useState<FollowUpDueFilter>('any')
  const [categoryFilter, setCategoryFilter] = useState('')
  const [folderFilter, setFolderFilter] = useState('')
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
  const filterFolders = useMemo(() => (folders ?? []).filter((folder) => !isArchived(folder)), [folders])
  const folderScope = useMemo(
    () =>
      folderFilter && folders
        ? new Set([folderFilter, ...descendantIDs(folders, folderFilter)])
        : null,
    [folderFilter, folders],
  )
  const facetedReminders = useMemo(
    () =>
      openReminders.filter(
        (reminder) =>
          (!personFilter || reminder.personIDs.includes(personFilter)) &&
          matchesDueFilter(reminder, dueFilter, now) &&
          (!folderScope || (!!reminder.folderID && folderScope.has(reminder.folderID))) &&
          (!categoryFilter ||
            (reminder.categoryTags ?? []).some((tag) => categoryKey(tag) === categoryKey(categoryFilter))),
      ),
    [categoryFilter, dueFilter, folderScope, now, openReminders, personFilter],
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
    statusFilter !== 'all' ||
    personFilter !== '' ||
    dueFilter !== 'any' ||
    categoryFilter !== '' ||
    folderFilter !== '' ||
    ownership !== 'all'

  function clearFilters() {
    setSearchParams({}, { replace: true })
    setPersonFilter('')
    setDueFilter('any')
    setCategoryFilter('')
    setFolderFilter('')
    setOwnership('all')
  }

  function changeStatusFilter(next: FollowUpStatusFilter) {
    const nextParams = new URLSearchParams(searchParams)
    if (next === 'all') nextParams.delete('status')
    else nextParams.set('status', next)
    setSearchParams(nextParams, { replace: true })
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
    if (!reminder.dueAt && reminder.startAt) {
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
            folderID={folderFilter}
            folders={filterFolders}
            responsibility={ownership}
            onStatusChange={changeStatusFilter}
            onPersonChange={setPersonFilter}
            onDueChange={setDueFilter}
            onCategoryChange={setCategoryFilter}
            onFolderChange={setFolderFilter}
            onResponsibilityChange={setOwnership}
            onClear={clearFilters}
          />
        )}

        {view === 'open' && groups && people && (
          <InlineFollowUpComposer
            people={people}
            folders={folders ?? []}
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
                if (editing?.id === reminder.id && people) {
                  return (
                    <InlineFollowUpComposer
                      key={reminder.id}
                      existing={reminder}
                      people={people}
                      folders={folders ?? []}
                      tagSuggestions={tagSuggestions}
                      onClose={() =>
                        setEditing((current) => (current?.id === reminder.id ? null : current))
                      }
                    />
                  )
                }
                return (
                  <FollowUpRow
                    key={reminder.id}
                    reminder={reminder}
                    now={now}
                    peopleByID={peopleByID}
                    foldersByID={foldersByID}
                    onComplete={() => void complete(reminder)}
                    onEdit={() => setEditing(reminder)}
                    onReschedule={() => void rescheduleTomorrow(reminder)}
                  />
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
