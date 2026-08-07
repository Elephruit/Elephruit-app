import { describe, expect, it } from 'vitest'
import { newID } from './ids'

describe('newID', () => {
  it('produces RFC 4122 UUIDs that do not repeat', () => {
    const a = newID()
    const b = newID()
    expect(a).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/)
    expect(a).not.toBe(b)
  })
})
