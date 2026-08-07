import { HttpsError } from 'firebase-functions/v2/https'
import { describe, expect, it } from 'vitest'
import { PublicError, toHttpsError } from './errors.js'

describe('toHttpsError', () => {
  it('carries the public code in details and the public message', () => {
    const error = toHttpsError(new PublicError('CREDENTIAL_NOT_FOUND', 'No such credential.'))
    expect(error).toBeInstanceOf(HttpsError)
    expect(error.code).toBe('not-found')
    expect(error.message).toBe('No such credential.')
    expect(error.details).toEqual({ code: 'CREDENTIAL_NOT_FOUND' })
  })

  it('flattens unexpected errors into INTERNAL without leaking their message', () => {
    const error = toHttpsError(new Error('ECONNREFUSED api.internal:8443 with sk-ant-something in the message'))
    expect(error.code).toBe('internal')
    expect(error.message).toBe('Something went wrong on our side.')
    expect(error.details).toEqual({ code: 'INTERNAL' })
    expect(JSON.stringify({ message: error.message, details: error.details })).not.toContain('sk-ant')
  })

  it('passes through an HttpsError untouched', () => {
    const original = new HttpsError('unauthenticated', 'Sign in first.')
    expect(toHttpsError(original)).toBe(original)
  })
})
