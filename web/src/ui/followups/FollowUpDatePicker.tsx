import { useEffect, useId, useLayoutEffect, useMemo, useRef, useState } from 'react'
import { dateSuggestions, localDateValue } from '../../domain/dateSuggestions'
import { Icon } from '../components/Icon'

const WEEKDAY_LABELS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']

function dateFromValue(value: string): Date | null {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return null
  const [year, month, day] = value.split('-').map(Number)
  const date = new Date(year, month - 1, day, 12)
  return date.getFullYear() === year && date.getMonth() === month - 1 && date.getDate() === day ? date : null
}

function addDays(date: Date, days: number): Date {
  const next = new Date(date)
  next.setDate(next.getDate() + days)
  next.setHours(12, 0, 0, 0)
  return next
}

function nextMonday(now: Date): Date {
  return addDays(now, ((8 - now.getDay()) % 7) || 7)
}

function formatShort(date: Date): string {
  return new Intl.DateTimeFormat(undefined, { weekday: 'short', month: 'short', day: 'numeric' }).format(date)
}

function monthTitle(date: Date): string {
  return new Intl.DateTimeFormat(undefined, { month: 'long', year: 'numeric' }).format(date)
}

function calendarDays(month: Date): Date[] {
  const first = new Date(month.getFullYear(), month.getMonth(), 1, 12)
  const gridStart = addDays(first, -first.getDay())
  return Array.from({ length: 42 }, (_, index) => addDays(gridStart, index))
}

