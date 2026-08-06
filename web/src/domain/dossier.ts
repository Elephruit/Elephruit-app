/// The dossier review as pure domain: what the parser proposed, resolved
/// against the chosen target person's current facts, with explicit inclusion
/// defaults (sensitive material and follow-ups start excluded), explicit
/// conflict resolutions, and one atomic plan at the end. The model's output
/// is never written — only the reviewed draft is.

import type { DossierProposal } from '../ai/dossier'
import { foldAttribute } from './assist'
import {
  makePerson,
  planCorrection,
  planObservation,
  planRelationshipPair,
  planRelativeCapture,
  planCreateReminder,
} from './capture'
import { currentValues, isMultiValued, type FactConfidence, type FactSensitivity, type Observation } from './facts'
import { foldedForMatching, type Person } from './person'
import { kindLabel, type RelationshipKind } from './relationships'
import { makeSourceDocument, planSourceDocument, type SourceDocument } from './sources'
import type { WritePlan } from './writePlan'

// MARK: Target resolution

export type DossierTargetOption =
  | { kind: 'existing'; person: Person; confidence: 'high' | 'possible' }
  | { kind: 'create'; name: string }

/// Ranked options for "Who is this dossier about?". Nothing is preconfirmed:
/// the UI requires an explicit activation even when one option ranks first.
export function dossierTargetOptions(proposal: DossierProposal, people: Person[]): DossierTargetOption[] {
  const options: DossierTargetOption[] = []
  const proposedName = proposal.subject.proposedName?.trim() ?? null
  const folded = proposedName ? foldedForMatching(proposedName) : null

  if (folded) {
    for (const person of people) {
      if (foldedForMatching(person.displayName) === folded) {
        options.push({ kind: 'existing', person, confidence: 'high' })
      }
    }
    const firstName = folded.split(' ')[0]
    for (const person of people) {
      if (options.some((option) => option.kind === 'existing' && option.person.id === person.id)) continue
      const personFolded = foldedForMatching(person.displayName)
      if (personFolded.split(' ')[0] === firstName || (proposal.subject.organizationName && person.organizationName === proposal.subject.organizationName)) {
        options.push({ kind: 'existing', person, confidence: 'possible' })
      }
    }
  }

  if (proposedName) options.push({ kind: 'create', name: proposedName })
  return options
}

// MARK: The draft

export interface DossierFactDraft {
  id: string
  attribute: string
  value: string
  confidence: FactConfidence
  sensitivity: FactSensitivity
  evidence: string
  sourceAttachmentID: string
  pageNumber: number | null
  included: boolean
  /// Present when a single-valued attribute already has a different current
  /// value. Must be resolved before an included fact can save.
  conflict: { current: Observation; resolution: 'keep' | 'replace' | null } | null
}

export interface DossierRelationshipDraft {
  id: string
  kind: RelationshipKind
  label: string
  otherName: string | null
  /// Unnamed relationships stay inactive until the user confirms the label.
  confirmed: boolean
  included: boolean
  facts: Array<{ attribute: string; value: string; evidence: string; sourceAttachmentID: string; pageNumber: number | null }>
}

export interface DossierFollowUpDraft {
  id: string
  title: string
  evidence: string
  sourceAttachmentID: string
  pageNumber: number | null
  included: boolean
}

export interface DossierDraft {
  /// Existing person target, or null when creating.
  targetPersonID: string | null
  createName: string
  roleTitle: string
  organizationName: string
  facts: DossierFactDraft[]
  relationships: DossierRelationshipDraft[]
  followUps: DossierFollowUpDraft[]
  warnings: string[]
}

export type DossierTarget = { mode: 'existing'; person: Person } | { mode: 'create'; name: string }

