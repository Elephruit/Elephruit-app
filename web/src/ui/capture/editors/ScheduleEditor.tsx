/// The one schedule control: mode as a radio-semantics segmented choice, then
/// only the fields the active mode needs, with the interpreted result read
/// back in words. Used by the follow-up draft editor in review and by the
/// standalone follow-up sheet — nobody keeps a second copy of date logic.

import { useId, useMemo, useState } from 'react'
import { toLocalDateValue } from '../../dateInput'
import {
  formatScheduleSummary,
  resolveScheduleDraft,
  type ScheduleDraftFields,
  type ScheduleMode,
} from '../../../domain/temporal'
import { SegmentedControl } from '../../components/SegmentedControl'

const MODE_OPTIONS: ReadonlyArray<{ value: ScheduleMode; label: string }> = [
  { value: 'none', label: 'No date' },
  { value: 'deadline', label: 'Deadline' },
  { value: 'start', label: 'Starts' },
  { value: 'someday', label: 'Someday' },
]

const MODE_HELP: Record<ScheduleMode, string> = {
  none: 'Stays in Anytime until you schedule or complete it.',
  deadline: 'Turns overdue after this.',
  start: 'Appears on this date but never becomes overdue.',
  someday: 'Deliberately parked without a date.',
}

function quickDate(base: Date, addDays: number): string {
  const d = new Date(base)
  d.setDate(d.getDate() + addDays)
  return toLocalDateValue(d)
}

function nextMonday(base: Date): string {
  const d = new Date(base)
  const shift = (8 - d.getDay()) % 7 || 7
  d.setDate(d.getDate() + shift)
  return toLocalDateValue(d)
}

export function ScheduleEditor({
  value,
  onChange,
  sourceText,
  userZone,
}: {
  value: ScheduleDraftFields
  onChange: (next: ScheduleDraftFields) => void
  /// The parsed phrase this schedule came from — "Monday 10am CT".
  sourceText?: string | null
  userZone: string
}) {
  const dateID = useId()
  const [showTime, setShowTime] = useState(value.localTime.length > 0)
  const now = useMemo(() => new Date(), [])

  const hasDateFields = value.scheduleMode === 'deadline' || value.scheduleMode === 'start'
  const showZone = showTime && value.localTime.length > 0
  const zones = useMemo(() => Intl.supportedValuesOf('timeZone'), [])

  const interpreted = useMemo(() => {
    if (!hasDateFields || !value.localDate) return null
    return formatScheduleSummary(resolveScheduleDraft(value, { timeZone: userZone }))
  }, [value, hasDateFields, userZone])

  function set(changes: Partial<ScheduleDraftFields>) {
    onChange({ ...value, ...changes })
  }

  return (
    <div className="schedule-editor">
      <SegmentedControl
        options={MODE_OPTIONS}
        value={value.scheduleMode}
        onChange={(mode) => {
          // Typed date/time survives mode flips during the session; only the
          // active mode's fields are saved.
          set({ scheduleMode: mode, timeZone: value.timeZone || userZone })
        }}
        label="When?"
      />
      <p className="field-help">{MODE_HELP[value.scheduleMode]}</p>

      {hasDateFields && (
        <>
          {sourceText && <p className="schedule-detected">Detected from “{sourceText}”</p>}
          <div className="schedule-quick">
            {value.scheduleMode === 'deadline' && (
              <>
                <button type="button" className="chip" onClick={() => set({ localDate: quickDate(now, 0) })}>
                  Today
                </button>
                <button type="button" className="chip" onClick={() => set({ localDate: quickDate(now, 1) })}>
                  Tomorrow
                </button>
                <button type="button" className="chip" onClick={() => set({ localDate: nextMonday(now) })}>
                  Next Monday
                </button>
                <button type="button" className="chip" onClick={() => set({ localDate: quickDate(now, 7) })}>
                  Next week
                </button>
              </>
            )}
          </div>
          <div className="schedule-fields">
            <label className="field-label" htmlFor={dateID}>
              Date
            </label>
            <input
              id={dateID}
              type="date"
              className="field"
              value={value.localDate}
              onChange={(event) => set({ localDate: event.target.value })}
            />
            {!showTime && (
              <button type="button" className="button-plain button" onClick={() => setShowTime(true)}>
                Add time
              </button>
            )}
            {showTime && (
              <>
                <label className="field-label" htmlFor={`${dateID}-time`}>
                  Time
                </label>
                <input
                  id={`${dateID}-time`}
                  type="time"
                  className="field"
                  value={value.localTime}
                  onChange={(event) =>
                    set({ localTime: event.target.value, timeZone: value.timeZone || userZone })
                  }
                />
                <button
                  type="button"
                  className="button-plain button"
                  onClick={() => {
                    setShowTime(false)
                    set({ localTime: '' })
                  }}
                >
                  Remove time
                </button>
              </>
            )}
          </div>
          {showZone && (
            <div className="schedule-fields">
              <label className="field-label" htmlFor={`${dateID}-zone`}>
                Time zone
              </label>
              <select
                id={`${dateID}-zone`}
                className="field field-select"
                value={value.timeZone || userZone}
                onChange={(event) => set({ timeZone: event.target.value })}
              >
                {!zones.includes(value.timeZone) && value.timeZone && (
                  <option value={value.timeZone}>{value.timeZone}</option>
                )}
                {zones.map((zone) => (
                  <option key={zone} value={zone}>
                    {zone}
                  </option>
                ))}
              </select>
            </div>
          )}
          {interpreted && (
            <p className="schedule-interpreted" aria-live="polite">
              {interpreted}
            </p>
          )}
        </>
      )}
    </div>
  )
}
