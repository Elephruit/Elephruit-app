/// Create or rename one folder.
///
/// There used to be a "what is it — project or folder?" control at the top,
/// asked before the answer was necessarily known and enforced by a rule that
/// refused dates on the wrong choice. There is one kind now, so the sheet opens
/// on the only field that is always required, and the dates are optional
/// underneath for the folders that are trips.

import { useMemo, useState } from 'react'
import { applyPlan } from '../../data/applyPlan'
import {
  moveRefusal,
  folderTint,
  planCreateFolder,
  planUpdateFolder,
  validateFolderDraft,
  type Folder,
  type FolderColor,
} from '../../domain/folder'
import { PALETTE_COLORS } from '../../domain/person'
import { fromLocalDateValue, toLocalDateValue } from '../dateInput'
import { Button } from '../components/Button'
import { FormField } from '../components/FormField'
import { Sheet } from '../components/Sheet'
import { useUID } from '../UserContext'
import { FolderPicker } from './FolderPicker'

export function FolderSheet({
  existing,
  folders,
  defaultParentID = null,
  onClose,
  onSaved,
}: {
  existing: Folder | null
  folders: Folder[]
  defaultParentID?: string | null
  onClose: () => void
  onSaved?: (id: string) => void
}) {
  const uid = useUID()
  const [title, setTitle] = useState(existing?.title ?? '')
  const [summary, setSummary] = useState(existing?.summary ?? '')
  const [colorName, setColorName] = useState<FolderColor>(existing?.colorName ?? 'blue')
  const [parentID, setParentID] = useState<string | null>(existing?.parentID ?? defaultParentID)
  const [datesOpen, setDatesOpen] = useState(Boolean(existing?.startAt || existing?.dueAt))
  const [startField, setStartField] = useState(existing?.startAt ? toLocalDateValue(existing.startAt) : '')
  const [dueField, setDueField] = useState(existing?.dueAt ? toLocalDateValue(existing.dueAt) : '')
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)

  /// A folder being edited may not be offered any parent the domain would
  /// refuse — itself, or one of its own descendants, which is the move that
  /// makes a branch vanish.
  const parentOptions = useMemo(() => {
    if (!existing) return folders
    return folders.filter((folder) => moveRefusal(folders, existing, folder.id) === null)
  }, [folders, existing])

  const startAt = datesOpen ? fromLocalDateValue(startField) : null
  const dueAt = datesOpen ? fromLocalDateValue(dueField) : null
  const refusal = validateFolderDraft({ title, startAt, dueAt })

  async function save() {
    if (refusal || saving) return
    setSaving(true)
    setError(null)
    try {
      const fields = { title: title.trim(), summary: summary.trim() || null, colorName, parentID, startAt, dueAt }
      if (existing) {
        await applyPlan(uid, planUpdateFolder(existing.id, fields, new Date()).plan)
        onSaved?.(existing.id)
      } else {
        const { plan, folder } = planCreateFolder(fields, new Date())
        await applyPlan(uid, plan)
        onSaved?.(folder.id)
      }
      onClose()
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Could not save.')
      setSaving(false)
    }
  }

  return (
    <Sheet
      title={existing ? `Rename ${existing.title}` : 'New folder'}
      onClose={onClose}
      footer={
        <>
          <Button variant="quiet" onClick={onClose}>
            Cancel
          </Button>
          <Button variant="primary" loading={saving} disabled={refusal !== null} onClick={() => void save()}>
            {existing ? 'Save' : 'Create folder'}
          </Button>
        </>
      }
    >
      <FormField label="Name" htmlFor="folder-title">
        <input
          id="folder-title"
          className="field"
          value={title}
          onChange={(event) => setTitle(event.target.value)}
          placeholder="Chicago, October"
          autoFocus
          onKeyDown={(event) => {
            if (event.key === 'Enter' && !refusal) void save()
          }}
        />
      </FormField>

      <FormField label="Summary" htmlFor="folder-summary">
        <input
          id="folder-summary"
          className="field"
          value={summary}
          onChange={(event) => setSummary(event.target.value)}
          placeholder="Optional"
        />
      </FormField>

      <FormField label="Inside">
        <FolderPicker
          folders={parentOptions}
          value={parentID}
          onChange={setParentID}
          label="Parent folder"
          emptyLabel="Nothing — keep it at the top"
        />
      </FormField>

      <FormField label="Color">
        <div className="color-choices">
          {PALETTE_COLORS.map((color) => (
            <button
              key={color}
              type="button"
              className="color-choice"
              style={{ '--tint': folderTint(color) } as React.CSSProperties}
              data-selected={color === colorName || undefined}
              aria-label={color}
              aria-pressed={color === colorName}
              onClick={() => setColorName(color)}
            />
          ))}
          <label className="color-choice color-choice-custom" data-selected={colorName.startsWith('#') || undefined}>
            <input
              type="color"
              aria-label="Custom folder color"
              value={colorName.startsWith('#') ? colorName : '#4168c6'}
              onChange={(event) => setColorName(event.target.value as FolderColor)}
            />
          </label>
        </div>
      </FormField>

      {/* Dates are for the folders that are trips, which is a minority — so
          they are one line away rather than two fields every folder has to
          look at and leave blank. */}
      {datesOpen ? (
        <div className="field-row">
          <FormField label="Starts" htmlFor="folder-start">
            <input
              id="folder-start"
              className="field"
              type="date"
              value={startField}
              onChange={(event) => setStartField(event.target.value)}
            />
          </FormField>
          <FormField label="Ends" htmlFor="folder-due">
            <input
              id="folder-due"
              className="field"
              type="date"
              value={dueField}
              onChange={(event) => setDueField(event.target.value)}
            />
          </FormField>
        </div>
      ) : (
        <Button variant="ghost" small icon="calendar" onClick={() => setDatesOpen(true)}>
          Add dates
        </Button>
      )}

      {(refusal || error) && title.trim() !== '' && (
        <p className="field-error" role="alert">
          {error ?? refusal}
        </p>
      )}
    </Sheet>
  )
}
