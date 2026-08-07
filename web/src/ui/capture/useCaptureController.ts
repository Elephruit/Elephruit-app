/// The capture flow as a hook, extracted from the old CapturePage so the feed
/// composer, and nothing else, owns the UI. Parsing, error handling, review
/// state, and draft persistence live here; the URL (open/closed) stays with
/// FeedPage, which maps ?capture=1 onto open()/collapse(). The hook never
/// navigates and never writes — saving still goes through the review surface
/// and the one applyPlan path.

import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { AICaptureError, parseCapture } from '../../ai/anthropic'
import { activeCredential } from '../../ai/credentials'
import {
  DossierMultipleSubjectsError,
  parseDossier,
  type DossierAttachmentInput,
  type DossierProposal,
} from '../../ai/dossier'
import { storedModel } from '../../ai/settings'
import { ingestFile } from '../../attachments/ingest'
import { resolveProposal, type ResolvedCapture } from '../../domain/assist'
import {
  attachmentsReadyForReview,
  isDuplicate,
  validateSelection,
  type CaptureAttachment,
} from '../../domain/attachments'
import { dossierTargetOptions, type DossierTarget, type DossierTargetOption } from '../../domain/dossier'
import { newID } from '../../domain/ids'
import { attributeLabel } from '../../domain/facts'
import { profileFocusOf } from '../../domain/person'
import { kindLabel } from '../../domain/relationships'
import { useAiCredentials, useAllObservations, useAllRelationships, usePeople, useReminders } from '../../data/hooks'
import { useUID } from '../UserContext'

export type CaptureMode =
  | 'collapsed'
  | 'composing'
  | 'extracting'
  | 'parsing'
  | 'reviewing'
  | 'reviewing-dossier'
  | 'saving'
  | 'saved'
  | 'error'

/// The dossier flow's own state: after parsing, either the target question or
/// the review itself.
export type DossierState =
  | { phase: 'target'; proposal: DossierProposal; options: DossierTargetOption[] }
  | { phase: 'review'; proposal: DossierProposal; target: DossierTarget }

const DRAFT_KEY = 'elephruit.captureDraft.v1'
const DRAFT_DEBOUNCE_MS = 300

interface StoredDraft {
  text: string
  /// Names and sizes only — enough to say "reattach these", never content.
  attachments: Array<{ name: string; byteSize: number }>
}

function readDraft(): StoredDraft {
  try {
    const raw = sessionStorage.getItem(DRAFT_KEY)
    if (!raw) return { text: '', attachments: [] }
    if (raw.startsWith('{')) {
      const parsed = JSON.parse(raw) as Partial<StoredDraft>
      return { text: parsed.text ?? '', attachments: parsed.attachments ?? [] }
    }
    return { text: raw, attachments: [] }
  } catch {
    return { text: '', attachments: [] }
  }
}

function writeDraft(draft: StoredDraft): void {
  try {
    if (draft.text.length > 0 || draft.attachments.length > 0) {
      sessionStorage.setItem(DRAFT_KEY, JSON.stringify(draft))
    } else {
      sessionStorage.removeItem(DRAFT_KEY)
    }
  } catch {
    // Private-mode storage failures degrade to an unpersisted draft.
  }
}

