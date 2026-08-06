/// The capture flow as a hook, extracted from the old CapturePage so the feed
/// composer, and nothing else, owns the UI. Parsing, error handling, review
/// state, and draft persistence live here; the URL (open/closed) stays with
/// FeedPage, which maps ?capture=1 onto open()/collapse(). The hook never
/// navigates and never writes — saving still goes through the review surface
/// and the one applyPlan path.

import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { AICaptureError, parseCapture } from '../../ai/anthropic'
import { activeCredential } from '../../ai/credentials'
import { storedModel } from '../../ai/settings'
import { resolveProposal, type ResolvedCapture } from '../../domain/assist'
import { useAiCredentials, usePeople } from '../../data/hooks'
import { useUID } from '../UserContext'

export type CaptureMode =
  | 'collapsed'
  | 'composing'
  | 'parsing'
  | 'reviewing'
  | 'saving'
  | 'saved'
  | 'error'

const DRAFT_KEY = 'elephruit.captureDraft.v1'
const DRAFT_DEBOUNCE_MS = 300

function readDraft(): string {
  try {
    return sessionStorage.getItem(DRAFT_KEY) ?? ''
  } catch {
    return ''
  }
}

function writeDraft(text: string): void {
  try {
    if (text.length > 0) sessionStorage.setItem(DRAFT_KEY, text)
    else sessionStorage.removeItem(DRAFT_KEY)
  } catch {
    // Private-mode storage failures degrade to an unpersisted draft.
  }
}

export interface CaptureController {
  mode: CaptureMode
  text: string
  setText(text: string): void
  review: ResolvedCapture | null
  error: string | null
  /// An AI credential is linked and usable.
  ready: boolean
  /// A credential exists but the provider stopped accepting it.
  credentialNeedsAttention: boolean
  canParse: boolean
  canLogManually: boolean
  hasDraft: boolean
  /// From ?person=<id> — reconnect and profile entry points preselect a person.
  initialPersonID: string | null
  open(initialPersonID?: string | null): void
  collapse(): void
  parse(): Promise<void>
  /// Reviewing → composing, keeping the text for correction.
  editText(): void
  clearReview(): void
  discardDraft(): void
  /// The review surface saved its plan; show the confirmation beat.
  handleSaved(): void
}

export function useCaptureController(): CaptureController {
  const uid = useUID()
  const people = usePeople(uid)
  const credentials = useAiCredentials(uid)

  const [mode, setMode] = useState<CaptureMode>('collapsed')
  const [text, setTextState] = useState<string>(() => readDraft())
  const [review, setReview] = useState<ResolvedCapture | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [initialPersonID, setInitialPersonID] = useState<string | null>(null)
  const draftTimer = useRef<number | null>(null)

  const credential = activeCredential(credentials)
  const ready = credential !== null
  const credentialNeedsAttention =
    !ready && (credentials ?? []).some((entry) => entry.status === 'invalid' || entry.status === 'revoked')

  const setText = useCallback((next: string) => {
    setTextState(next)
    if (draftTimer.current !== null) window.clearTimeout(draftTimer.current)
    draftTimer.current = window.setTimeout(() => writeDraft(next), DRAFT_DEBOUNCE_MS)
  }, [])

  useEffect(
    () => () => {
      if (draftTimer.current !== null) window.clearTimeout(draftTimer.current)
    },
    [],
  )

  const busy = mode === 'parsing' || mode === 'saving'
  const canParse = ready && text.trim().length > 0 && !busy && people !== undefined
  const canLogManually = text.trim().length > 0

  const open = useCallback((personID?: string | null) => {
    setInitialPersonID(personID ?? null)
    setMode((current) => (current === 'collapsed' ? 'composing' : current))
  }, [])

  const collapse = useCallback(() => {
    // The draft survives; review and errors are transient composer state.
    setMode('collapsed')
    setReview(null)
    setError(null)
  }, [])

  const parse = useCallback(async () => {
    if (!credential || !canParse) return
    setMode('parsing')
    setError(null)
    try {
      const proposal = await parseCapture(text, {
        credentialId: credential.id,
        model: storedModel(),
        context: {
          today: new Date(),
          peopleNames: (people ?? []).filter((p) => p.hasStatedName).map((p) => p.displayName),
          locale: navigator.language,
          timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone,
          utcOffsetMinutes: -new Date().getTimezoneOffset(),
        },
      })
      setReview(resolveProposal(proposal, people ?? [], new Date()))
      setMode('reviewing')
    } catch (cause) {
      setError(cause instanceof AICaptureError ? cause.message : 'Something went wrong. Your text is kept.')
      setMode('error')
    }
  }, [credential, canParse, text, people])

  const editText = useCallback(() => {
    setReview(null)
    setError(null)
    setMode('composing')
  }, [])

  const clearReview = useCallback(() => {
    setReview(null)
  }, [])

  const discardDraft = useCallback(() => {
    setTextState('')
    writeDraft('')
    setReview(null)
    setError(null)
  }, [])

  const handleSaved = useCallback(() => {
    setTextState('')
    writeDraft('')
    setReview(null)
    setError(null)
    setMode('saved')
  }, [])

  return useMemo(
    () => ({
      mode,
      text,
      setText,
      review,
      error,
      ready,
      credentialNeedsAttention,
      canParse,
      canLogManually,
      hasDraft: text.trim().length > 0,
      initialPersonID,
      open,
      collapse,
      parse,
      editText,
      clearReview,
      discardDraft,
      handleSaved,
    }),
    [
      mode,
      text,
      setText,
      review,
      error,
      ready,
      credentialNeedsAttention,
      canParse,
      canLogManually,
      initialPersonID,
      open,
      collapse,
      parse,
      editText,
      clearReview,
      discardDraft,
      handleSaved,
    ],
  )
}
