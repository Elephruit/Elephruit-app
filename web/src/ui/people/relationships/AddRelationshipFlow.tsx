/// The four-step relationship flow in the shared Sheet: type → who → optional
/// details → review. Back preserves everything; closing with changes asks
/// inline in the footer; nothing is created until the final action, and the
/// save is one atomic plan with its memory record.

import { useMemo, useState } from 'react'
import { applyPlan } from '../../../data/applyPlan'
import { planObservation, planRelationshipPair, planRelativeCapture } from '../../../domain/capture'
import { foldAttribute } from '../../../domain/assist'
import { customAttribute } from '../../../domain/facts'
import { planMemoryRecord } from '../../../domain/memory'
import type { Observation } from '../../../domain/facts'
import type { Person } from '../../../domain/person'
import type { Relationship, RelationshipKind } from '../../../domain/relationships'
import type { WritePlan } from '../../../domain/writePlan'
import { useUID } from '../../UserContext'
import { Button } from '../../components/Button'
import { Sheet } from '../../components/Sheet'
import { RelationshipDetailsStep } from './RelationshipDetailsStep'
import { RelationshipPersonStep, type PersonChoice } from './RelationshipPersonStep'
import { RelationshipReviewStep } from './RelationshipReviewStep'
import { RelationshipTypeStep } from './RelationshipTypeStep'

const STEP_COUNT = 4

