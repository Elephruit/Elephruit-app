import { describe, expect, it } from 'vitest'
import { dateSuggestions } from './dateSuggestions'

const NOW = new Date(2026, 7, 6, 15)

describe('dateSuggestions', () => {
  it('offers day-of-month and relative interpretations for a bare number', () => {
    expect(dateSuggestions('8', NOW).map(({ localDate, label }) => ({ localDate, label }))).toEqual([
      { localDate: '2026-08-08', label: 'August 8' },
      { localDate: '2026-08-14', label: 'in 8 days' },
    ])
  })

  it('offers the next three future years for month/day', () => {
    expect(dateSuggestions('8/8', NOW).map((item) => item.localDate)).toEqual([
      '2026-08-08',
      '2027-08-08',
      '2028-08-08',
    ])
  })

  it('offers the next three strictly future matching weekdays', () => {
    expect(dateSuggestions('thur', NOW).map((item) => item.localDate)).toEqual([
      '2026-08-13',
      '2026-08-20',
      '2026-08-27',
    ])
  })

  it('rejects invalid dates', () => {
    expect(dateSuggestions('2/30', NOW)).toEqual([])
  })
})
