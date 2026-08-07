import { describe, expect, it } from 'vitest'
import { fromLocalMonthValue, toLocalMonthValue } from './dateInput'

describe('month input', () => {
  it('formats a date at month precision', () => {
    expect(toLocalMonthValue(new Date(2026, 6, 18, 15))).toBe('2026-07')
  })

  it('parses the selected month without crossing a time-zone boundary', () => {
    expect(fromLocalMonthValue('2026-07')).toEqual(new Date(2026, 6, 1, 12))
    expect(fromLocalMonthValue('July 2026')).toBeNull()
  })
})
