/// The dossier review: identity, new facts, conflicts, relationships, then
/// the deliberately-excluded subsections — private details and suggested
/// follow-ups — each row citing its source file and page with expandable
/// evidence, editable in place, removable with Undo. Conflicts demand an
/// explicit keep/replace choice; the save is one atomic plan or nothing.

import { useMemo, useState } from 'react'
import { applyPlan } from '../../data/applyPlan'
import { useObservationsFor, usePeople } from '../../data/hooks'
import type { CaptureAttachment } from '../../domain/attachments'
import {
  buildDossierDraft,
  includedCount,
  planFromDossierDraft,
  validateDossierDraft,
  type DossierDraft,
  type DossierFactDraft,
  type DossierTarget,
} from '../../domain/dossier'
import type { DossierProposal } from '../../ai/dossier'
import { CONFIDENCE_LABELS, SENSITIVITY_LABELS, attributeLabel } from '../../domain/facts'
import { kindLabel } from '../../domain/relationships'
import { MAX_PLAN_LENGTH } from '../../domain/writePlan'
import { useUID } from '../UserContext'
import { Button } from '../components/Button'

function EvidenceDisclosure({ evidence, sourceName, page }: { evidence: string; sourceName: string; page: number | null }) {
  const [open, setOpen] = useState(false)
  return (
    <span className="dossier-evidence">
      <button type="button" className="dossier-evidence-toggle" aria-expanded={open} onClick={() => setOpen(!open)}>
        {sourceName}
        {page !== null && ` · p.${page}`}
      </button>
      {open && <span className="dossier-evidence-text">“{evidence}”</span>}
    </span>
  )
}