function base64FromBytes(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer)
  let binary = ''
  const chunk = 0x8000
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk))
  }
  return btoa(binary)
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
  attachments: CaptureAttachment[]
  /// True while any attachment is still extracting.
  extracting: boolean
  /// Review may proceed: every attachment ready or excluded.
  attachmentsReady: boolean
  /// Transient notice — duplicate skipped, etc. — read by a live region.
  notice: string | null
  /// Filenames from a pre-refresh draft that must be reattached.
  lostAttachments: Array<{ name: string; byteSize: number }>
  dossier: DossierState | null
  addAttachments(files: FileList | File[]): Promise<void>
  removeAttachment(id: string): void
  retryAttachment(id: string): Promise<void>
  open(initialPersonID?: string | null): void
  collapse(): void
  parse(): Promise<void>
  /// Explicit target choice in the dossier flow.
  chooseDossierTarget(target: DossierTarget): void
  changeDossierTarget(): void
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
  const observations = useAllObservations(uid)
  const reminders = useReminders(uid)
  const relationships = useAllRelationships(uid)
  const credentials = useAiCredentials(uid)

  const [mode, setMode] = useState<CaptureMode>('collapsed')
  const [text, setTextState] = useState<string>(() => readDraft().text)
  const [review, setReview] = useState<ResolvedCapture | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [initialPersonID, setInitialPersonID] = useState<string | null>(null)
  const [attachments, setAttachments] = useState<CaptureAttachment[]>([])
  const [notice, setNotice] = useState<string | null>(null)
  const [lostAttachments, setLostAttachments] = useState<StoredDraft['attachments']>(() => readDraft().attachments)
  const [dossier, setDossier] = useState<DossierState | null>(null)
  const draftTimer = useRef<number | null>(null)
  const aborts = useRef(new Map<string, AbortController>())
  /// Re-encoded image payloads keyed by attachment id — transient memory only.
  const preparedImages = useRef(new Map<string, { bytes: ArrayBuffer; mimeType: string }>())
  const attachmentsRef = useRef<CaptureAttachment[]>([])
  attachmentsRef.current = attachments

  const credential = activeCredential(credentials)
  const ready = credential !== null
  const credentialNeedsAttention =
    !ready && (credentials ?? []).some((entry) => entry.status === 'invalid' || entry.status === 'revoked')

  const persistDraft = useCallback((nextText: string, nextAttachments: CaptureAttachment[]) => {
    if (draftTimer.current !== null) window.clearTimeout(draftTimer.current)
    draftTimer.current = window.setTimeout(
      () =>
        writeDraft({
          text: nextText,
          attachments: nextAttachments
            .filter((a) => a.status !== 'error')
            .map((a) => ({ name: a.name, byteSize: a.byteSize })),
        }),
      DRAFT_DEBOUNCE_MS,
    )
  }, [])

  const setText = useCallback(
    (next: string) => {
      setTextState(next)
      persistDraft(next, attachmentsRef.current)
    },
    [persistDraft],
  )

  useEffect(
    () => () => {
      if (draftTimer.current !== null) window.clearTimeout(draftTimer.current)
      for (const controller of aborts.current.values()) controller.abort()
      // eslint-disable-next-line react-hooks/exhaustive-deps
    },
    [],
  )

  const extracting = attachments.some((a) => a.status === 'queued' || a.status === 'extracting')
  const attachmentsReady = attachmentsReadyForReview(attachments)
  const busy = mode === 'parsing' || mode === 'saving'
  const canParse =
    ready &&
    (text.trim().length > 0 || attachments.some((a) => a.status === 'ready')) &&
    !busy &&
    attachmentsReady &&
    people !== undefined
  const canLogManually = text.trim().length > 0

  const addAttachments = useCallback(
    async (files: FileList | File[]) => {
      setNotice(null)
      setLostAttachments([])
      const list = [...files]
      for (const file of list) {
        const current = attachmentsRef.current
        if (
          isDuplicate(
            { name: file.name, byteSize: file.size, lastModified: file.lastModified },
            current.map((a) => ({
              name: a.name,
              byteSize: a.byteSize,
              sha256: a.sha256,
              lastModified: a.file.lastModified,
            })),
          )
        ) {
          setNotice(`${file.name} is already attached.`)
          continue
        }
        const verdict = validateSelection(
          { name: file.name, byteSize: file.size },
          current.map((a) => ({ name: a.name, byteSize: a.byteSize })),
        )
        if (!verdict.ok) {
          setAttachments((existing) => [
            ...existing,
            {
              id: newID(),
              file,
              name: file.name,
              detectedMimeType: '',
              kind: 'text',
              byteSize: file.size,
              sha256: null,
              status: 'error',
              pageCount: null,
              extractedText: null,
              requiresVision: false,
              errorCode: verdict.code,
              errorMessage: verdict.message,
            },
          ])
          continue
        }

        const abort = new AbortController()
        const placeholderID = newID()
        aborts.current.set(placeholderID, abort)
        setAttachments((existing) => [
          ...existing,
          {
            id: placeholderID,
            file,
            name: file.name,
            detectedMimeType: '',
            kind: 'text',
            byteSize: file.size,
            sha256: null,
            status: 'extracting',
            pageCount: null,
            extractedText: null,
            requiresVision: false,
            errorCode: null,
            errorMessage: null,
          },
        ])

        const result = await ingestFile(file, abort.signal)
        aborts.current.delete(placeholderID)
        // A file removed mid-extraction stays removed.
        if (!attachmentsRef.current.some((a) => a.id === placeholderID)) continue
        // Post-hash duplicate check against everything else attached.
        if (
          result.attachment.sha256 &&
          attachmentsRef.current.some((a) => a.id !== placeholderID && a.sha256 === result.attachment.sha256)
        ) {
          setNotice(`${file.name} is already attached.`)
          setAttachments((existing) => existing.filter((a) => a.id !== placeholderID))
          continue
        }
        if (result.preparedImage) preparedImages.current.set(placeholderID, result.preparedImage)
        setAttachments((existing) =>
          existing.map((a) => (a.id === placeholderID ? { ...result.attachment, id: placeholderID } : a)),
        )
      }
      persistDraft(text, attachmentsRef.current)
    },
    [persistDraft, text],
  )

  const removeAttachment = useCallback(
    (id: string) => {
      aborts.current.get(id)?.abort()
      aborts.current.delete(id)
      preparedImages.current.delete(id)
      const remaining = attachmentsRef.current.filter((a) => a.id !== id)
      setAttachments(remaining)
      persistDraft(text, remaining)
    },
    [persistDraft, text],
  )

  const retryAttachment = useCallback(async (id: string) => {
    const target = attachmentsRef.current.find((a) => a.id === id)
    if (!target || target.status !== 'error') return
    const abort = new AbortController()
    aborts.current.set(id, abort)
    setAttachments((existing) =>
      existing.map((a) => (a.id === id ? { ...a, status: 'extracting', errorCode: null, errorMessage: null } : a)),
    )
    const result = await ingestFile(target.file, abort.signal)
    aborts.current.delete(id)
    if (result.preparedImage) preparedImages.current.set(id, result.preparedImage)
    setAttachments((existing) => existing.map((a) => (a.id === id ? { ...result.attachment, id } : a)))
  }, [])

  const open = useCallback((personID?: string | null) => {
    setInitialPersonID(personID ?? null)
    setMode((current) => (current === 'collapsed' ? 'composing' : current))
  }, [])

  const collapse = useCallback(() => {
    // The draft survives; review, dossier state, and errors are transient.
    setMode('collapsed')
    setReview(null)
    setDossier(null)
    setError(null)
  }, [])

  const captureContext = useCallback(
    () => {
      const namedPeople = (people ?? []).filter((person) => person.hasStatedName)
      return {
        today: new Date(),
        peopleNames: namedPeople.map((person) => person.displayName),
        records: namedPeople.map((person) => ({
          id: person.id,
          name: person.displayName,
          profile: [profileFocusOf(person), person.roleTitle, person.organizationName].filter(Boolean).join(' · '),
          // Only normal facts may leave the app. Sensitive and restricted
          // observations remain local even when they would help matching.
          facts: (observations ?? [])
            .filter((fact) => fact.subjectID === person.id && fact.sensitivity === 'normal' && fact.supersededOn === null)
            .map((fact) => ({ id: fact.id, label: attributeLabel(fact.attribute), value: fact.value })),
          reminders: (reminders ?? [])
            .filter((reminder) => reminder.personIDs.includes(person.id))
            .map((reminder) => ({
              id: reminder.id,
              title: reminder.title,
              status: reminder.status,
              responsibility: reminder.responsibility ?? 'mine' as const,
            })),
          relationships: (relationships ?? [])
            .filter((relationship) => relationship.subjectID === person.id)
            .map((relationship) => ({
              id: relationship.id,
              description: `${kindLabel(relationship.kind)} → ${(people ?? []).find((candidate) => candidate.id === relationship.otherID)?.displayName ?? 'unnamed person'}`,
            })),
        })),
        locale: navigator.language,
        timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone,
        utcOffsetMinutes: -new Date().getTimezoneOffset(),
      }
    },
    [people, observations, reminders, relationships],
  )

  /// Attachments → provider inputs. Vision PDFs travel as their original
  /// bytes; images as the re-encoded payload; everything else as text.
  const dossierInputs = useCallback(async (): Promise<DossierAttachmentInput[]> => {
    const inputs: DossierAttachmentInput[] = []
    for (const attachment of attachmentsRef.current) {
      if (attachment.status !== 'ready') continue
      if (attachment.kind === 'image') {
        const prepared = preparedImages.current.get(attachment.id)
        if (!prepared) continue
        inputs.push({
          id: attachment.id,
          name: attachment.name,
          extractedText: null,
          visionPayload: {
            mimeType: prepared.mimeType as 'image/jpeg' | 'image/png',
            dataBase64: base64FromBytes(prepared.bytes),
          },
          pageCount: attachment.pageCount,
        })
        continue
      }
      if (attachment.kind === 'pdf' && attachment.requiresVision) {
        inputs.push({
          id: attachment.id,
          name: attachment.name,
          extractedText: null,
          visionPayload: {
            mimeType: 'application/pdf',
            dataBase64: base64FromBytes(await attachment.file.arrayBuffer()),
          },
          pageCount: attachment.pageCount,
        })
        continue
      }
      inputs.push({
        id: attachment.id,
        name: attachment.name,
        extractedText: attachment.extractedText,
        visionPayload: null,
        pageCount: attachment.pageCount,
      })
    }
    return inputs
  }, [])

  const parse = useCallback(async () => {
    if (!credential || !canParse) return
    setMode('parsing')
    setError(null)
    try {
      const hasSources = attachmentsRef.current.some((a) => a.status === 'ready')
      if (hasSources) {
        const preselected = initialPersonID ? (people ?? []).find((p) => p.id === initialPersonID) : undefined
        const proposal = await parseDossier(await dossierInputs(), {
          credentialId: credential.id,
          model: storedModel(),
          context: {
            peopleNames: (people ?? []).filter((p) => p.hasStatedName).map((p) => p.displayName),
            targetName: preselected?.displayName ?? null,
          },
        })
        if (preselected) {
          setDossier({ phase: 'review', proposal, target: { mode: 'existing', person: preselected } })
        } else {
          setDossier({ phase: 'target', proposal, options: dossierTargetOptions(proposal, people ?? []) })
        }
        setMode('reviewing-dossier')
        return
      }

      const proposal = await parseCapture(text, {
        credentialId: credential.id,
        model: storedModel(),
        context: captureContext(),
      })
      setReview(resolveProposal(proposal, people ?? [], new Date(), { reminders: reminders ?? [], observations: observations ?? [], relationships: relationships ?? [] }))
      setMode('reviewing')
    } catch (cause) {
      if (cause instanceof DossierMultipleSubjectsError) {
        setError(
          'These files appear to describe more than one person. Review them separately or choose which person to build now.',
        )
      } else {
        setError(cause instanceof AICaptureError ? cause.message : 'Something went wrong. Your text is kept.')
      }
      setMode('error')
    }
  }, [credential, canParse, text, people, reminders, observations, relationships, captureContext, dossierInputs, initialPersonID])

  const chooseDossierTarget = useCallback((target: DossierTarget) => {
    setDossier((current) => (current ? { phase: 'review', proposal: current.proposal, target } : current))
  }, [])

  const changeDossierTarget = useCallback(() => {
    setDossier((current) =>
      current
        ? { phase: 'target', proposal: current.proposal, options: dossierTargetOptions(current.proposal, people ?? []) }
        : current,
    )
  }, [people])

  const editText = useCallback(() => {
    setReview(null)
    setDossier(null)
    setError(null)
    setMode('composing')
  }, [])

  const clearReview = useCallback(() => {
    setReview(null)
    setDossier(null)
  }, [])

  const clearAllAttachments = useCallback(() => {
    for (const controller of aborts.current.values()) controller.abort()
    aborts.current.clear()
    preparedImages.current.clear()
    setAttachments([])
  }, [])

  const discardDraft = useCallback(() => {
    setTextState('')
    clearAllAttachments()
    setLostAttachments([])
    writeDraft({ text: '', attachments: [] })
    setReview(null)
    setDossier(null)
    setError(null)
  }, [clearAllAttachments])

  const handleSaved = useCallback(() => {
    setTextState('')
    clearAllAttachments()
    setLostAttachments([])
    writeDraft({ text: '', attachments: [] })
    setReview(null)
    setDossier(null)
    setError(null)
    setMode('saved')
  }, [clearAllAttachments])

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
      hasDraft: text.trim().length > 0 || attachments.length > 0,
      initialPersonID,
      attachments,
      extracting,
      attachmentsReady,
      notice,
      lostAttachments,
      dossier,
      addAttachments,
      removeAttachment,
      retryAttachment,
      open,
      collapse,
      parse,
      chooseDossierTarget,
      changeDossierTarget,
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
      attachments,
      extracting,
      attachmentsReady,
      notice,
      lostAttachments,
      dossier,
      addAttachments,
      removeAttachment,
      retryAttachment,
      open,
      collapse,
      parse,
      chooseDossierTarget,
      changeDossierTarget,
      editText,
      clearReview,
      discardDraft,
      handleSaved,
    ],
  )
}