export function buildDossierDraft(
  proposal: DossierProposal,
  target: DossierTarget,
  targetObservations: Observation[],
): DossierDraft {
  let index = 0
  const nextID = () => `dossier-${index++}`

  const facts: DossierFactDraft[] = proposal.facts.map((fact) => {
    const attribute = foldAttribute(fact.attribute)
    const evidence = fact.evidence.slice(0, 200)
    let conflict: DossierFactDraft['conflict'] = null
    if (target.mode === 'existing' && !isMultiValued(attribute)) {
      const current = currentValues(targetObservations, attribute)[0]
      if (current && current.value.trim().toLowerCase() !== fact.value.trim().toLowerCase()) {
        conflict = { current, resolution: null }
      }
    }
    return {
      id: nextID(),
      attribute,
      value: fact.value,
      confidence: fact.confidence,
      sensitivity: fact.sensitivity,
      evidence,
      sourceAttachmentID: fact.sourceAttachmentID,
      pageNumber: fact.pageNumber,
      // Normal stated/inferred facts start included (labeled when not
      // stated); sensitive and restricted start in the private subsection.
      included: fact.sensitivity === 'normal',
      conflict,
    }
  })

  return {
    targetPersonID: target.mode === 'existing' ? target.person.id : null,
    createName: target.mode === 'create' ? target.name : '',
    roleTitle: proposal.subject.roleTitle ?? '',
    organizationName: proposal.subject.organizationName ?? '',
    facts,
    relationships: proposal.relationships.map((relationship) => ({
      id: nextID(),
      kind: relationship.kind,
      label: relationship.label ?? '',
      otherName: relationship.otherName,
      confirmed: relationship.otherName !== null,
      included: relationship.otherName !== null,
      facts: relationship.facts.map((f) => ({ ...f, evidence: f.evidence.slice(0, 200) })),
    })),
    followUps: proposal.followUps.map((followUp) => ({
      id: nextID(),
      title: followUp.title,
      evidence: followUp.evidence.slice(0, 200),
      sourceAttachmentID: followUp.sourceAttachmentID,
      pageNumber: followUp.pageNumber,
      // Dossier-derived follow-ups are suggestions, never active by default.
      included: false,
    })),
    warnings: proposal.warnings,
  }
}

export interface DossierProblem {
  itemID: string | null
  message: string
}

export function validateDossierDraft(draft: DossierDraft): DossierProblem[] {
  const problems: DossierProblem[] = []
  if (draft.targetPersonID === null && !draft.createName.trim()) {
    problems.push({ itemID: null, message: 'Choose who this dossier is about.' })
  }
  for (const fact of draft.facts) {
    if (!fact.included) continue
    if (!fact.value.trim()) problems.push({ itemID: fact.id, message: 'The fact needs a value.' })
    if (fact.conflict && fact.conflict.resolution === null) {
      problems.push({ itemID: fact.id, message: 'Decide what happens to the current value first.' })
    }
  }
  for (const relationship of draft.relationships) {
    if (relationship.included && relationship.otherName === null && !relationship.confirmed) {
      problems.push({ itemID: relationship.id, message: 'Confirm the temporary label for this unnamed person.' })
    }
  }
  return problems
}

export function includedCount(draft: DossierDraft): number {
  return (
    draft.facts.filter((f) => f.included).length +
    draft.relationships.filter((r) => r.included).length +
    draft.followUps.filter((f) => f.included).length
  )
}

// MARK: The plan

export interface DossierSourceInput {
  attachmentID: string
  displayName: string
  mimeType: string
  byteSize: number
  sha256: string
  pageCount: number | null
}

export interface DossierPlanResult {
  plan: WritePlan
  person: Person
  sources: SourceDocument[]
}

