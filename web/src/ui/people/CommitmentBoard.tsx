import { useEffect, useLayoutEffect, useMemo, useRef, useState, type KeyboardEvent, type PointerEvent as ReactPointerEvent } from 'react'
import { applyPlan } from '../../data/applyPlan'
import { planUpdateReminder } from '../../domain/capture'
import {
  orderedCommitments,
  ownerAcrossBoundary,
  planCommitmentPlacement,
  previewCommitmentPlacement,
  type CommitmentOwner,
  type CommitmentPlacement,
} from '../../domain/commitmentOrdering'
import type { Person } from '../../domain/person'
import { bucketFor, type Reminder } from '../../domain/reminders'
import { formatScheduleSummary } from '../../domain/temporal'
import { useUID } from '../UserContext'

const CROSS_LANE_HYSTERESIS = 28
const DRAG_THRESHOLD = 5

interface DragState extends CommitmentPlacement {
  started: boolean
  startX: number
  startY: number
  pointerX: number
  pointerY: number
  offsetX: number
  offsetY: number
  width: number
  height: number
}

export function CommitmentBoard({
  person,
  reminders,
  now,
  onComplete,
}: {
  person: Person
  reminders: Reminder[]
  now: Date
  onComplete: (reminderID: string) => void
}) {
  const uid = useUID()
  const boardRef = useRef<HTMLDivElement>(null)
  const laneRefs = useRef<Record<CommitmentOwner, HTMLElement | null>>({ mine: null, theirs: null })
  const dragRef = useRef<DragState | null>(null)
  const beforeRects = useRef<Map<string, DOMRect> | null>(null)
  const [drag, setDrag] = useState<DragState | null>(null)
  const [optimisticPlacement, setOptimisticPlacement] = useState<CommitmentPlacement | null>(null)
  const [inlineEdit, setInlineEdit] = useState<{ id: string; title: string } | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [announcement, setAnnouncement] = useState('')

  const open = useMemo(
    () => reminders.filter((reminder) => reminder.status === 'open' && reminder.personIDs.includes(person.id)),
    [reminders, person.id],
  )
  const activePlacement = drag?.started ? drag : optimisticPlacement
  const lanes = useMemo(
    () =>
      activePlacement
        ? previewCommitmentPlacement(open, person.id, activePlacement)
        : {
            mine: orderedCommitments(open, person.id, 'mine'),
            theirs: orderedCommitments(open, person.id, 'theirs'),
          },
    [open, person.id, activePlacement],
  )

  function captureRects(): Map<string, DOMRect> {
    const rects = new Map<string, DOMRect>()
    boardRef.current?.querySelectorAll<HTMLElement>('[data-commitment-id]').forEach((element) => {
      rects.set(element.dataset.commitmentId!, element.getBoundingClientRect())
    })
    return rects
  }

  // FLIP animation: the pointer chooses the projected insertion, React lays
  // it out, then every displaced sibling eases from its former rectangle.
  useLayoutEffect(() => {
    const previous = beforeRects.current
    if (!previous) return
    beforeRects.current = null
    boardRef.current?.querySelectorAll<HTMLElement>('[data-commitment-id]').forEach((element) => {
      const before = previous.get(element.dataset.commitmentId!)
      if (!before) return
      const after = element.getBoundingClientRect()
      const x = before.left - after.left
      const y = before.top - after.top
      if (Math.abs(x) < 1 && Math.abs(y) < 1) return
      element.animate(
        [{ transform: `translate(${x}px, ${y}px)` }, { transform: 'translate(0, 0)' }],
        { duration: 170, easing: 'cubic-bezier(.2,.8,.2,1)' },
      )
    })
  }, [drag?.owner, drag?.index])

  function publishDrag(next: DragState | null) {
    dragRef.current = next
    setDrag(next)
  }

  function projectedOwner(current: CommitmentOwner, x: number, y: number): CommitmentOwner {
    const mine = laneRefs.current.mine?.getBoundingClientRect()
    const theirs = laneRefs.current.theirs?.getBoundingClientRect()
    if (!mine || !theirs) return current
    const stacked = Math.abs(mine.left - theirs.left) < 40
    if (stacked) {
      const boundary = (mine.bottom + theirs.top) / 2
      return ownerAcrossBoundary(current, y, boundary, CROSS_LANE_HYSTERESIS)
    }
    const boundary = (mine.right + theirs.left) / 2
    return ownerAcrossBoundary(current, x, boundary, CROSS_LANE_HYSTERESIS)
  }

  function projectedIndex(owner: CommitmentOwner, pointerY: number, reminderID: string): number {
    const elements = [...(laneRefs.current[owner]?.querySelectorAll<HTMLElement>('[data-commitment-id]') ?? [])]
      .filter((element) => element.dataset.commitmentId !== reminderID)
    const index = elements.findIndex((element) => pointerY < element.getBoundingClientRect().top + element.getBoundingClientRect().height / 2)
    return index === -1 ? elements.length : index
  }

  useEffect(() => {
    if (!drag) return
    function move(event: PointerEvent) {
      const current = dragRef.current
      if (!current) return
      event.preventDefault()
      const distance = Math.hypot(event.clientX - current.startX, event.clientY - current.startY)
      const started = current.started || distance >= DRAG_THRESHOLD
      if (!started) {
        publishDrag({ ...current, pointerX: event.clientX, pointerY: event.clientY })
        return
      }
      const owner = projectedOwner(current.owner, event.clientX, event.clientY)
      const index = projectedIndex(owner, event.clientY, current.reminderID)
      if (owner !== current.owner || index !== current.index) beforeRects.current = captureRects()
      publishDrag({ ...current, started: true, owner, index, pointerX: event.clientX, pointerY: event.clientY })
    }
    function finish(event: PointerEvent) {
      const current = dragRef.current
      if (!current) return
      event.preventDefault()
      publishDrag(null)
      if (current.started) void commitPlacement(current)
    }
    function cancel() {
      publishDrag(null)
    }
    window.addEventListener('pointermove', move, { passive: false })
    window.addEventListener('pointerup', finish)
    window.addEventListener('pointercancel', cancel)
    return () => {
      window.removeEventListener('pointermove', move)
      window.removeEventListener('pointerup', finish)
      window.removeEventListener('pointercancel', cancel)
    }
    // Installed once per drag; the ref always contains the latest projection.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [drag !== null])

  async function commitPlacement(placement: CommitmentPlacement) {
    const plan = planCommitmentPlacement(open, person.id, placement)
    if (plan.length === 0) return
    const moved = open.find((reminder) => reminder.id === placement.reminderID)
    setOptimisticPlacement(placement)
    setError(null)
    try {
      await applyPlan(uid, plan)
      if (moved) {
        setAnnouncement(`Moved ${moved.title} to ${placement.owner === 'mine' ? 'My next moves' : `Waiting on ${firstName}`}, position ${placement.index + 1}.`)
      }
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Could not move that commitment.')
    } finally {
      setOptimisticPlacement(null)
    }
  }

  function startDrag(event: ReactPointerEvent<HTMLButtonElement>, reminder: Reminder, owner: CommitmentOwner, index: number) {
    if (event.button !== 0) return
    const card = event.currentTarget.closest<HTMLElement>('[data-commitment-id]')
    if (!card) return
    const rect = card.getBoundingClientRect()
    setError(null)
    publishDrag({
      reminderID: reminder.id, owner, index, started: false,
      startX: event.clientX, startY: event.clientY,
      pointerX: event.clientX, pointerY: event.clientY,
      offsetX: event.clientX - rect.left, offsetY: event.clientY - rect.top,
      width: rect.width, height: rect.height,
    })
  }

  function keyboardMove(event: KeyboardEvent<HTMLButtonElement>, reminder: Reminder, owner: CommitmentOwner, index: number) {
    if (!event.altKey) return
    let placement: CommitmentPlacement | null = null
    if (event.key === 'ArrowUp') placement = { reminderID: reminder.id, owner, index: Math.max(0, index - 1) }
    if (event.key === 'ArrowDown') placement = { reminderID: reminder.id, owner, index: Math.min(lanes[owner].length - 1, index + 1) }
    if (event.key === 'ArrowLeft' && owner === 'theirs') placement = { reminderID: reminder.id, owner: 'mine', index: lanes.mine.length }
    if (event.key === 'ArrowRight' && owner === 'mine') placement = { reminderID: reminder.id, owner: 'theirs', index: lanes.theirs.length }
    if (!placement || (placement.owner === owner && placement.index === index)) return
    event.preventDefault()
    void commitPlacement(placement)
  }

  async function commitTitle(reminder: Reminder, title: string) {
    const next = title.trim()
    setInlineEdit(null)
    if (!next || next === reminder.title) return
    await applyPlan(uid, planUpdateReminder(reminder.id, { title: next }).plan)
  }

  const draggedReminder = drag ? open.find((reminder) => reminder.id === drag.reminderID) : null
  const firstName = person.displayName.trim().split(/\s+/)[0] || 'them'
  const laneDetails: Array<{ owner: CommitmentOwner; title: string }> = [
    { owner: 'mine', title: 'My next moves' },
    { owner: 'theirs', title: `Waiting on ${firstName}` },
  ]

  return (
    <section className="person-followups" aria-label="Commitments">
      <div className="aside-panel-head"><h2>Commitments</h2><span>{open.length}</span></div>
      <p id="commitment-drag-help" className="visually-hidden">Drag to reorder or move between columns. With the handle focused, hold Alt and use arrow keys.</p>
      <p className="visually-hidden" aria-live="polite">{announcement}</p>
      {error && <p className="field-error" role="alert">{error}</p>}
      <div ref={boardRef} className="person-followup-board" data-dragging={drag?.started || undefined}>
        {laneDetails.map((lane) => (
          <section
            key={lane.owner}
            ref={(node) => { laneRefs.current[lane.owner] = node }}
            className="person-followup-lane"
            data-owner={lane.owner}
            data-drag-target={drag?.started && drag.owner === lane.owner || undefined}
          >
            <div className="person-followup-lane-head"><h3>{lane.title}</h3><span>{lanes[lane.owner].length}</span></div>
            {lanes[lane.owner].length === 0 ? <p className="person-followup-empty">Drop here.</p> : (
              <div className="person-followup-grid">
                {lanes[lane.owner].map((reminder, index) => {
                  const isDragged = drag?.started && reminder.id === drag.reminderID
                  return (
                    <article key={reminder.id} className="person-followup" data-tone={bucketFor(reminder, now)} data-commitment-id={reminder.id} data-drag-source={isDragged || undefined}>
                      <button type="button" className="commitment-drag-handle" aria-label={`Move ${reminder.title}`} aria-describedby="commitment-drag-help" onPointerDown={(event) => startDrag(event, reminder, lane.owner, index)} onKeyDown={(event) => keyboardMove(event, reminder, lane.owner, index)}><span aria-hidden="true">⠿</span></button>
                      <button type="button" className="complete-ring" aria-label={`Complete ${reminder.title}`} onClick={() => onComplete(reminder.id)} />
                      <div className="person-followup-body">
                        {inlineEdit?.id === reminder.id ? (
                          <input className="inline-text-editor person-followup-editor" aria-label="Edit follow-up title" value={inlineEdit.title} onChange={(event) => setInlineEdit({ id: reminder.id, title: event.target.value })} onBlur={(event) => void commitTitle(reminder, event.target.value)} onKeyDown={(event) => { if (event.key === 'Enter') { event.preventDefault(); void commitTitle(reminder, event.currentTarget.value) } if (event.key === 'Escape') setInlineEdit(null) }} autoFocus />
                        ) : <button type="button" className="person-followup-title" title="Edit follow-up" onClick={() => setInlineEdit({ id: reminder.id, title: reminder.title })}>{reminder.title}</button>}
                        <span className="person-followup-when tabular">{formatScheduleSummary(reminder) ?? 'Anytime'}</span>
                        {lane.owner === 'theirs' && reminder.progress && reminder.progress !== 'notStarted' && <span className="person-followup-progress" data-progress={reminder.progress}>{reminder.progress === 'blocked' ? 'Blocked' : 'In progress'}</span>}
                      </div>
                    </article>
                  )
                })}
              </div>
            )}
          </section>
        ))}
      </div>
      {drag?.started && draggedReminder && (
        <div className="commitment-drag-ghost" style={{ left: drag.pointerX - drag.offsetX, top: drag.pointerY - drag.offsetY, width: drag.width, minHeight: drag.height }} aria-hidden="true">
          <span className="commitment-drag-ghost-handle">⠿</span><span>{draggedReminder.title}</span>
        </div>
      )}
    </section>
  )
}
