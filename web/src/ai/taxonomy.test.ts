import { describe, expect, it } from 'vitest'
import { taxonomyListErrorMessage } from './taxonomy'

describe('taxonomyListErrorMessage', () => {
  it('distinguishes rejected access from a server missing the callable', () => {
    expect(taxonomyListErrorMessage({ code: 'functions/permission-denied' })).toContain('access was rejected')
    expect(taxonomyListErrorMessage({ code: 'functions/not-found' })).toContain('server build')
  })

  it('uses a retriable message for other failures', () => {
    expect(taxonomyListErrorMessage(new Error('offline'))).toContain('try again')
  })
})
