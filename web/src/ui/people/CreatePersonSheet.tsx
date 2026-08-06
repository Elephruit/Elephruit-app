import { useState } from 'react'
import { planCreatePerson } from '../../domain/capture'
import type { Person } from '../../domain/person'
import { applyPlan } from '../../data/applyPlan'
import { useUID } from '../UserContext'
import { Dialog } from '../components/Dialog'

export function CreatePersonSheet({
  onClose,
  onCreated,
}: {
  onClose: () => void
  onCreated: (person: Person) => void
}) {
  const uid = useUID()
  const [name, setName] = useState('')
  const [organization, setOrganization] = useState('')
  const [role, setRole] = useState('')
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const valid = name.trim().length > 0

  async function save() {
    if (!valid || saving) return
    setSaving(true)
    setError(null)
    try {
      const { plan, person } = planCreatePerson(
        { displayName: name, organizationName: organization, roleTitle: role },
        new Date(),
      )
      await applyPlan(uid, plan)
      onCreated(person)
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Could not save.')
      setSaving(false)
    }
  }

  return (
    <Dialog title="New person" onClose={onClose}>
      <label className="field-label" htmlFor="person-name">
        Name
      </label>
      <input
        id="person-name"
        className="field"
        value={name}
        onChange={(event) => setName(event.target.value)}
        placeholder="Ana Torres"
        autoFocus
      />
      <label className="field-label" htmlFor="person-org">
        Organization
      </label>
      <input
        id="person-org"
        className="field"
        value={organization}
        onChange={(event) => setOrganization(event.target.value)}
        placeholder="Optional"
      />
      <label className="field-label" htmlFor="person-role">
        Role
      </label>
      <input
        id="person-role"
        className="field"
        value={role}
        onChange={(event) => setRole(event.target.value)}
        placeholder="Optional"
      />
      {error && <p role="alert">{error}</p>}
      <div className="sheet-actions">
        <button type="button" className="button button-quiet" onClick={onClose}>
          Cancel
        </button>
        <button type="button" className="button" disabled={!valid || saving} onClick={() => void save()}>
          Add person
        </button>
      </div>
    </Dialog>
  )
}
