/// Create or edit one container. The kind picker is the whole design: choosing
/// Project reveals the dates, choosing Folder hides them, and the domain
/// refuses dates on a folder anyway — so the interface and the validator say
/// the same thing rather than one of them being decorative.

import { useMemo, useState } from 'react'
import { applyPlan } from '../../data/applyPlan'
import {
  CONTAINER_KIND_LABELS,
  buildTree,
  flattenTree,
  moveRefusal,
  pathLabel,
  planCreateContainer,
  planUpdateContainer,
  validateContainerDraft,
  type Container,
  type ContainerKind,
} from '../../domain/container'
import { PALETTE_COLORS, type PaletteColor } from '../../domain/person'
import { fromLocalDateValue, toLocalDateValue } from '../dateInput'
import { Button } from '../components/Button'
import { FormField } from '../components/FormField'
import { SegmentedControl } from '../components/SegmentedControl'
import { Sheet } from '../components/Sheet'
import { useUID } from '../UserContext'

export function ContainerSheet({
  existing,
  containers,
  defaultParentID = null,
  onClose,
  onSaved,
}: {
  existing: Container | null
  containers: Container[]
  defaultParentID?: string | null
  onClose: () => void
  onSaved?: (id: string) => void
}) {
  const uid = useUID()
  const [kind, setKind] = useState<ContainerKind>(existing?.kind ?? 'project')
  const [title, setTitle] = useState(existing?.title ?? '')
  const [summary, setSummary] = useState(existing?.summary ?? '')
  const [colorName, setColorName] = useState<PaletteColor>(existing?.colorName ?? 'blue')
  const [parentID, setParentID] = useState<string | null>(existing?.parentID ?? defaultParentID)
  const [startField, setStartField] = useState(existing?.startAt ? toLocalDateValue(existing.startAt) : '')
  const [dueField, setDueField] = useState(existing?.dueAt ? toLocalDateValue(existing.dueAt) : '')
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)

  /// Only folders can be parents, and a container being edited may not be
  /// offered any parent the domain would refuse — including its own
  /// descendants, which is the move that makes a branch vanish.
  const parentOptions = useMemo(() => {
    const folders = flattenTree(buildTree(containers)).filter((node) => node.container.kind === 'folder')
    if (!existing) return folders
    return folders.filter((node) => moveRefusal(containers, existing, node.container.id) === null)
  }, [containers, existing])

  const startAt = kind === 'project' ? fromLocalDateValue(startField) : null
  const dueAt = kind === 'project' ? fromLocalDateValue(dueField) : null
  const refusal = validateContainerDraft({ kind, title, startAt, dueAt })

  async function save() {
    if (refusal || saving) return
    setSaving(true)
    setError(null)
    try {
      if (existing) {
        const { plan } = planUpdateContainer(
          existing.id,
          {
            title: title.trim(),
            summary: summary.trim() || null,
            colorName,
            parentID,
            // A project turned into a folder is not offered here; the kind is
            // fixed once created, so these stay in step with what is stored.
            startAt,
            dueAt,
          },
          new Date(),
        )
        await applyPlan(uid, plan)
        onSaved?.(existing.id)
      } else {
        const { plan, container } = planCreateContainer(
          { kind, title, summary, colorName, parentID, startAt, dueAt },
          new Date(),
        )
        await applyPlan(uid, plan)
        onSaved?.(container.id)
      }
      onClose()
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Could not save.')
      setSaving(false)
    }
  }

  return (
    <Sheet
      title={existing ? `Edit ${existing.title}` : 'New project or folder'}
      onClose={onClose}
      footer={
        <>
          <Button variant="quiet" onClick={onClose}>
            Cancel
          </Button>
          <Button variant="primary" loading={saving} disabled={refusal !== null} onClick={() => void save()}>
            {existing ? 'Save' : `Create ${CONTAINER_KIND_LABELS[kind].toLowerCase()}`}
          </Button>
        </>
      }
    >
      {!existing && (
        <FormField
          label="What is it"
          help={
            kind === 'project'
              ? 'Something that ends — a trip, a move, a launch. It can be archived when it is over.'
              : 'Somewhere to keep things — Travel, Recipes, Work. A folder never ends.'
          }
        >
          <SegmentedControl
            label="Project or folder"
            options={[
              { value: 'project', label: 'Project' },
              { value: 'folder', label: 'Folder' },
            ]}
            value={kind}
            onChange={setKind}
          />
        </FormField>
      )}

      <FormField label="Name" htmlFor="container-title">
        <input
          id="container-title"
          className="field"
          value={title}
          onChange={(event) => setTitle(event.target.value)}
          placeholder={kind === 'project' ? 'Chicago, October' : 'Travel'}
          autoFocus
        />
      </FormField>

      <FormField label="Summary" htmlFor="container-summary">
        <input
          id="container-summary"
          className="field"
          value={summary}
          onChange={(event) => setSummary(event.target.value)}
          placeholder="Optional"
        />
      </FormField>

      <FormField label="Inside" htmlFor="container-parent" help="Folders hold folders and projects.">
        <select
          id="container-parent"
          className="field"
          value={parentID ?? ''}
          onChange={(event) => setParentID(event.target.value || null)}
        >
          <option value="">Nothing — keep it at the top</option>
          {parentOptions.map((node) => (
            <option key={node.container.id} value={node.container.id}>
              {pathLabel(containers, node.container.id)}
            </option>
          ))}
        </select>
      </FormField>

      {kind === 'project' && (
        <div className="field-row">
          <FormField label="Starts" htmlFor="container-start">
            <input
              id="container-start"
              className="field"
              type="date"
              value={startField}
              onChange={(event) => setStartField(event.target.value)}
            />
          </FormField>
          <FormField label="Ends" htmlFor="container-due">
            <input
              id="container-due"
              className="field"
              type="date"
              value={dueField}
              onChange={(event) => setDueField(event.target.value)}
            />
          </FormField>
        </div>
      )}

      <FormField label="Color">
        <div className="color-choices">
          {PALETTE_COLORS.map((color) => (
            <button
              key={color}
              type="button"
              className="color-choice"
              style={{ '--tint': `var(--palette-${color})` } as React.CSSProperties}
              data-selected={color === colorName || undefined}
              aria-label={color}
              aria-pressed={color === colorName}
              onClick={() => setColorName(color)}
            />
          ))}
        </div>
      </FormField>

      {(refusal || error) && title.trim() !== '' && (
        <p className="field-error" role="alert">
          {error ?? refusal}
        </p>
      )}
    </Sheet>
  )
}
