/// Step 4 — the sentence and the exact row this will create, rendered with
/// the same component the relationships panel uses afterward.

import { makeObservation, makePerson, planRelativeCapture } from '../../../domain/capture'
import { attributeLabel, type Observation } from '../../../domain/facts'
import type { Person } from '../../../domain/person'
import { kindLabel, relationshipPair, type RelationshipKind } from '../../../domain/relationships'
import { RelationshipIdentityRow } from '../RelationshipsSection'
import type { PersonChoice } from './RelationshipPersonStep'

export function RelationshipReviewStep({
  subject,
  choice,
  kind,
  word,
  facts,
}: {
  subject: Person
  choice: PersonChoice
  kind: RelationshipKind
  word: string
  facts: Array<{ attribute: string; value: string }>
}) {
  const now = new Date()

  // A preview-only construction — nothing here is saved.
  let other: Person
  if (choice.kind === 'existing') other = choice.person
  else if (choice.kind === 'new') other = makePerson({ displayName: choice.name }, now)
  else other = planRelativeCapture(subject, { kind, label: word || null }, now).relative

  const relationship =
    choice.kind === 'unnamed'
      ? planRelativeCapture(subject, { kind, label: word || null }, now).pair[0]
      : relationshipPair({ subjectID: subject.id, otherID: other.id, kind, customLabel: word || null, now })[0]

  const previewObservations: Observation[] = facts
    .filter((f) => f.value.trim())
    .map((f) => makeObservation({ subjectID: other.id, attribute: f.attribute, value: f.value }, now))

  const wordText = word.trim() || kindLabel(kind)
  const factsText = facts
    .filter((f) => f.value.trim())
    .map((f) => `${attributeLabel(f.attribute)}: ${f.value}`)
    .join(', ')

  const sentence =
    choice.kind === 'existing'
      ? `Connect ${choice.person.displayName} to ${subject.displayName} as ${wordText}`
      : choice.kind === 'new'
        ? `Create ${choice.name} and connect them to ${subject.displayName} as ${wordText}`
        : `Add an unnamed ${wordText} to ${subject.displayName}`

  return (
    <div>
      <p className="row-subtitle" style={{ marginBottom: 'var(--space-medium)' }}>
        {sentence}
        {factsText ? ` with ${factsText}.` : '.'}
      </p>
      <div className="relationship-preview">
        <RelationshipIdentityRow
          subject={subject}
          other={other}
          relationship={relationship}
          observations={previewObservations}
        />
      </div>
    </div>
  )
}