/// One atomic plan: the person (created or identity-updated), every included
/// item with document provenance, corrections for replace-resolutions, and
/// source metadata for exactly the attachments that contributed a saved item.
export function planFromDossierDraft(
  draft: DossierDraft,
  args: {
    targetPerson: Person | null
    existingPeople: Person[]
    sources: DossierSourceInput[]
  },
  now: Date,
): DossierPlanResult {
  const plan: WritePlan = []
  const citedAttachmentIDs = new Set<string>()

  let person: Person
  if (args.targetPerson) {
    person = args.targetPerson
    const identity: Record<string, unknown> = {}
    if (draft.roleTitle.trim() && draft.roleTitle.trim() !== (person.roleTitle ?? '')) {
      identity.roleTitle = draft.roleTitle.trim()
    }
    if (draft.organizationName.trim() && draft.organizationName.trim() !== (person.organizationName ?? '')) {
      identity.organizationName = draft.organizationName.trim()
    }
    if (Object.keys(identity).length > 0) {
      plan.push({ op: 'update', collection: 'people', id: person.id, data: identity })
    }
  } else {
    person = makePerson(
      {
        displayName: draft.createName,
        roleTitle: draft.roleTitle.trim() || null,
        organizationName: draft.organizationName.trim() || null,
      },
      now,
    )
    plan.push({ op: 'set', collection: 'people', id: person.id, data: person })
  }

  // Source metadata ids, minted up front so observations can reference them;
  // only the cited ones are written at the end.
  const sourceByAttachment = new Map<string, SourceDocument>()
  for (const input of args.sources) {
    sourceByAttachment.set(
      input.attachmentID,
      makeSourceDocument(
        {
          displayName: input.displayName,
          mimeType: input.mimeType,
          byteSize: input.byteSize,
          sha256: input.sha256,
          pageCount: input.pageCount,
        },
        now,
      ),
    )
  }
  const sourceID = (attachmentID: string): string | null => {
    const source = sourceByAttachment.get(attachmentID)
    if (!source) return null
    citedAttachmentIDs.add(attachmentID)
    return source.id
  }

  for (const fact of draft.facts) {
    if (!fact.included || !fact.value.trim()) continue
    if (fact.conflict) {
      if (fact.conflict.resolution === 'keep') continue
      if (fact.conflict.resolution === 'replace') {
        plan.push(
          ...planCorrection(
            fact.conflict.current,
            {
              value: fact.value,
              confidence: fact.confidence,
              sensitivity: fact.sensitivity,
              sourceDocumentID: sourceID(fact.sourceAttachmentID),
            },
            'Replaced from imported document',
            now,
          ).plan,
        )
        continue
      }
      continue // unresolved conflicts never reach here — validation blocks
    }
    plan.push(
      ...planObservation(
        {
          subjectID: person.id,
          attribute: foldAttribute(fact.attribute),
          value: fact.value,
          confidence: fact.confidence,
          sensitivity: fact.sensitivity,
          sourceDocumentID: sourceID(fact.sourceAttachmentID),
        },
        now,
      ).plan,
    )
  }

  for (const relationship of draft.relationships) {
    if (!relationship.included) continue
    const label = relationship.label.trim() || null
    if (relationship.otherName === null) {
      const capture = planRelativeCapture(
        person,
        {
          kind: relationship.kind,
          label: label ?? kindLabel(relationship.kind),
          name: null,
          facts: relationship.facts.map((f) => ({ attribute: foldAttribute(f.attribute), value: f.value })),
        },
        now,
      )
      for (const f of relationship.facts) sourceID(f.sourceAttachmentID)
      plan.push(...capture.plan)
      continue
    }
    const folded = foldedForMatching(relationship.otherName)
    const existing = args.existingPeople.find((p) => foldedForMatching(p.displayName) === folded)
    let other: Person
    if (existing) {
      other = existing
    } else {
      other = makePerson({ displayName: relationship.otherName }, now)
      plan.push({ op: 'set', collection: 'people', id: other.id, data: other })
    }
    plan.push(
      ...planRelationshipPair({ subjectID: person.id, otherID: other.id, kind: relationship.kind, customLabel: label }, now)
        .plan,
    )
    for (const f of relationship.facts) {
      if (!f.value.trim()) continue
      plan.push(
        ...planObservation(
          {
            subjectID: other.id,
            attribute: foldAttribute(f.attribute),
            value: f.value,
            sourceDocumentID: sourceID(f.sourceAttachmentID),
          },
          now,
        ).plan,
      )
    }
  }

  for (const followUp of draft.followUps) {
    if (!followUp.included || !followUp.title.trim()) continue
    plan.push(
      ...planCreateReminder(
        {
          title: followUp.title,
          personIDs: [person.id],
          sourceDocumentID: sourceID(followUp.sourceAttachmentID),
        },
        now,
      ).plan,
    )
  }

  const sources: SourceDocument[] = []
  for (const [attachmentID, source] of sourceByAttachment) {
    if (!citedAttachmentIDs.has(attachmentID)) continue
    sources.push(source)
    plan.push(...planSourceDocument(source))
  }

  return { plan, person, sources }
}
