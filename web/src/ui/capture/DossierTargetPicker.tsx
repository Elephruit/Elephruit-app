/// "Who is this dossier about?" — the required resolution step. Radio
/// semantics, nothing preconfirmed: the model's ranking orders the list, but
/// only the user's activation continues. Choose someone else opens a search
/// over everyone on record.

import { useState } from 'react'
import type { DossierTarget, DossierTargetOption } from '../../domain/dossier'
import { foldedForMatching, type Person } from '../../domain/person'
import { Avatar } from '../components/Avatar'
import { Button } from '../components/Button'

export function DossierTargetPicker({
  options,
  people,
  onChoose,
}: {
  options: DossierTargetOption[]
  people: Person[]
  onChoose: (target: DossierTarget) => void
}) {
  const [selected, setSelected] = useState<string | null>(null)
  const [searching, setSearching] = useState(false)
  const [search, setSearch] = useState('')

  const folded = foldedForMatching(search)
  const searchResults = folded
    ? people.filter((p) => foldedForMatching(p.displayName).includes(folded)).slice(0, 6)
    : []

  function keyFor(option: DossierTargetOption): string {
    return option.kind === 'existing' ? `existing:${option.person.id}` : `create:${option.name}`
  }

  function targetFor(key: string): DossierTarget | null {
    for (const option of options) {
      if (keyFor(option) !== key) continue
      return option.kind === 'existing' ? { mode: 'existing', person: option.person } : { mode: 'create', name: option.name }
    }
    const personID = key.startsWith('person:') ? key.slice('person:'.length) : null
    const person = personID ? people.find((p) => p.id === personID) : null
    return person ? { mode: 'existing', person } : null
  }

  return (
    <div className="dossier-target" role="radiogroup" aria-label="Who is this dossier about?">
      <h3 className="section-header">Who is this dossier about?</h3>

      {options.map((option) => {
        const key = keyFor(option)
        return (
          <label key={key} className="dossier-target-option">
            <input
              type="radio"
              name="dossier-target"
              checked={selected === key}
              onChange={() => setSelected(key)}
            />
            {option.kind === 'existing' ? (
              <span className="dossier-target-body">
                <Avatar name={option.person.displayName} colorName={option.person.colorName} small />
                <span className="dossier-target-text">
                  <b>Update {option.person.displayName}</b>
                  {(option.person.roleTitle || option.person.organizationName) && (
                    <span>
                      {[option.person.roleTitle, option.person.organizationName].filter(Boolean).join(' · ')}
                    </span>
                  )}
                </span>
              </span>
            ) : (
              <span className="dossier-target-body">
                <span className="dossier-target-text">
                  <b>Create {option.name} as a new person</b>
                </span>
              </span>
            )}
          </label>
        )
      })}

      <label className="dossier-target-option">
        <input
          type="radio"
          name="dossier-target"
          checked={searching}
          onChange={() => {
            setSearching(true)
            setSelected(null)
          }}
        />
        <span className="dossier-target-body">
          <span className="dossier-target-text">
            <b>Choose someone else</b>
          </span>
        </span>
      </label>

      {searching && (
        <div className="dossier-target-search">
          <input
            className="field"
            placeholder="Search people on record"
            value={search}
            onChange={(event) => setSearch(event.target.value)}
            autoFocus
          />
          {searchResults.map((person) => (
            <label key={person.id} className="dossier-target-option">
              <input
                type="radio"
                name="dossier-target"
                checked={selected === `person:${person.id}`}
                onChange={() => setSelected(`person:${person.id}`)}
              />
              <span className="dossier-target-body">
                <Avatar name={person.displayName} colorName={person.colorName} small />
                <span className="dossier-target-text">
                  <b>{person.displayName}</b>
                  {(person.roleTitle || person.organizationName) && (
                    <span>{[person.roleTitle, person.organizationName].filter(Boolean).join(' · ')}</span>
                  )}
                </span>
              </span>
            </label>
          ))}
        </div>
      )}

      <div className="sheet-actions">
        <Button
          variant="primary"
          disabled={selected === null}
          onClick={() => {
            const target = selected ? targetFor(selected) : null
            if (target) onChoose(target)
          }}
        >
          Continue
        </Button>
      </div>
    </div>
  )
}
