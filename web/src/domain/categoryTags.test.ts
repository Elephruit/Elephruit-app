import { describe, expect, it } from 'vitest'
import { categoryKey, uniqueCategoryTags } from './categoryTags'

describe('category tags', () => {
  it('uses case-insensitive identity while preserving the first display spelling', () => {
    expect(categoryKey(' Work ')).toBe('work')
    expect(uniqueCategoryTags(['work', 'Work', ' WAITING ', 'waiting'])).toEqual(['work', 'WAITING'])
  })

  it('drops blanks', () => {
    expect(uniqueCategoryTags(['', '  ', 'Personal'])).toEqual(['Personal'])
  })
})