export function DossierReview({
  proposal,
  target,
  attachments,
  onChangeTarget,
  onClose,
  onSaved,
}: {
  proposal: DossierProposal
  target: DossierTarget
  attachments: CaptureAttachment[]
  onChangeTarget: () => void
  onClose: () => void
  onSaved: () => void
}) {
  const uid = useUID()
  const people = usePeople(uid) ?? []
  const targetPersonID = target.mode === 'existing' ? target.person.id : null
  const targetObservations = useObservationsFor(uid, targetPersonID ?? '__none__') ?? []

  const [draft, setDraft] = useState<DossierDraft | null>(null)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [editingID, setEditingID] = useState<string | null>(null)
  const [announcement, setAnnouncement] = useState('')

  // The draft builds once observations for the chosen target have arrived —
  // conflict detection needs them. Rebuild only when the target changes.
  const built = useMemo(
    () => buildDossierDraft(proposal, target, targetObservations),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [proposal, targetPersonID, targetObservations.length],
  )
  const current = draft ?? built

  const problems = validateDossierDraft(current)
  const count = includedCount(current)
  const personName = target.mode === 'existing' ? target.person.displayName : current.createName || 'the new person'

  const readyAttachments = attachments.filter((a) => a.status === 'ready')
  const pageTotal = readyAttachments.reduce((sum, a) => sum + (a.pageCount ?? 0), 0)
  const attachmentName = (id: string) => attachments.find((a) => a.id === id)?.name ?? 'imported file'

  function updateFact(id: string, changes: Partial<DossierFactDraft>) {
    setDraft({
      ...current,
      facts: current.facts.map((fact) => (fact.id === id ? { ...fact, ...changes } : fact)),
    })
  }

  function setIncluded(kind: 'fact' | 'relationship' | 'followUp', id: string, included: boolean, summary: string) {
    if (kind === 'fact') {
      setDraft({ ...current, facts: current.facts.map((f) => (f.id === id ? { ...f, included } : f)) })
    } else if (kind === 'relationship') {
      setDraft({
        ...current,
        relationships: current.relationships.map((r) =>
          r.id === id ? { ...r, included, confirmed: included ? true : r.confirmed } : r,
        ),
      })
    } else {
      setDraft({ ...current, followUps: current.followUps.map((f) => (f.id === id ? { ...f, included } : f)) })
    }
    setAnnouncement(included ? `Added ${summary}` : `Removed ${summary}`)
  }

  async function save() {
    if (saving || problems.length > 0 || count === 0) return
    const { plan } = planFromDossierDraft(
      current,
      {
        targetPerson: target.mode === 'existing' ? target.person : null,
        existingPeople: people,
        sources: readyAttachments
          .filter((a) => a.sha256)
          .map((a) => ({
            attachmentID: a.id,
            displayName: a.name,
            mimeType: a.detectedMimeType,
            byteSize: a.byteSize,
            sha256: a.sha256!,
            pageCount: a.pageCount,
          })),
      },
      new Date(),
    )
    if (plan.length > MAX_PLAN_LENGTH) {
      setError(`This import needs ${plan.length} writes — more than one save can carry. Deselect some details and import the rest separately.`)
      return
    }
    setSaving(true)
    setError(null)
    try {
      await applyPlan(uid, plan)
      onSaved()
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Could not save.')
      setSaving(false)
    }
  }

  const normalFacts = current.facts.filter((f) => f.sensitivity === 'normal' && !f.conflict)
  const conflictFacts = current.facts.filter((f) => f.conflict)
  const privateFacts = current.facts.filter((f) => f.sensitivity !== 'normal' && !f.conflict)

  function factRow(fact: DossierFactDraft, excludedSection: boolean) {
    if (!fact.included && !excludedSection) {
      return (
        <div key={fact.id} className="draft-row draft-row-removed" role="status">
          <span className="draft-row-sub">
            Removed {attributeLabel(fact.attribute)}: {fact.value} ·{' '}
          </span>
          <button
            type="button"
            className="button button-plain"
            onClick={() => setIncluded('fact', fact.id, true, `${attributeLabel(fact.attribute)}: ${fact.value}`)}
          >
            Undo
          </button>
        </div>
      )
    }
    const editing = editingID === fact.id
    return (
      <div key={fact.id} className="draft-row">
        <div className="draft-row-line">
          <div className="draft-row-main">
            <span className="draft-row-title">
              {attributeLabel(fact.attribute)}: {fact.value}
            </span>
            <span className="draft-row-sub">
              {fact.confidence !== 'stated' && `${CONFIDENCE_LABELS[fact.confidence]} · `}
              {fact.sensitivity !== 'normal' && `${SENSITIVITY_LABELS[fact.sensitivity]} · `}
              <EvidenceDisclosure
                evidence={fact.evidence}
                sourceName={attachmentName(fact.sourceAttachmentID)}
                page={fact.pageNumber}
              />
            </span>
            {fact.conflict && (
              <div className="dossier-conflict" role="group" aria-label="Conflict with the current value">
                <span className="draft-row-sub">
                  Currently: <b>{fact.conflict.current.value}</b>
                </span>
                <label className="draft-radio">
                  <input
                    type="radio"
                    name={`conflict-${fact.id}`}
                    checked={fact.conflict.resolution === 'keep'}
                    onChange={() => updateFact(fact.id, { conflict: { ...fact.conflict!, resolution: 'keep' } })}
                  />
                  <span>Keep current</span>
                </label>
                <label className="draft-radio">
                  <input
                    type="radio"
                    name={`conflict-${fact.id}`}
                    checked={fact.conflict.resolution === 'replace'}
                    onChange={() => updateFact(fact.id, { conflict: { ...fact.conflict!, resolution: 'replace' } })}
                  />
                  <span>Replace with dossier value</span>
                </label>
              </div>
            )}
          </div>
          <span className="draft-row-actions">
            {excludedSection && !fact.included ? (
              <button
                type="button"
                className="button button-plain"
                onClick={() => setIncluded('fact', fact.id, true, `${attributeLabel(fact.attribute)}: ${fact.value}`)}
              >
                Review and add
              </button>
            ) : (
              <>
                <button
                  type="button"
                  className="button button-plain"
                  aria-expanded={editing}
                  aria-label={`Edit ${attributeLabel(fact.attribute)}`}
                  onClick={() => setEditingID(editing ? null : fact.id)}
                >
                  {editing ? 'Done' : 'Edit'}
                </button>
                <button
                  type="button"
                  className="icon-button"
                  aria-label={`Remove ${attributeLabel(fact.attribute)}: ${fact.value}`}
                  onClick={() => setIncluded('fact', fact.id, false, `${attributeLabel(fact.attribute)}: ${fact.value}`)}
                >
                  ×
                </button>
              </>
            )}
          </span>
        </div>
        {editing && (
          <div className="draft-row-editor">
            <label className="field-label">Category</label>
            <input className="field" value={fact.attribute} onChange={(e) => updateFact(fact.id, { attribute: e.target.value })} />
            <label className="field-label">Value</label>
            <input className="field" value={fact.value} onChange={(e) => updateFact(fact.id, { value: e.target.value })} />
          </div>
        )}
      </div>
    )
  }

  return (
    <div className="editable-review">
      <p className="visually-hidden" aria-live="polite">
        {announcement}
      </p>

      <div className="dossier-head">
        <div>
          <h3 className="composer-head-label">Review details for {personName}</h3>
          <p className="draft-row-sub">
            From {readyAttachments.length} file{readyAttachments.length === 1 ? '' : 's'}
            {pageTotal > 0 && ` · ${pageTotal} pages`}
          </p>
        </div>
        <button type="button" className="button button-plain" onClick={onChangeTarget}>
          Change person
        </button>
      </div>

      <h3 className="section-header">Identity</h3>
      <div className="draft-editor">
        {target.mode === 'create' && (
          <>
            <label className="field-label" htmlFor="dossier-name">
              Name
            </label>
            <input
              id="dossier-name"
              className="field"
              value={current.createName}
              onChange={(event) => setDraft({ ...current, createName: event.target.value })}
            />
          </>
        )}
        <div className="draft-editor-pair">
          <div>
            <label className="field-label" htmlFor="dossier-role">
              Role
            </label>
            <input
              id="dossier-role"
              className="field"
              value={current.roleTitle}
              onChange={(event) => setDraft({ ...current, roleTitle: event.target.value })}
            />
          </div>
          <div>
            <label className="field-label" htmlFor="dossier-org">
              Organization
            </label>
            <input
              id="dossier-org"
              className="field"
              value={current.organizationName}
              onChange={(event) => setDraft({ ...current, organizationName: event.target.value })}
            />
          </div>
        </div>
      </div>

      {normalFacts.length > 0 && (
        <>
          <h3 className="section-header">New facts</h3>
          {normalFacts.map((fact) => factRow(fact, false))}
        </>
      )}

      {conflictFacts.length > 0 && (
        <>
          <h3 className="section-header">Conflicts with existing facts</h3>
          {conflictFacts.map((fact) => factRow(fact, false))}
        </>
      )}

      {current.relationships.length > 0 && (
        <>
          <h3 className="section-header">Relationships</h3>
          {current.relationships.map((relationship) => (
            <div key={relationship.id} className="draft-row">
              <div className="draft-row-line">
                <div className="draft-row-main">
                  <span className="draft-row-title">
                    {relationship.label.trim() || kindLabel(relationship.kind)} →{' '}
                    {relationship.otherName ?? 'unnamed person'}
                  </span>
                  {relationship.facts.length > 0 && (
                    <span className="draft-row-sub">
                      {relationship.facts.map((f) => `${attributeLabel(f.attribute)}: ${f.value}`).join(' · ')}
                    </span>
                  )}
                </div>
                <span className="draft-row-actions">
                  {relationship.included ? (
                    <button
                      type="button"
                      className="icon-button"
                      aria-label={`Remove relationship with ${relationship.otherName ?? 'unnamed person'}`}
                      onClick={() =>
                        setIncluded('relationship', relationship.id, false, `relationship with ${relationship.otherName ?? 'unnamed'}`)
                      }
                    >
                      ×
                    </button>
                  ) : (
                    <button
                      type="button"
                      className="button button-plain"
                      onClick={() =>
                        setIncluded('relationship', relationship.id, true, `relationship with ${relationship.otherName ?? 'unnamed'}`)
                      }
                    >
                      {relationship.otherName === null ? 'Confirm and add' : 'Review and add'}
                    </button>
                  )}
                </span>
              </div>
            </div>
          ))}
        </>
      )}

      {privateFacts.length > 0 && (
        <>
          <h3 className="section-header">Private details not included</h3>
          {privateFacts.map((fact) => factRow(fact, true))}
        </>
      )}

      {current.followUps.length > 0 && (
        <>
          <h3 className="section-header">Suggested follow-ups not included</h3>
          {current.followUps.map((followUp) =>
            followUp.included ? (
              <div key={followUp.id} className="draft-row">
                <div className="draft-row-line">
                  <div className="draft-row-main">
                    <span className="draft-row-title">{followUp.title}</span>
                    <span className="draft-row-sub">
                      <EvidenceDisclosure
                        evidence={followUp.evidence}
                        sourceName={attachmentName(followUp.sourceAttachmentID)}
                        page={followUp.pageNumber}
                      />
                    </span>
                  </div>
                  <span className="draft-row-actions">
                    <button
                      type="button"
                      className="icon-button"
                      aria-label={`Remove follow-up ${followUp.title}`}
                      onClick={() => setIncluded('followUp', followUp.id, false, followUp.title)}
                    >
                      ×
                    </button>
                  </span>
                </div>
              </div>
            ) : (
              <div key={followUp.id} className="draft-row">
                <div className="draft-row-line">
                  <div className="draft-row-main">
                    <span className="draft-row-sub">{followUp.title}</span>
                  </div>
                  <span className="draft-row-actions">
                    <button
                      type="button"
                      className="button button-plain"
                      onClick={() => setIncluded('followUp', followUp.id, true, followUp.title)}
                    >
                      Review and add
                    </button>
                  </span>
                </div>
              </div>
            ),
          )}
        </>
      )}

      {current.warnings.length > 0 && (
        <>
          <h3 className="section-header">Warnings</h3>
          {current.warnings.map((warning) => (
            <p key={warning} className="draft-warning">
              {warning}
            </p>
          ))}
        </>
      )}

      {problems.map((problem) => (
        <p key={`${problem.itemID}-${problem.message}`} className="field-error" role="alert">
          {problem.message}
        </p>
      ))}
      {error && (
        <p className="field-error" role="alert">
          {error}
        </p>
      )}

      <div className="sheet-actions">
        <Button variant="quiet" onClick={onClose}>
          Back
        </Button>
        <Button variant="primary" loading={saving} disabled={count === 0 || problems.length > 0} onClick={() => void save()}>
          {target.mode === 'existing'
            ? `Add ${count} detail${count === 1 ? '' : 's'} to ${personName}`
            : `Create ${personName} with ${count} detail${count === 1 ? '' : 's'}`}
        </Button>
      </div>
    </div>
  )
}
