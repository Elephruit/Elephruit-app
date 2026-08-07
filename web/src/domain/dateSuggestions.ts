import { startOfDay, wholeDaysBetween } from './dates'

export interface DateSuggestion {
  id: string
  localDate: string
  label: string
  detail: string
}

const WEEKDAYS = [
  { name: 'sunday', aliases: ['sun'] },
  { name: 'monday', aliases: ['mon'] },
  { name: 'tuesday', aliases: ['tue', 'tues'] },
  { name: 'wednesday', aliases: ['wed'] },
  { name: 'thursday', aliases: ['thu', 'thur', 'thurs'] },
  { name: 'friday', aliases: ['fri'] },
  { name: 'saturday', aliases: ['sat'] },
] as const

function pad(number: number): string {
  return String(number).padStart(2, '0')
}

export function localDateValue(date: Date): string {
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`
}

function atNoon(year: number, month: number, day: number): Date | null {
  const date = new Date(year, month, day, 12)
  return date.getFullYear() === year && date.getMonth() === month && date.getDate() === day ? date : null
}

function monthDayLabel(date: Date, showYear: boolean): string {
  return new Intl.DateTimeFormat(undefined, {
    month: 'long',
    day: 'numeric',
    year: showYear ? 'numeric' : undefined,
  }).format(date)
}

function shortDateLabel(date: Date): string {
  return new Intl.DateTimeFormat(undefined, { weekday: 'short', month: 'short', day: 'numeric' }).format(date)
}

function weekdayLabel(date: Date): string {
  return new Intl.DateTimeFormat(undefined, { weekday: 'short' }).format(date)
}

function nextDayOfMonth(day: number, now: Date): Date | null {
  const today = startOfDay(now)
  for (let offset = 0; offset < 14; offset += 1) {
    const monthStart = new Date(now.getFullYear(), now.getMonth() + offset, 1, 12)
    const candidate = atNoon(monthStart.getFullYear(), monthStart.getMonth(), day)
    if (candidate && candidate.getTime() >= today.getTime()) return candidate
  }
  return null
}

function nextWeekday(weekday: number, now: Date, weeksAhead: number): Date {
  const date = startOfDay(now)
  const firstShift = (weekday - date.getDay() + 7) % 7 || 7
  date.setDate(date.getDate() + firstShift + weeksAhead * 7)
  date.setHours(12)
  return date
}

function suggestion(date: Date, label: string, detail: string): DateSuggestion {
  const localDate = localDateValue(date)
  return { id: `${localDate}-${label}`, localDate, label, detail }
}

function deduplicate(suggestions: DateSuggestion[]): DateSuggestion[] {
  const seen = new Set<string>()
  return suggestions.filter((item) => {
    if (seen.has(item.localDate)) return false
    seen.add(item.localDate)
    return true
  })
}

/// Things-style typed date proposals. A bare number can mean a day of this or
/// next month *or* a relative number of days; month/day proposes future years;
/// weekday prefixes propose the next three matching weekdays.
export function dateSuggestions(query: string, now: Date): DateSuggestion[] {
  const text = query.trim().toLocaleLowerCase()
  if (!text) return []

  if ('today'.startsWith(text)) {
    const date = startOfDay(now)
    date.setHours(12)
    return [suggestion(date, 'Today', shortDateLabel(date))]
  }
  if ('tomorrow'.startsWith(text)) {
    const date = startOfDay(now)
    date.setDate(date.getDate() + 1)
    date.setHours(12)
    return [suggestion(date, 'Tomorrow', shortDateLabel(date))]
  }

  const monthDay = text.match(/^(\d{1,2})\/(\d{1,2})(?:\/(\d{2,4}))?$/)
  if (monthDay) {
    const month = Number(monthDay[1]) - 1
    const day = Number(monthDay[2])
    if (month < 0 || month > 11 || day < 1 || day > 31) return []
    if (monthDay[3]) {
      let year = Number(monthDay[3])
      if (year < 100) year += 2000
      const date = atNoon(year, month, day)
      return date ? [suggestion(date, monthDayLabel(date, true), weekdayLabel(date))] : []
    }

    const suggestions: DateSuggestion[] = []
    let year = now.getFullYear()
    while (suggestions.length < 3 && year < now.getFullYear() + 5) {
      const date = atNoon(year, month, day)
      if (date && date.getTime() >= startOfDay(now).getTime()) {
        suggestions.push(suggestion(date, monthDayLabel(date, year !== now.getFullYear()), weekdayLabel(date)))
      }
      year += 1
    }
    return suggestions
  }

  const numberOnly = text.match(/^\d{1,3}$/)
  if (numberOnly) {
    const number = Number(text)
    const suggestions: DateSuggestion[] = []
    if (number >= 1 && number <= 31) {
      const date = nextDayOfMonth(number, now)
      if (date) suggestions.push(suggestion(date, monthDayLabel(date, false), weekdayLabel(date)))
    }
    if (number >= 1 && number <= 365) {
      const date = startOfDay(now)
      date.setDate(date.getDate() + number)
      date.setHours(12)
      suggestions.push(suggestion(date, `in ${number} day${number === 1 ? '' : 's'}`, shortDateLabel(date)))
    }
    return deduplicate(suggestions)
  }

  const weekday = WEEKDAYS.find(
    (candidate) => candidate.name.startsWith(text) || candidate.aliases.some((alias) => alias.startsWith(text)),
  )
  if (weekday) {
    const weekdayIndex = WEEKDAYS.indexOf(weekday)
    return [0, 1, 2].map((week) => {
      const date = nextWeekday(weekdayIndex, now, week)
      const days = wholeDaysBetween(now, date)
      return suggestion(date, shortDateLabel(date), `in ${days} days`)
    })
  }

  return []
}