export function FollowUpDatePicker({
  value,
  timeValue,
  onSelect,
  onTimeChange,
  onClear,
  onDone,
  onExitBackward,
  onExitForward,
  autoFocus = false,
}: {
  value: string
  timeValue: string
  onSelect: (localDate: string) => void
  onTimeChange: (localTime: string) => void
  onClear: () => void
  onDone: () => void
  onExitBackward?: () => void
  onExitForward?: () => void
  autoFocus?: boolean
}) {
  const suggestionListID = useId()
  const now = useMemo(() => new Date(), [])
  const selected = dateFromValue(value)
  const initial = selected ?? new Date(now.getFullYear(), now.getMonth(), now.getDate(), 12)
  const [query, setQuery] = useState('')
  const [activeSuggestion, setActiveSuggestion] = useState(0)
  const [month, setMonth] = useState(() => new Date(initial.getFullYear(), initial.getMonth(), 1, 12))
  const [activeDate, setActiveDate] = useState(() => localDateValue(initial))
  const calendarRef = useRef<HTMLDivElement>(null)
  const inputRef = useRef<HTMLInputElement>(null)
  const pickerRef = useRef<HTMLDivElement>(null)
  const suggestions = useMemo(() => dateSuggestions(query, now), [now, query])
  const days = useMemo(() => calendarDays(month), [month])
  const todayValue = localDateValue(now)
  const quickDates = [
    { label: 'Today', date: new Date(now.getFullYear(), now.getMonth(), now.getDate(), 12) },
    { label: 'Tomorrow', date: addDays(now, 1) },
    { label: 'Next Monday', date: nextMonday(now) },
  ]

  useEffect(() => {
    setActiveSuggestion(0)
  }, [query])

  useEffect(() => {
    if (!query || suggestions.length === 0) return
    const frame = window.requestAnimationFrame(() => {
      pickerRef.current
        ?.querySelector<HTMLElement>(`#${CSS.escape(`${suggestionListID}-option-${Math.min(activeSuggestion, suggestions.length - 1)}`)}`)
        ?.scrollIntoView({ block: 'nearest' })
    })
    return () => window.cancelAnimationFrame(frame)
  }, [activeSuggestion, query, suggestionListID, suggestions.length])

  useLayoutEffect(() => {
    if (query) return
    let secondFrame = 0
    const firstFrame = window.requestAnimationFrame(() => {
      secondFrame = window.requestAnimationFrame(() => {
        pickerRef.current?.scrollIntoView({ behavior: 'smooth', block: 'nearest', inline: 'nearest' })
      })
    })
    return () => {
      window.cancelAnimationFrame(firstFrame)
      window.cancelAnimationFrame(secondFrame)
    }
  }, [query])

  function choose(localDate: string) {
    onSelect(localDate)
  }

  function focusDate(date: Date) {
    const localDate = localDateValue(date)
    setActiveDate(localDate)
    setMonth(new Date(date.getFullYear(), date.getMonth(), 1, 12))
    window.setTimeout(() => {
      calendarRef.current?.querySelector<HTMLButtonElement>(`[data-date="${localDate}"]`)?.focus()
    }, 0)
  }

  function focusSuggestion(index: number) {
    const clamped = Math.max(0, Math.min(index, suggestions.length - 1))
    setActiveSuggestion(clamped)
    window.setTimeout(() => {
      pickerRef.current
        ?.querySelector<HTMLButtonElement>(`#${CSS.escape(`${suggestionListID}-option-${clamped}`)}`)
        ?.focus()
    }, 0)
  }

  function moveMonth(offset: number) {
    const nextMonth = new Date(month.getFullYear(), month.getMonth() + offset, 1, 12)
    const active = dateFromValue(activeDate) ?? nextMonth
    const maxDay = new Date(nextMonth.getFullYear(), nextMonth.getMonth() + 1, 0).getDate()
    focusDate(new Date(nextMonth.getFullYear(), nextMonth.getMonth(), Math.min(active.getDate(), maxDay), 12))
  }

  function handleSearchKeyDown(event: React.KeyboardEvent<HTMLInputElement>) {
    if (event.key === 'Tab') {
      event.preventDefault()
      if (event.shiftKey) onExitBackward?.()
      else onExitForward?.()
    } else if (event.key === 'ArrowDown') {
      event.preventDefault()
      if (suggestions.length > 0) {
        setActiveSuggestion((index) => Math.min(index + 1, suggestions.length - 1))
      } else if (!query) {
        focusDate(dateFromValue(activeDate) ?? initial)
      }
    } else if (event.key === 'ArrowUp' && suggestions.length > 0) {
      event.preventDefault()
      setActiveSuggestion((index) => Math.max(index - 1, 0))
    } else if (event.key === 'Enter' && suggestions.length > 0) {
      event.preventDefault()
      choose(suggestions[Math.min(activeSuggestion, suggestions.length - 1)].localDate)
    } else if (event.key === 'Escape' && query) {
      event.preventDefault()
      event.stopPropagation()
      setQuery('')
    }
  }

  function handleSuggestionKeyDown(event: React.KeyboardEvent<HTMLButtonElement>, index: number) {
    if (event.key === 'ArrowDown') {
      event.preventDefault()
      focusSuggestion(index + 1)
    } else if (event.key === 'ArrowUp') {
      event.preventDefault()
      focusSuggestion(index - 1)
    } else if (event.key === 'Enter' || event.key === ' ') {
      event.preventDefault()
      choose(suggestions[index].localDate)
    } else if (event.key === 'Tab') {
      event.preventDefault()
      if (event.shiftKey) onExitBackward?.()
      else onExitForward?.()
    }
  }

  function handleDayKeyDown(event: React.KeyboardEvent<HTMLButtonElement>, date: Date) {
    let next: Date | null = null
    if (event.key === 'Tab') {
      event.preventDefault()
      if (event.shiftKey) onExitBackward?.()
      else onExitForward?.()
      return
    }
    if (event.key === 'Enter' || event.key === ' ') {
      event.preventDefault()
      choose(localDateValue(date))
      return
    }
    if (event.key === 'ArrowLeft') next = addDays(date, -1)
    else if (event.key === 'ArrowRight') next = addDays(date, 1)
    else if (event.key === 'ArrowUp') next = addDays(date, -7)
    else if (event.key === 'ArrowDown') next = addDays(date, 7)
    else if (event.key === 'Home') next = addDays(date, -date.getDay())
    else if (event.key === 'End') next = addDays(date, 6 - date.getDay())
    else if (event.key === 'PageUp' || event.key === 'PageDown') {
      event.preventDefault()
      moveMonth(event.key === 'PageUp' ? -1 : 1)
      return
    }
    if (!next) return
    event.preventDefault()
    focusDate(next)
  }

  return (
    <div ref={pickerRef} className="followup-date-picker">
      <div className="followup-date-search">
        <input
          ref={inputRef}
          type="text"
          inputMode="text"
          autoComplete="off"
          autoFocus={autoFocus}
          value={query}
          aria-label="Type a due date"
          aria-controls={suggestionListID}
          aria-activedescendant={suggestions.length ? `${suggestionListID}-option-${activeSuggestion}` : undefined}
          placeholder="Type a date — 8, 8/8, Thursday"
          onChange={(event) => setQuery(event.target.value)}
          onKeyDown={handleSearchKeyDown}
        />
        {query && (
          <button type="button" className="followup-date-search-clear" aria-label="Clear typed date" onClick={() => setQuery('')}>
            <Icon name="x" size={15} />
          </button>
        )}
      </div>

      {query ? (
        <div id={suggestionListID} className="followup-date-suggestions" role="listbox" aria-label="Date suggestions">
          {suggestions.map((suggestion, index) => (
            <button
              id={`${suggestionListID}-option-${index}`}
              key={suggestion.id}
              type="button"
              role="option"
              aria-selected={index === activeSuggestion}
              data-active={index === activeSuggestion || undefined}
              tabIndex={index === activeSuggestion ? 0 : -1}
              onMouseEnter={() => setActiveSuggestion(index)}
              onFocus={() => setActiveSuggestion(index)}
              onKeyDown={(event) => handleSuggestionKeyDown(event, index)}
              onClick={() => choose(suggestion.localDate)}
            >
              <span className="followup-date-suggestion-main"><Icon name="calendar" size={16} />{suggestion.label}</span>
              <span>{suggestion.detail}</span>
            </button>
          ))}
          {suggestions.length === 0 && (
            <p className="followup-date-empty">Try “8”, “8/8”, “Thursday”, “today”, or “tomorrow”.</p>
          )}
        </div>
      ) : (
        <>
          <div className="followup-date-quick" aria-label="Quick dates">
            {quickDates.map((choice) => {
              const localDate = localDateValue(choice.date)
              return (
                <button key={choice.label} type="button" aria-pressed={value === localDate} onClick={() => choose(localDate)}>
                  <strong>{choice.label}</strong>
                  <span>{formatShort(choice.date)}</span>
                </button>
              )
            })}
          </div>

          <div ref={calendarRef} className="followup-calendar">
            <div className="followup-calendar-header">
              <strong>{monthTitle(month)}</strong>
              <span>
                <button type="button" aria-label="Previous month" onClick={() => moveMonth(-1)}><Icon name="back" size={17} /></button>
                <button type="button" aria-label="Next month" onClick={() => moveMonth(1)}><Icon name="chevron" size={17} /></button>
              </span>
            </div>
            <div className="followup-calendar-weekdays" aria-hidden="true">
              {WEEKDAY_LABELS.map((label) => <span key={label}>{label}</span>)}
            </div>
            <div className="followup-calendar-grid" role="grid" aria-label={monthTitle(month)}>
              {days.map((date) => {
                const localDate = localDateValue(date)
                const outside = date.getMonth() !== month.getMonth()
                return (
                  <button
                    key={localDate}
                    type="button"
                    role="gridcell"
                    data-date={localDate}
                    data-outside={outside || undefined}
                    data-today={localDate === todayValue || undefined}
                    aria-label={new Intl.DateTimeFormat(undefined, { dateStyle: 'full' }).format(date)}
                    aria-selected={localDate === value}
                    tabIndex={localDate === activeDate ? 0 : -1}
                    onFocus={() => setActiveDate(localDate)}
                    onKeyDown={(event) => handleDayKeyDown(event, date)}
                    onClick={() => choose(localDate)}
                  >
                    {date.getDate()}
                  </button>
                )
              })}
            </div>
          </div>
        </>
      )}

      {value && (
        <div className="followup-date-footer">
          <label className="followup-time-field">
            <span>Time</span>
            <input
              type="time"
              value={timeValue}
              aria-label="Due time"
              onChange={(event) => onTimeChange(event.target.value)}
              onKeyDown={(event) => {
                if (event.key !== 'Tab') return
                event.preventDefault()
                if (event.shiftKey) onExitBackward?.()
                else onExitForward?.()
              }}
            />
          </label>
          <button
            type="button"
            className="button button-quiet button-small"
            onClick={onClear}
            onKeyDown={(event) => {
              if (event.key !== 'Tab') return
              event.preventDefault()
              if (event.shiftKey) onExitBackward?.()
              else onExitForward?.()
            }}
          >
            Clear date
          </button>
          <button
            type="button"
            className="button button-secondary button-small"
            onClick={onDone}
            onKeyDown={(event) => {
              if (event.key !== 'Tab') return
              event.preventDefault()
              if (event.shiftKey) onExitBackward?.()
              else onExitForward?.()
            }}
          >
            Done
          </button>
        </div>
      )}
    </div>
  )
}
