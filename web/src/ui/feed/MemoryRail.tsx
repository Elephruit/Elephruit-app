/// The continuous rail: one vertical spine from the composer through every
/// loaded moment. Day markers are hollow nodes with a canvas halo; recent
/// days stay fully expanded, months take over after fourteen days, and the
/// terminal control for older memories is itself a small node on the rail.
/// Insertion animates only moments that arrive after the first ready render.

import { useEffect, useMemo, useRef, useState } from 'react'
import type { MemoryMomentViewModel } from '../../data/memoryProjection'
import { startOfDay, wholeDaysBetween } from '../../domain/dates'
import { MemoryMoment } from './MemoryMoment'

const INITIAL_LIMIT = 30

interface RailGroup {
  key: string
  label: string
  month: boolean
  moments: MemoryMomentViewModel[]
}

function dayLabel(day: Date, now: Date): string {
  const days = wholeDaysBetween(day, startOfDay(now))
  if (days === 0) return 'Today'
  if (days === 1) return 'Yesterday'
  return day.toLocaleDateString(undefined, { weekday: 'long', month: 'long', day: 'numeric' })
}

function groupMoments(moments: MemoryMomentViewModel[], now: Date): RailGroup[] {
  const groups: RailGroup[] = []
  for (const moment of moments) {
    const age = wholeDaysBetween(startOfDay(moment.occurredAt), startOfDay(now))
    let key: string
    let label: string
    let month = false
    if (age <= 14) {
      const day = startOfDay(moment.occurredAt)
      key = `day-${day.getTime()}`
      label = dayLabel(day, now)
    } else {
      month = true
      key = `month-${moment.occurredAt.getFullYear()}-${moment.occurredAt.getMonth()}`
      label = moment.occurredAt.toLocaleDateString(undefined, { month: 'long', year: 'numeric' })
    }
    const last = groups[groups.length - 1]
    if (last && last.key === key) last.moments.push(moment)
    else groups.push({ key, label, month, moments: [moment] })
  }
  return groups
}

export function MemoryRail({
  moments,
  now,
  inlineAfterFirstGroup,
}: {
  moments: MemoryMomentViewModel[]
  now: Date
  /// The compact Next up module rendered after Today below the wide breakpoint.
  inlineAfterFirstGroup?: React.ReactNode
}) {
  const [showAll, setShowAll] = useState(false)
  // Everything present at first ready render is old; only later arrivals play
  // the insertion sequence.
  const seen = useRef<Set<string> | null>(null)
  const [enteringIDs, setEnteringIDs] = useState<Set<string>>(new Set())

  useEffect(() => {
    if (seen.current === null) {
      seen.current = new Set(moments.map((m) => m.id))
      return
    }
    const fresh = moments.filter((m) => !seen.current!.has(m.id))
    if (fresh.length === 0) return
    for (const m of fresh) seen.current.add(m.id)
    setEnteringIDs(new Set(fresh.map((m) => m.id)))
    const timer = window.setTimeout(() => setEnteringIDs(new Set()), 400)
    return () => window.clearTimeout(timer)
  }, [moments])

  const visible = showAll ? moments : moments.slice(0, INITIAL_LIMIT)
  const groups = useMemo(() => groupMoments(visible, now), [visible, now])
  const hiddenCount = moments.length - visible.length

  return (
    <div className="memory-rail" data-extending={enteringIDs.size > 0 || undefined}>
      {groups.map((group, groupIndex) => (
        <section key={group.key} className="memory-day" data-month={group.month || undefined}>
          <header className="memory-day-header">
            <span className="memory-rail-col" aria-hidden="true">
              <span className="memory-date-node" />
            </span>
            <h2 className="memory-day-title">{group.label}</h2>
          </header>
          {group.moments.map((moment, index) => (
            <MemoryMoment
              key={moment.id}
              moment={moment}
              now={now}
              entering={enteringIDs.has(moment.id)}
              last={
                index === group.moments.length - 1 &&
                (groupIndex === groups.length - 1 || group.moments.length === 1)
              }
            />
          ))}
          {groupIndex === 0 && inlineAfterFirstGroup}
        </section>
      ))}

      {hiddenCount > 0 && (
        <div className="memory-rail-terminal">
          <span className="memory-rail-col" aria-hidden="true">
            <span className="memory-date-node" />
          </span>
          <button type="button" className="memory-show-earlier" onClick={() => setShowAll(true)}>
            Show earlier memories ({hiddenCount})
          </button>
        </div>
      )}
    </div>
  )
}