export function AddRelationshipFlow({
  subject,
  people,
  existingRelationships,
  observationsBySubject,
  onClose,
  onCreated,
}: {
  subject: Person
  people: Person[]
  existingRelationships: Relationship[]
  observationsBySubject: Map<string, Observation[]>
  onClose: () => void
  onCreated: (relationshipID: string) => void
}) {
  void observationsBySubject
  const uid = useUID()
  const [step, setStep] = useState(1)
  const [kind, setKind] = useState<RelationshipKind | null>(null)
  const [word, setWord] = useState('')
  const [choice, setChoice] = useState<PersonChoice | null>(null)
  const [facts, setFacts] = useState<Record<string, string>>({})
  const [custom, setCustom] = useState({ name: '', value: '' })
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [confirmingDiscard, setConfirmingDiscard] = useState(false)

  const dirty = kind !== null || word.trim().length > 0 || choice !== null || Object.values(facts).some((v) => v.trim())

  const firstName = subject.displayName.split(/\s+/)[0]

  const factList = useMemo(
    () => [
      ...Object.entries(facts)
        .filter(([, value]) => value.trim())
        .map(([attribute, value]) => ({ attribute, value })),
      ...(custom.name.trim() && custom.value.trim() && customAttribute(custom.name)
        ? [{ attribute: customAttribute(custom.name)!, value: custom.value }]
        : []),
    ],
    [facts, custom],
  )

  function requestClose() {
    if (dirty && !confirmingDiscard) {
      setConfirmingDiscard(true)
      return
    }
    onClose()
  }

  async function save() {
    if (!kind || !choice || saving) return
    setSaving(true)
    setError(null)
    try {
      const now = new Date()
      let plan: WritePlan
      let other: { id: string; displayName: string }
      let relationshipIDs: [string, string]
      const observationIDs: string[] = []

      if (choice.kind === 'unnamed') {
        const capture = planRelativeCapture(
          subject,
          {
            kind,
            label: word.trim() || null,
            name: null,
            facts: factList.map((f) => ({ attribute: foldAttribute(f.attribute), value: f.value })),
          },
          now,
        )
        plan = capture.plan
        other = capture.relative
        relationshipIDs = [capture.pair[0].id, capture.pair[1].id]
        for (const write of capture.plan) {
          if (write.collection === 'observations' && write.op === 'set') observationIDs.push(write.id)
        }
      } else {
        plan = []
        if (choice.kind === 'new') {
          const created = planRelativeCapture(subject, { kind, label: word.trim() || null, name: choice.name }, now)
          // planRelativeCapture already wires person + pair for the named case.
          plan.push(...created.plan)
          other = created.relative
          relationshipIDs = [created.pair[0].id, created.pair[1].id]
        } else {
          other = choice.person
          const { plan: pairPlan, pair } = planRelationshipPair(
            { subjectID: subject.id, otherID: choice.person.id, kind, customLabel: word.trim() || null },
            now,
          )
          plan.push(...pairPlan)
          relationshipIDs = [pair[0].id, pair[1].id]
        }
        for (const fact of factList) {
          const { plan: factPlan, observation } = planObservation(
            { subjectID: other.id, attribute: foldAttribute(fact.attribute), value: fact.value },
            now,
          )
          observationIDs.push(observation.id)
          plan.push(...factPlan)
        }
      }

      const { plan: memoryPlan } = planMemoryRecord(
        {
          kind: 'manualUpdate',
          title: `Connected ${subject.displayName} and ${other.displayName}`,
          occurredAt: now,
          personIDs: [subject.id, other.id],
          relationshipIDs: [...relationshipIDs],
          observationIDs,
          origin: 'manualRelationship',
        },
        now,
      )
      await applyPlan(uid, [...plan, ...memoryPlan])
      onCreated(relationshipIDs[0])
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Could not save.')
      setSaving(false)
    }
  }

  const canContinue = step === 1 ? kind !== null : step === 2 ? choice !== null : true
  const primaryLabel =
    step < 3
      ? 'Continue'
      : step === 3
        ? 'Review'
        : choice?.kind === 'existing'
          ? 'Connect person'
          : choice?.kind === 'new'
            ? 'Create and connect'
            : 'Add unnamed person'

  return (
    <Sheet
      title={`Add someone in ${firstName}’s life`}
      onClose={requestClose}
      footer={
        confirmingDiscard ? (
          <>
            <span className="sheet-confirm-text" role="alert">
              Discard this relationship?
            </span>
            <Button variant="quiet" onClick={() => setConfirmingDiscard(false)}>
              Keep editing
            </Button>
            <Button variant="destructive" onClick={onClose}>
              Discard
            </Button>
          </>
        ) : (
          <>
            <span className="visually-hidden" aria-live="polite">{`Step ${step} of ${STEP_COUNT}`}</span>
            <span className="sheet-step-note" aria-hidden="true">
              Step {step} of {STEP_COUNT}
            </span>
            {step > 1 && (
              <Button variant="quiet" onClick={() => setStep(step - 1)}>
                Back
              </Button>
            )}
            {step === 3 && (
              <Button variant="quiet" onClick={() => setStep(4)}>
                Skip details
              </Button>
            )}
            <Button
              variant="primary"
              loading={saving}
              disabled={!canContinue}
              onClick={() => (step < STEP_COUNT ? setStep(step + 1) : void save())}
            >
              {primaryLabel}
            </Button>
          </>
        )
      }
    >
      {step === 1 && (
        <>
          <p className="field-label">Who are they to {firstName}?</p>
          <RelationshipTypeStep kind={kind} word={word} onPickKind={setKind} onWordChange={setWord} />
        </>
      )}
      {step === 2 && kind && (
        <RelationshipPersonStep
          subject={subject}
          people={people}
          existingRelationships={existingRelationships}
          choice={choice}
          onChoose={setChoice}
        />
      )}
      {step === 3 && kind && (
        <RelationshipDetailsStep
          kind={kind}
          facts={facts}
          custom={custom}
          onFactChange={(attribute, value) => setFacts((current) => ({ ...current, [attribute]: value }))}
          onCustomChange={setCustom}
        />
      )}
      {step === 4 && kind && choice && (
        <RelationshipReviewStep subject={subject} choice={choice} kind={kind} word={word} facts={factList} />
      )}

      {error && (
        <p className="field-error" role="alert">
          {error}
        </p>
      )}
    </Sheet>
  )
}
